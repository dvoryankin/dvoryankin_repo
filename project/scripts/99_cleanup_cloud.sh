#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Настраиваемые переменные
CLUSTER_NAME=${CLUSTER_NAME:-demo-cluster}
NETWORK=${NETWORK:-k8s-net}
SUBNET=${SUBNET:-k8s-subnet-a}
RT_NAME=${RT_NAME:-rt-a}
GW_NAME=${GW_NAME:-nat-gw-a}

echo ">>> CLOUD NUKE is about to run."
read -p "Type 'YES' to continue: " ACK
[[ "$ACK" == "YES" ]]

echo "[1/6] Delete Node Groups..."
for NG in $(yc managed-kubernetes node-group list --format json | jq -r '.[] | select(.cluster_id!=null) | .id'); do
  echo " - deleting node-group $NG"
  yc managed-kubernetes node-group delete --id "$NG" || true
done

echo "[2/6] Delete Cluster (if exists)..."
if yc managed-kubernetes cluster get "$CLUSTER_NAME" >/dev/null 2>&1; then
  yc managed-kubernetes cluster delete --name "$CLUSTER_NAME" || true
fi

echo "[3/6] Delete Network Load Balancers..."
for NLB in $(yc load-balancer network-load-balancer list --format json | jq -r '.[].id'); do
  echo " - deleting NLB $NLB"
  yc load-balancer network-load-balancer delete --id "$NLB" || true
done

echo "[3b/6] Delete Target Groups (orphans)..."
for TG in $(yc load-balancer target-group list --format json | jq -r '.[].id'); do
  echo " - deleting TG $TG"
  yc load-balancer target-group delete --id "$TG" || true
done

echo "[4/6] Detach route table from subnet (if any)..."
if yc vpc subnet get "$SUBNET" >/dev/null 2>&1; then
  yc vpc subnet update "$SUBNET" --clear-route-table || true
fi

echo "[4b/6] Delete route table and NAT gateway..."
yc vpc route-table delete --name "$RT_NAME" || true
yc vpc gateway delete --name "$GW_NAME" || true

echo "[5/6] Delete subnet and network..."
yc vpc subnet delete --name "$SUBNET" || true
yc vpc network delete --name "$NETWORK" || true

echo "[6/6] Delete service accounts (optional)..."
yc iam service-account delete --name sa-k8s-node || true
yc iam service-account delete --name sa-k8s-cluster || true

echo "[✓] Cloud resources cleanup triggered. Verify with:
yc compute instance list
yc load-balancer network-load-balancer list
yc vpc subnet list
yc vpc gateway list
yc vpc route-table list
yc managed-kubernetes cluster list
"
