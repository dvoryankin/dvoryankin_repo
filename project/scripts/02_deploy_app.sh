#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

NS=default
ING_NS=ingress-nginx

echo "[i] Getting EXTERNAL-IP of ingress-nginx..."
IP=$(kubectl -n "$ING_NS" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [[ -z "$IP" ]]; then
  echo "[!] EXTERNAL-IP not found. Install ingress first (scripts/01_install_ingress.sh)."
  exit 1
fi
SHOP_HOST="shop.${IP}.nip.io"
echo "[+] SHOP_HOST: $SHOP_HOST"

echo "[+] Deploy Online Boutique (upstream manifests)"
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/v0.8.0/release/kubernetes-manifests.yaml

echo "[+] Render and apply Ingress for frontend"
export SHOP_HOST
envsubst < apps/online-boutique/ingress.yaml.tmpl > apps/online-boutique/ingress.yaml
kubectl apply -f apps/online-boutique/ingress.yaml

echo "[i] Wait until frontend is Ready..."
kubectl -n "$NS" rollout status deploy/frontend --timeout=180s || true

echo "[✓] Open in browser: http://$SHOP_HOST"
