#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-kubernetes-prod/inventory/otus-ha/hosts.yaml}"
ANSIBLE_USER=${ANSIBLE_USER:-ubuntu}
SSH_PRIV=${SSH_PRIV:-~/.ssh/yc_k8s_key}

mkdir -p "$(dirname "$OUT")"

python3 - "$OUT" "$ANSIBLE_USER" "$SSH_PRIV" <<'PY'
import json, subprocess, sys, os
out, user, key = sys.argv[1], sys.argv[2], sys.argv[3]
names = ["cp1","cp2","cp3","wk1","wk2"]

data = subprocess.run(["yc","compute","instance","list","--format","json"],
                      text=True, capture_output=True, check=True).stdout
j = json.loads(data)

m = {}
for it in j:
    n = it["name"]
    if n not in names:
        continue
    nic = it["network_interfaces"][0]["primary_v4_address"]
    intip = nic.get("address","")
    pub = (nic.get("one_to_one_nat") or {}).get("address","")
    m[n] = {"int": intip, "pub": pub}

def host_block(n):
    return f"""\
    {n}:
      ansible_host: {m[n]['pub']}  # {n} EXTERNAL
      ip:           {m[n]['int']}  # {n} INTERNAL
      access_ip:    {m[n]['int']}"""

for n in names:
    if n not in m or not m[n]["int"] or not m[n]["pub"]:
        print(f"Missing IPs for {n}", file=sys.stderr); sys.exit(2)

yaml = f"""\
all:
  hosts:
{host_block('cp1')}
{host_block('cp2')}
{host_block('cp3')}
{host_block('wk1')}
{host_block('wk2')}

  vars:
    ansible_user: {user}
    ansible_ssh_private_key_file: {key}

    ansible_python_interpreter: /usr/bin/python3
    ansible_timeout: 30
    ansible_ssh_common_args: >-
      -o StrictHostKeyChecking=no
      -o UserKnownHostsFile=/dev/null
      -o ServerAliveInterval=30
      -o ServerAliveCountMax=5
      -o ConnectTimeout=5
      -o ControlMaster=auto
      -o ControlPersist=30m

  children:
    kube_control_plane:
      hosts:
        cp1:
        cp2:
        cp3:
    kube_node:
      hosts:
        wk1:
        wk2:
    etcd:
      hosts:
        cp1:
        cp2:
        cp3:
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
    calico_rr:
      hosts: {{}}
"""

open(out,"w").write(yaml)
print(f"Wrote {out}")
PY
