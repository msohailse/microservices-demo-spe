#!/usr/bin/env bash
# Runs the full local pipeline in order: monitoring/tracing infra first (so
# Istio sidecars get injected as soon as the app starts), then the app, then
# the Istio routing that exposes it. Run from the repo root.
#
# Order matters:
#   1. monitoring-setup.sh enables Istio + injection on 'default' before any
#      app pod exists, and stands up Prometheus/Grafana.
#   2. jaeger.yaml gives the Envoy sidecars somewhere to send spans, and
#      Prometheus something to scrape, before the app starts talking.
#   3. kubernetes-manifests.yaml deploys the ~11 services (sidecars injected
#      on creation since injection is already enabled).
#   4. istio-manifests.yaml opens the Gateway/HTTPRoute to the frontend.

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
kubectl patch configmap istio -n istio-system --type merge -p '{
  "data": {
    "mesh": "defaultConfig:\n  discoveryAddress: istiod.istio-system.svc:15012\n  tracing:\n    zipkin:\n      address: jaeger-collector.monitoring.svc.cluster.local:9411\n    sampling: 100.0\ndefaultProviders:\n  metrics:\n  - prometheus\n  tracing:\n  - zipkin\nenablePrometheusMerge: true\nrootNamespace: istio-system\ntrustDomain: cluster.local"
  }
}'

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
