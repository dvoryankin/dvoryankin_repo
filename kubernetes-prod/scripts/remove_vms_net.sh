#!/usr/bin/env bash
set -euo pipefail

ZONE=${ZONE:-ru-central1-a}
NET=${NET:-otus-net-ha}
SUBNET=${SUBNET:-otus-subnet-a}
CIDR=${CIDR:-10.10.0.0/24}
IMG_FAMILY=${IMG_FAMILY:-ubuntu-2204-lts}
PLATFORM=${PLATFORM:-standard-v3}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/yc_k8s_key.pub}
NAMES=(cp1 cp2 cp3 wk1 wk2)

echo ">>> Ensure network/subnet"
yc vpc network get --name "$NET" >/dev/null 2>&1 || yc vpc network create --name "$NET"
yc vpc subnet  get --name "$SUBNET" >/dev/null 2>&1 || yc vpc subnet create --name "$SUBNET" --zone "$ZONE" --range "$CIDR" --network-name "$NET"

echo ">>> Create instances (${NAMES[*]})"
for name in "${NAMES[@]}"; do
  if yc compute instance get --name "$name" >/dev/null 2>&1; then
    echo "skip $name (already exists)"; continue
  fi
  yc compute instance create \
    --name "$name" \
    --zone "$ZONE" \
    --hostname "$name" \
    --platform "$PLATFORM" \
    --cores 2 --memory 4 \
    --create-boot-disk image-family="$IMG_FAMILY",type=network-ssd,size=20 \
    --network-interface subnet-name="$SUBNET",nat-ip-version=ipv4 \
    --ssh-key "$SSH_KEY"
done

echo ">>> Collected internal IPs:"
yc compute instance list --format json | python3 - <<'PY'
import json,sys
want = {"cp1","cp2","cp3","wk1","wk2"}
data = json.load(sys.stdin)
m = {}
for i in data:
    n = i["name"]
    if n in want:
        ip = i["network_interfaces"][0]["primary_v4_address"]["address"]
        m[n]=ip
for k in ["cp1","cp2","cp3","wk1","wk2"]:
    print(f"{k} {m.get(k)}")
PY
