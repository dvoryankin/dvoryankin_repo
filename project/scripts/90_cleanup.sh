#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "[!] Deleting Online Boutique..."
kubectl delete -f https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/v0.8.0/release/kubernetes-manifests.yaml || true
kubectl delete -f apps/online-boutique/ingress.yaml || true

echo "[!] Deleting monitoring (kube-prometheus-stack) and logging (loki)..."
helm -n observability uninstall kps || true
helm -n observability uninstall loki || true
kubectl delete ns observability --wait=false || true

echo "[!] Deleting ingress-nginx..."
helm -n ingress-nginx uninstall ingress-nginx || true
kubectl delete ns ingress-nginx --wait=false || true

echo "[✓] Done. Delete the cluster in your cloud provider to stop charges."
