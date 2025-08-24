#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME=${CLUSTER_NAME:-demo-cluster}

echo "[!] Delete node groups manually in YC UI if present (API names vary)."
echo "[!] Deleting cluster: $CLUSTER_NAME"
yc managed-kubernetes cluster delete --name "$CLUSTER_NAME" || true
