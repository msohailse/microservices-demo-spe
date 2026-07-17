# Setup

## Steps

1. [x] Switch context: `kubectl config use-context minikube`
2. [x] `minikube start --driver=docker --cpus=4`
3. [x] `kubectl apply -f release/kubernetes-manifests.yaml` — 12 microservices
4. [ ] `./scripts/monitoring-setup.sh` — Prometheus + Grafana + Jaeger
5. [ ] All pods ready
6. [ ] Baseline load tests

## Monitoring Stack

| Tool | Purpose | Port | Command |
|------|---------|------|---------|
| Prometheus | Metrics | 9090 | `kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090` |
| Grafana | Dashboards | 3000 | `kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80` |
| Jaeger | Tracing + dependency graph | 16686 | `kubectl port-forward -n monitoring svc/jaeger-query 16686:16686` |

Grafana login: `admin` / `prom-operator`

## Access
- Online Boutique: `minikube service frontend-external`
- Grafana: `localhost:3000`
- Prometheus: `localhost:9090`
- Jaeger: `localhost:16686`
