#!/usr/bin/env bash
# SPE measurement script -- queries Prometheus and Jaeger for all metrics needed
# to populate the JMT model and validate predictions against measurements.
#
# Outputs:
#   1. Routing probabilities (Jaeger /api/dependencies)
#   2. Corrected (net) service times for JMT input
#      S_net[s] = S_measured[s] - sum(direct_calls_per_root * S_net[downstream])
#
# Requires both port-forwards running:
#   kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
#   kubectl port-forward -n monitoring svc/jaeger-query 16686:16686

PROM="http://localhost:9090"
JAEGER="http://localhost:16686"

python3 << EOF
import json, sys, urllib.request, urllib.parse, time
from collections import defaultdict

PROM  = "$PROM"
JAEGER = "$JAEGER"

def prom_query(q):
    url = PROM + "/api/v1/query?" + urllib.parse.urlencode({"query": q})
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            return json.load(r)
    except Exception as e:
        print(f"  [ERROR] Prometheus unreachable: {e}", file=sys.stderr)
        return {}

def jaeger_deps():
    end_ts = int(time.time() * 1000)
    url = f"{JAEGER}/api/dependencies?endTs={end_ts}&lookback=86400000"
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            return json.load(r).get("data", [])
    except Exception as e:
        print(f"  [ERROR] Jaeger unreachable: {e}", file=sys.stderr)
        return []

# ── Fetch ─────────────────────────────────────────────────────────────────────
edges = jaeger_deps()

prom_duration = prom_query(
    "sum by (destination_workload) "
    "(rate(istio_request_duration_milliseconds_sum[2m])) / "
    "sum by (destination_workload) "
    "(rate(istio_request_duration_milliseconds_count[2m]))"
)
prom_lambda = prom_query(
    'sum(rate(istio_requests_total{destination_workload="frontend"}[2m]))'
)

# ── Build call graph ──────────────────────────────────────────────────────────
outbound   = defaultdict(lambda: defaultdict(int))
root_calls = 0

for e in edges:
    p = e.get("parent","").replace(".default","")
    c = e.get("child","").replace(".default","")
    n = e.get("callCount", 0)
    if "jaeger" in p or "jaeger" in c:
        continue
    outbound[p][c] += n
    if p == "loadgenerator" and c == "frontend":
        root_calls = n

# ── Section 1: Routing probabilities ─────────────────────────────────────────
print("=" * 56)
print("1. ROUTING PROBABILITIES  -- Jaeger")
print("=" * 56)

if not edges:
    print("  No data — is Jaeger port-forward running?")
else:
    for parent in sorted(outbound):
        total = sum(outbound[parent].values())
        print(f"\nFrom {parent} (total calls: {total}):")
        for child, n in sorted(outbound[parent].items(), key=lambda x: -x[1]):
            print(f"  -> {child:<28} p={n/total:.3f}")

# ── Section 2: Corrected service times ───────────────────────────────────────
print()
print("=" * 56)
print("2. JMT INPUT TABLE (net service time -- downstream wait removed)")
print("=" * 56)

results = prom_duration.get("data", {}).get("result", [])
if not results:
    print("  No data — is Prometheus port-forward running?")
    sys.exit(0)

lam_results = prom_lambda.get("data", {}).get("result", [])
lam = float(lam_results[0]["value"][1]) if lam_results else 0.0

measured = {}
for r in results:
    svc = r["metric"].get("destination_workload","")
    if svc and svc != "unknown":
        measured[svc] = float(r["value"][1])   # milliseconds

print()
print(f"  Root calls (loadgenerator->frontend): {root_calls}")
print(f"  lambda (λ) frontend: {lam:.4f} req/s")

if root_calls == 0:
    print()
    print("  [WARNING] No Jaeger dependency data — S_i corrections cannot be applied.")
    print("            JMT input table skipped: S_i = R_i would be wrong for non-leaf services.")
    print("            Make sure BOTH port-forwards are running and load has accumulated traces:")
    print("            kubectl port-forward -n monitoring svc/jaeger-query 16686:16686")
    print("            kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090")
else:
    services   = set(measured.keys())
    downstream = {s: set(outbound[s].keys()) & services for s in services}

    total_incoming = defaultdict(int)
    for parent, children in outbound.items():
        for child, n in children.items():
            total_incoming[child] += n

    # V_i = total_incoming[s] / root_calls  (visit ratio: avg calls to s per root request)
    fan_out = defaultdict(lambda: defaultdict(float))
    for parent, children in outbound.items():
        denom = total_incoming[parent]
        if denom == 0:
            continue
        for child, n in children.items():
            fan_out[parent][child] = n / denom

    order, remaining = [], set(services)
    while remaining:
        leaves = [s for s in remaining if all(c in order for c in downstream[s])]
        if not leaves:
            leaves = sorted(remaining)
        for s in sorted(leaves):
            order.append(s)
            remaining.discard(s)

    S_net = {}
    for s in order:
        correction = sum(
            fan_out[s].get(c, 0.0) * S_net.get(c, measured.get(c, 0.0))
            for c in downstream[s]
        )
        S_net[s] = max(measured.get(s, 0.0) - correction, 0.0)

    print()
    print(f"  {'Station':<28} {'R_i (ms)':<18} {'S_i (ms)':<16} {'S_i (s) -> JMT':<18} {'Note'}")
    print(f"  {'(Prometheus R_i)':<28} {'raw residence time':<18} {'S_i=R_i-W_i':<16}")
    print(f"  {'-'*90}")
    ia = (1/lam)*1000 if lam > 0 else 0
    print(f"  {'loadgenerator (source)':<28} {'-':<18} {ia:<16.3f} {ia/1000:<18.6f}")
    for s in sorted(S_net, key=lambda x: -S_net[x]):
        sm = measured.get(s, 0.0)
        sn = S_net[s]
        flag = "W_i subtracted" if abs(sm - sn) > 0.5 else "leaf: S_i = R_i"
        print(f"  {s:<28} {sm:<18.3f} {sn:<16.3f} {sn/1000:<18.6f} {flag}")

# ── Section 3: p95 latency per service ───────────────────────────────────────
print()
print("=" * 56)
print("3. P95 LATENCY  -- Prometheus histogram_quantile")
print("=" * 56)

prom_p95 = prom_query(
    "histogram_quantile(0.95, sum by (destination_workload, le) "
    "(rate(istio_request_duration_milliseconds_bucket[2m])))"
)
prom_p95_sys = prom_query(
    "histogram_quantile(0.95, sum by (le) "
    "(rate(istio_request_duration_milliseconds_bucket"
    "{destination_workload=\"frontend\"}[2m])))"
)

p95_results = prom_p95.get("data", {}).get("result", [])
p95_sys_results = prom_p95_sys.get("data", {}).get("result", [])

if not p95_results:
    print("  No histogram data — ensure Istio metrics are being scraped.")
else:
    p95_map = {}
    for r in p95_results:
        svc = r["metric"].get("destination_workload", "")
        if svc and svc != "unknown":
            p95_map[svc] = float(r["value"][1])  # already in ms (bucket boundaries are ms)

    sys_p95 = float(p95_sys_results[0]["value"][1]) if p95_sys_results else 0.0

    print()
    print(f"  System p95 (frontend end-to-end): {sys_p95:.1f} ms")
    print()
    print(f"  {'Station':<28} {'R_i (ms)':<16} {'p95 (ms)':<14} {'p95/R_i ratio'}")
    print(f"  {'-'*70}")
    for s in sorted(measured, key=lambda x: -measured.get(x, 0)):
        mn  = measured.get(s, 0.0)
        p95 = p95_map.get(s, 0.0)
        ratio = p95 / mn if mn > 0 else 0.0
        print(f"  {s:<28} {mn:<16.3f} {p95:<14.1f} {ratio:.2f}")
EOF
