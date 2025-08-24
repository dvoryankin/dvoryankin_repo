#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

NS=observability

echo "[+] Add Helm repo grafana"
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo update >/dev/null

echo "[+] Create namespace $NS (if not exists)"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

echo "[+] Install/upgrade Loki Stack (NO builtin datasource)"
helm upgrade --install loki grafana/loki-stack -n "$NS" \
  -f platform/logging/values.yaml \
  --wait --timeout 15m

echo "[+] Apply Grafana Loki datasource ConfigMap"
kubectl apply -f platform/logging/grafana-datasource-loki.yaml

if kubectl -n "$NS" get deploy kps-grafana >/dev/null 2>&1; then
  echo "[i] Restarting Grafana to reload datasources"
  kubectl -n "$NS" rollout restart deploy/kps-grafana
  kubectl -n "$NS" rollout status deploy/kps-grafana --timeout=180s || true
fi

echo "[i] In Grafana → Explore, choose 'Loki' to search logs."
