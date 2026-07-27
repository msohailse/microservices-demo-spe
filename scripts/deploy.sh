#!/usr/bin/env bash
# Full deployment pipeline for the SPE benchmark on Minikube. Run from repo root.
#
# What this does, in plain terms:
#   1. Starts Minikube if it is not already running.
#   2. Installs Prometheus and Grafana (for metrics), enables Istio (the service
#      mesh that wraps each pod in a proxy so we can measure traffic without
#      touching any app code), and registers Jaeger as the tracing destination.
#   3. Deploys Jaeger (distributed trace collector) and tells Istio to send
#      every request trace to it at 100% sampling.
#   4. Deploys the 11 Online Boutique microservices. Because Istio is already
#      enabled, each pod gets a sidecar proxy injected automatically on startup.
#   5. Opens the frontend to browser traffic via an Istio Gateway.

set -euo pipefail

command -v kubectl  >/dev/null || { echo "kubectl not found on PATH" >&2; exit 1; }
command -v minikube >/dev/null || { echo "minikube not found on PATH" >&2; exit 1; }

echo ">> [1/5] Ensuring minikube is running"
if ! minikube status --format='{{.Host}}' 2>/dev/null | grep -q Running; then
  minikube start --driver=docker --cpus=6 --memory=9g
else
  echo "minikube already running — skipping start"
fi

echo ">> [2/5] Monitoring + tracing infra (Istio, Prometheus, Grafana)"
./scripts/monitoring-setup.sh

echo ">> [3/5] Jaeger + Istio telemetry wiring"
kubectl apply -f monitoring-manifests/monitoring.yaml

echo ">> Setting Istio trace sampling to 100% and pointing to Jaeger"
# monitoring-setup.sh already adds the extensionProvider; this patch only
# merges sampling/tracing fields without touching extensionProviders.
MESH_PATCH=$(kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}' | python3 -c '
import json, sys, yaml
mesh = yaml.safe_load(sys.stdin) or {}
mesh.setdefault("defaultConfig", {}).setdefault("tracing", {}).update({
    "zipkin": {"address": "jaeger-collector.monitoring.svc.cluster.local:9411"},
    "sampling": 100.0,
})
mesh.setdefault("defaultProviders", {}).update({"metrics": ["prometheus"], "tracing": ["zipkin"]})
print(json.dumps({"data": {"mesh": yaml.dump(mesh, default_flow_style=False)}}))
')
kubectl patch configmap istio -n istio-system --type merge -p "${MESH_PATCH}"

echo ">> [4/5] Online Boutique microservices"
kubectl apply -f release/kubernetes-manifests.yaml

echo ">> [5/5] Istio Gateway/HTTPRoute for the frontend"
# release/istio-manifests.yaml uses the Kubernetes Gateway API
# (gateway.networking.k8s.io/v1beta1), which is a separate upstream project
# from Istio and ships its own CRDs. Install them first if missing.
if ! kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  echo ">> Installing Kubernetes Gateway API CRDs (standard channel v1.2.0)"
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
fi
kubectl apply -f release/istio-manifests.yaml

echo
echo "Done. To access things:"
echo "  App:        minikube service frontend-external"
echo "  Grafana:    kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80"
echo "  Prometheus: kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090"
echo "  Jaeger:     kubectl port-forward -n monitoring svc/jaeger-query 16686:16686"
echo "  Grafana login: admin / prom-operator"
