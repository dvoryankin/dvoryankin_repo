#!/usr/bin/env bash
set -euo pipefail

# inventory: YAML/INI — get IPv4 from hosts
INV_PATH="${1:-kubernetes-prod/inventory/otus-ha/hosts.yaml}"

if [[ ! -f "$INV_PATH" ]]; then
  echo "Inventory not found: $INV_PATH" >&2
  exit 1
fi

# 1) get IP from inventory
mapfile -t INV_IPS < <(grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' "$INV_PATH" | sort -u)

echo "IPs from inventory:"
for ip in "${INV_IPS[@]}"; do echo " - $ip"; done

# 2) base names to remove
NAMES=(cp1 cp2 cp3 wk1 wk2 ha-cp1 ha-cp2 k8s-master-1 k8s-worker-1 k8s-worker-2)
# add args to names
if (( $# > 1 )); then
  shift
  NAMES+=("$@")
fi

echo "Looking for instances by name or IP..."

# 3) remove
python3 - <<'PY'
import json, os, re, subprocess, sys, time

def sh(cmd):
    return subprocess.run(cmd, text=True, capture_output=True)

# --- get data from ENV and ARGV ---
inv_ips = set()
inv_ips_str = os.environ.get("NUKE_INV_IPS", "").strip()
if inv_ips_str:
    inv_ips = set(inv_ips_str.split())

names = set(os.environ.get("NUKE_NAMES","").split())

# --- put instances to JSON ---
out = sh(["yc","compute","instance","list","--format","json"])
if out.returncode != 0 or not out.stdout.strip():
    print("ERROR: 'yc compute instance list' returned empty or failed. Is YC configured? (yc init / yc config get folder-id)", file=sys.stderr)
    print(out.stderr, file=sys.stderr)
    sys.exit(2)

try:
    data = json.loads(out.stdout)
except json.JSONDecodeError as e:
    print("ERROR: Failed to parse yc JSON output.", file=sys.stderr)
    print(out.stdout, file=sys.stderr)
    sys.exit(2)

hits = []
for it in data:
    name = it.get("name","")
    nics = it.get("network_interfaces") or []
    ip = nat = None
    if nics:
        p = nics[0].get("primary_v4_address") or {}
        ip = p.get("address")
        nat = (p.get("one_to_one_nat") or {}).get("address")

    by_ip = (ip in inv_ips) or (nat in inv_ips)
    by_name = (name in names) or \
              re.match(r'^(ha-)?cp[1-3]$', name or "") or \
              re.match(r'^k8s-(master|worker)-\d+$', name or "") or \
              (name in {"wk1","wk2"})

    if by_ip or by_name:
        hits.append((it["id"], name, ip, nat))

if not hits:
    print("Nothing to delete.")
    sys.exit(0)

for iid, name, ip, nat in hits:
    print(f"Deleting {name} (int={ip}, nat={nat}) id={iid} ...")
    subprocess.run(["yc","compute","instance","delete","--id",iid], check=False)

print("Waiting until instances really disappear (by ID)...")
pending = {iid for iid,_,_,_ in hits}
while pending:
    time.sleep(3)
    gone = set()
    for iid in list(pending):
        r = subprocess.run(["yc","compute","instance","get","--id",iid], text=True, capture_output=True)
        if r.returncode != 0:
            gone.add(iid)
    pending -= gone
    if pending:
        print(".", end="", flush=True)
print("\n✔ Instances deleted")
PY
