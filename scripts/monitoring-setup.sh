#!/usr/bin/env bash
# Enables Istio + injection on the `default` namespace, installs Prometheus +
# Grafana (kube-prometheus-stack) into the `monitoring` namespace, and
# registers Jaeger as Istio's tracing provider. Idempotent — safe to re-run.
# Run from the repo root (paths below are relative to it).
#
# Access after install:
#   kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
#   kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
#   kubectl port-forward -n monitoring svc/jaeger-query 16686:16686
#
# Grafana default login: admin / prom-operator

set -euo pipefail

NAMESPACE="monitoring"
RELEASE="monitoring"
CHART="prometheus-community/kube-prometheus-stack"

command -v helm     >/dev/null || { echo "helm not found on PATH" >&2; exit 1; }
command -v kubectl  >/dev/null || { echo "kubectl not found on PATH" >&2; exit 1; }
command -v minikube >/dev/null || { echo "minikube not found on PATH" >&2; exit 1; }
command -v python3  >/dev/null || { echo "python3 not found on PATH" >&2; exit 1; }
python3 -c "import yaml" 2>/dev/null || { echo "PyYAML not found (pip install pyyaml) - needed to patch Istio's mesh config" >&2; exit 1; }

echo ">> Enabling minikube addons (metrics-server, istio-provisioner, istio)"
#  This installs the Kubernetes Metrics Server, which acts as a cluster-wide aggregator of resource usage data.
minikube addons enable metrics-server
# Not use in produciton, tells Minikube to automatically pull, configuration-map, and deploy a basic installation of Istio into your local cluster so you don't have to download the binary files manually.
minikube addons enable istio-provisioner
# Istio wraps each microservice in sidecar proxy, so it knows all the traffic going in and out of the service.
minikube addons enable istio

echo ">> Waiting for the Istio control plane (istiod) to be ready"
# `minikube addons enable istio` returns as soon as it applies the Istio
# operator CR, not once the operator has reconciled and actually created the
# istiod Deployment - `kubectl wait` errors immediately (NotFound) rather
# than polling if the object doesn't exist yet, so wait for it to exist first.
until kubectl -n istio-system get deployment istiod >/dev/null 2>&1; do
  echo "   ...waiting for istiod deployment to be created"
  sleep 5
done
kubectl -n istio-system wait --for=condition=available deployment/istiod --timeout=180s

echo ">> Enabling Istio sidecar injection on the 'default' namespace"
kubectl label namespace default istio-injection=enabled --overwrite

echo ">> Registering Jaeger (zipkin) as an Istio tracing provider"
# The istio ConfigMap's data.mesh field is a single serialized YAML string,
# so a plain `kubectl patch --type merge` would replace the whole mesh config
# instead of merging into it. Read it, merge in our provider, write it back.
MESH_PATCH=$(kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}' | python3 -c '
import json, sys, yaml
mesh = yaml.safe_load(sys.stdin) or {}
providers = mesh.setdefault("extensionProviders", [])
if not any(p.get("name") == "zipkin" for p in providers):
    providers.append({
        "name": "zipkin",
        "zipkin": {
            "service": "jaeger-collector.monitoring.svc.cluster.local",
            "port": 9411,
        },
    })
print(json.dumps({"data": {"mesh": yaml.dump(mesh, default_flow_style=False)}}))
')
kubectl patch configmap istio -n istio-system --type merge -p "${MESH_PATCH}"

echo ">> Adding prometheus-community helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

echo ">> Ensuring namespace '${NAMESPACE}' exists"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Self-heal a stuck helm release from a prior interrupted run. A `helm upgrade`
# refuses to run while the release is in a transient pending-* state, which is
# what happens if a previous run of this script was Ctrl+C'd or timed out.
release_status=$(helm status "${RELEASE}" -n "${NAMESPACE}" -o json 2>/dev/null \
  | python3 -c 'import sys,json;
try:
    print(json.load(sys.stdin)["info"]["status"])
except Exception:
    print("missing")' 2>/dev/null || echo "missing")
case "${release_status}" in
  pending-install|pending-upgrade|pending-rollback)
    echo ">> Release ${RELEASE} is stuck in '${release_status}'; rolling back"
    if ! helm rollback "${RELEASE}" -n "${NAMESPACE}" 2>/dev/null; then
      echo ">> Rollback failed; uninstalling ${RELEASE} so the next install is clean"
      helm uninstall "${RELEASE}" -n "${NAMESPACE}" --wait
    fi
    ;;
  failed)
    echo ">> Release ${RELEASE} last state is 'failed'; attempting rollback before upgrade"
    helm rollback "${RELEASE}" -n "${NAMESPACE}" 2>/dev/null || true
    ;;
esac

echo ">> Installing/upgrading ${RELEASE} (${CHART}) in ${NAMESPACE}"
helm upgrade --install "${RELEASE}" "${CHART}" \
  --namespace "${NAMESPACE}" \
  -f monitoring-manifests/override_values.yaml \
  --wait

echo
echo "Done. To access the UIs:"
echo "  Grafana:    kubectl port-forward -n ${NAMESPACE} svc/${RELEASE}-grafana 3000:80"
echo "  Prometheus: kubectl port-forward -n ${NAMESPACE} svc/${RELEASE}-kube-prometheus-prometheus 9090:9090"
echo "  Jaeger:     kubectl port-forward -n ${NAMESPACE} svc/jaeger-query 16686:16686"
echo "  Grafana login: admin / prom-operator"
