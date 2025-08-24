#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME=${CLUSTER_NAME:-demo-cluster}
NETWORK=${NETWORK:-k8s-net}
SUBNET=${SUBNET:-k8s-subnet-a}
ZONE=${ZONE:-ru-central1-a}

SERVICE_ACCOUNT_NAME=${SERVICE_ACCOUNT_NAME:-sa-k8s-cluster}
NODE_SERVICE_ACCOUNT_NAME=${NODE_SERVICE_ACCOUNT_NAME:-sa-k8s-node}
FOLDER_ID=${FOLDER_ID:-$(yc config get folder-id)}

echo "[+] Ensuring VPC network/subnet..."
yc vpc network get "$NETWORK" >/dev/null 2>&1 || yc vpc network create --name "$NETWORK"
yc vpc subnet  get "$SUBNET"  >/dev/null 2>&1 || yc vpc subnet create --name "$SUBNET" --zone "$ZONE" --range 10.10.0.0/24 --network-name "$NETWORK"

echo "[+] Ensuring service accounts..."
yc iam service-account get "$SERVICE_ACCOUNT_NAME" >/dev/null 2>&1 || yc iam service-account create --name "$SERVICE_ACCOUNT_NAME"
yc iam service-account get "$NODE_SERVICE_ACCOUNT_NAME" >/dev/null 2>&1 || yc iam service-account create --name "$NODE_SERVICE_ACCOUNT_NAME"

echo "[+] Granting roles (idempotent)..."
yc resource-manager folder add-access-binding --id "$FOLDER_ID" --role editor --service-account-name "$SERVICE_ACCOUNT_NAME" || true
yc resource-manager folder add-access-binding --id "$FOLDER_ID" --role editor --service-account-name "$NODE_SERVICE_ACCOUNT_NAME" || true
yc resource-manager folder add-access-binding --id "$FOLDER_ID" --role container-registry.images.puller --service-account-name "$NODE_SERVICE_ACCOUNT_NAME" || true

echo "[+] Creating Managed Kubernetes cluster: $CLUSTER_NAME"
yc managed-kubernetes cluster create --name "$CLUSTER_NAME" \
  --zone "$ZONE" \
  --network-name "$NETWORK" --subnet-name "$SUBNET" \
  --release-channel RAPID --public-ip \
  --service-account-name "$SERVICE_ACCOUNT_NAME" \
  --node-service-account-name "$NODE_SERVICE_ACCOUNT_NAME"

echo "[+] Creating node group..."
yc managed-kubernetes node-group create --cluster-name "$CLUSTER_NAME" \
  --name ng-a \
  --cores 4 --memory 8 \
  --disk-type network-ssd --disk-size 50 \
  --fixed-size 2 \
  --location zone="$ZONE",subnet-name="$SUBNET"

echo "[+] Getting kubeconfig..."
yc managed-kubernetes cluster get-credentials "$CLUSTER_NAME" --external --force
kubectl get nodes -o wide || true
