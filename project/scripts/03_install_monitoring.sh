#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

NS=observability

echo "[+] Add Helm repos..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null

echo "[+] Create namespace $NS (if not exists)"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

echo "[+] Install kube-prometheus-stack (Grafana tuned)"
helm upgrade --install kps prometheus-community/kube-prometheus-stack -n "$NS" \
  -f platform/monitoring/values.yaml \
  --set grafana.initChownData.enabled=true \
  --set grafana.securityContext.runAsUser=472 \
  --set grafana.securityContext.fsGroup=472 \
  --set grafana.readinessProbe.initialDelaySeconds=60 \
  --set grafana.livenessProbe.initialDelaySeconds=120 \
  --wait --timeout 25m

echo "[+] Apply custom alert rules (ingress 5xx)"
kubectl apply -f platform/monitoring/alerts/ingress-5xx.yaml

if helm -n ingress-nginx status ingress-nginx >/dev/null 2>&1; then
  echo "[i] Enabling ServiceMonitor for ingress-nginx..."
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx \
    --reuse-values \
    --set controller.metrics.serviceMonitor.enabled=true \
    --set controller.metrics.serviceMonitor.namespace=$NS \
    --wait --timeout 10m
fi

echo "[i] Grafana credentials: admin / admin123"
echo "[i] Port-forward: kubectl -n observability port-forward svc/kps-grafana 3000:80"
echo "[i] Open http://localhost:3000"
