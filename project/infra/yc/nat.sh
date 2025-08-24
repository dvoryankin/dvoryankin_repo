#!/usr/bin/env bash
set -euo pipefail
NETWORK=${NETWORK:-k8s-net}
SUBNET=${SUBNET:-k8s-subnet-a}

yc vpc gateway get nat-gw-a >/dev/null 2>&1 || yc vpc gateway create --name nat-gw-a

GW_ID=$(yc vpc gateway list --format json | jq -r '.[] | select(.name=="nat-gw-a").id')

yc vpc route-table get rt-a >/dev/null 2>&1 || \
yc vpc route-table create --name rt-a --network-name "$NETWORK" \
  --route destination=0.0.0.0/0,gateway-id="$GW_ID"

yc vpc subnet update "$SUBNET" --route-table-name rt-a
echo "[✓] NAT configured for subnet $SUBNET"

