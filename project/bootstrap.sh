#!/usr/bin/env bash
set -euo pipefail

# --- sanity ---
command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }
command -v helm    >/dev/null || { echo "helm not found";    exit 1; }
kubectl version --client --output=yaml >/dev/null

# --- namespaces ---
kubectl get ns observability >/dev/null 2>&1 || kubectl create ns observability
kubectl get ns ingress-nginx >/dev/null 2>&1 || kubectl create ns ingress-nginx

# --- ingress-nginx ---
if ! kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1; then
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx \
    --set controller.service.type=LoadBalancer \
    --set controller.watchIngressWithoutClass=true
fi
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=10m
LB_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "Ingress LB IP: ${LB_IP}"

# --- loki  ---
helm repo add grafana https://grafana.github.io/helm-charts
helm upgrade --install loki grafana/loki-stack \
  -n observability \
  -f project/platform/logging/values.yaml
kubectl -n observability rollout status ds/loki-promtail --timeout=10m || true

# --- prometheus ---
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n observability \
  -f project/platform/monitoring/values.yaml
kubectl -n observability rollout status deploy/kps-grafana --timeout=10m || true

# --- grafana datasource for loki ---
kubectl -n observability apply -f project/platform/logging/grafana-datasource-loki.yaml

# --- app ingress ---
SVC_PORT="$(kubectl -n default get svc frontend -o jsonpath='{.spec.ports[0].port}')"
SHOP_HOST="shop.${LB_IP}.nip.io"
export SHOP_HOST SVC_PORT

if [[ "${SVC_PORT}" != "80" ]]; then
  sed -E "s/number: 80/number: ${SVC_PORT}/" project/platform/ingress/ingress-shop.yaml.tpl \
  | envsubst \
  | kubectl apply -f -
else
  envsubst < project/platform/ingress/ingress-shop.yaml.tpl \
  | kubectl apply -f -
fi

echo "Shop URL: http://${SHOP_HOST}/"
