#!/usr/bin/env bash
set -euo pipefail

ZONE=${ZONE:-ru-central1-a}
NET=${NET:-otus-net-ha}          # export NET=otus-k8s-network
SUBNET=${SUBNET:-otus-subnet-a}  # export SUBNET=otus-k8s-subnet
CIDR=${CIDR:-10.10.0.0/24}
PLATFORM=${PLATFORM:-standard-v3}
IMG_FAMILY=${IMG_FAMILY:-ubuntu-2204-lts}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/yc_k8s_key.pub}
USER_DATA=${USER_DATA:-kubernetes-prod/cloud-init/node-init.yaml}
NAMES=(cp1 cp2 cp3 wk1 wk2)
IMG_FOLDER=${IMG_FOLDER:-standard-images}

# last image ID
echo ">>> Resolve image from family: ${IMG_FAMILY} in folder ${IMG_FOLDER}"
IMG_ID=$(
  yc compute image get-latest-from-family "$IMG_FAMILY" --folder-id "$IMG_FOLDER" --format json \
    | python3 -c 'import sys,json; data=json.load(sys.stdin); print(data.get("id",""))'
)
if [ -z "$IMG_ID" ]; then
  echo "ERROR: cannot resolve image-id for family ${IMG_FAMILY} in folder ${IMG_FOLDER}" >&2
  exit 1
fi
echo "Using image-id: ${IMG_ID}"

need() { command -v "$1" >/dev/null || { echo "need $1 in PATH"; exit 1; }; }
need yc
[ -f "$USER_DATA" ] || { echo "cloud-init not found: $USER_DATA" >&2; exit 1; }

# check folder
if ! FID=$(yc config get folder-id 2>/dev/null); then
  echo "YC not configured. Run: yc init" >&2; exit 1
fi
if [[ -z "$FID" ]]; then
  echo "folder-id is empty. Run: yc init" >&2; exit 1
fi

json_or_empty() {
  local cmd=("$@")
  if ! out="$("${cmd[@]}" --format json 2>/dev/null)"; then
    echo ""
    return 0
  fi
  [[ -n "$out" ]] || { echo ""; return 0; }
  echo "$out"
}

ensure_network() {
  # check existing
  if yc vpc network get --name "$NET" >/dev/null 2>&1; then
    echo "Using existing network: $NET"; return
  fi
  # try create
  if yc vpc network create --name "$NET" >/dev/null 2>&1; then
    echo "Created network: $NET"; return
  fi
  echo "WARN: failed to create network '$NET' (quota?). Trying to reuse any existing one…"
  # get network
  list="$(json_or_empty yc vpc network list)"
  if [[ -z "$list" ]]; then
    echo "ERROR: no networks available and cannot create new." >&2; exit 1
  fi
  NET=$(python3 - <<'PY'
import json,sys
d=json.loads(sys.stdin.read())
print(d[0]["name"])
PY
<<<"$list")
  echo "Reusing network: $NET"
}

ensure_subnet() {
  if yc vpc subnet get --name "$SUBNET" >/dev/null 2>&1; then
    echo "Using existing subnet: $SUBNET"; return
  fi
  if yc vpc subnet create --name "$SUBNET" --zone "$ZONE" --range "$CIDR" --network-name "$NET" >/dev/null 2>&1; then
    echo "Created subnet: $SUBNET"; return
  fi
  echo "WARN: failed to create subnet '$SUBNET' (quota?). Trying to reuse any subnet in $ZONE…"
  list="$(json_or_empty yc vpc subnet list)"
  if [[ -z "$list" ]]; then
    echo "ERROR: no subnets available and cannot create new." >&2; exit 1
  fi
  SUBNET=$(python3 - "$ZONE" <<'PY'
import json,sys
zone=sys.argv[1]
d=json.loads(sys.stdin.read())
for s in d:
  if s.get("zoneId")==zone:
    print(s["name"]); break
PY
<<<"$list")
  [[ -n "$SUBNET" ]] || { echo "ERROR: no subnet found in $ZONE" >&2; exit 1; }
  echo "Reusing subnet: $SUBNET"
}

ensure_network
ensure_subnet

has_keys=0
grep -q 'ssh-authorized-keys' "$USER_DATA" && has_keys=1

echo ">>> Creating instances: ${NAMES[*]}"
for name in "${NAMES[@]}"; do
  if yc compute instance get --name "$name" >/dev/null 2>&1; then
    echo "skip $name (exists)"; continue
  fi

  if ((has_keys==1)); then
    # key in cloud-init → no --ssh-key
    yc compute instance create \
      --name "$name" \
      --hostname "$name" \
      --zone "$ZONE" \
      --platform "$PLATFORM" \
      --cores 2 --memory 4 \
      --create-boot-disk image-id="$IMG_ID",type=network-ssd,size=20 \
      --network-interface subnet-name="$SUBNET",nat-ip-version=ipv4 \
      --metadata-from-file user-data="$USER_DATA"
  else
    # no key cloud-init → through --ssh-key
    yc compute instance create \
      --name "$name" \
      --hostname "$name" \
      --zone "$ZONE" \
      --platform "$PLATFORM" \
      --cores 2 --memory 4 \
      --create-boot-disk image-id="$IMG_ID",type=network-ssd,size=20 \
      --network-interface subnet-name="$SUBNET",nat-ip-version=ipv4 \
      --metadata-from-file user-data="$USER_DATA" \
      --ssh-key "$SSH_KEY"
  fi
done

echo ">>> Internal/Public IPs (name int pub):"
yc compute instance list --format json | python3 - <<'PY'
import json,sys
want={"cp1","cp2","cp3","wk1","wk2"}
try:
  d=json.load(sys.stdin)
except Exception:
  sys.exit(0)
rows=[]
for it in d:
  n=it.get("name")
  if n in want:
    nic=it["network_interfaces"][0]["primary_v4_address"]
    intip=nic.get("address","")
    pub=(nic.get("one_to_one_nat") or {}).get("address","")
    rows.append((n,intip,pub))
for n,i,p in sorted(rows):
  print(n,i,p)
PY
