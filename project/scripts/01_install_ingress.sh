#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

NS=ingress-nginx

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
helm repo update >/dev/null

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

echo "[i] Checking ServiceMonitor CRD..."
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  echo "[+] CRD found -> installing with ServiceMonitor"
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n "$NS" \
    -f platform/ingress/values.yaml \
    --wait --timeout 20m
else
  echo "[!] CRD not found -> installing WITHOUT ServiceMonitor (metrics enabled)"
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n "$NS" \
    --set controller.publishService.enabled=true \
    --set controller.service.type=LoadBalancer \
    --set controller.metrics.enabled=true \
    --set controller.metrics.serviceMonitor.enabled=false \
    --wait --timeout 20m
fi

echo "[i] Waiting for LoadBalancer external IP..."
for i in {1..60}; do
  IP=$(kubectl -n "$NS" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -n "${IP:-}" ]] && { echo "[+] EXTERNAL-IP: $IP"; break; }
  sleep 5
done
[[ -z "${IP:-}" ]] && { echo "[!] EXTERNAL-IP not assigned yet"; exit 1; }
