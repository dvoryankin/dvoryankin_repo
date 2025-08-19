#!/usr/bin/env bash
set -euo pipefail

INV_DIR=${INV_DIR:-kubernetes-prod/inventory/otus-ha}
INV_FILE=${INV_FILE:-$INV_DIR/hosts.yaml}
KUBE_VER=${KUBE_VER:-v1.30.6}
ANSIBLE_USER=${ANSIBLE_USER:-ubuntu}
SSH_PRIV=${SSH_PRIV:-$HOME/.ssh/yc_k8s_key}

# group_vars path (in repo)
REPO_GV_ETCD=${REPO_GV_ETCD:-kubernetes-prod/inventory/otus-ha/group_vars/etcd/main.yml}
REPO_GV_K8S=${REPO_GV_K8S:-kubernetes-prod/inventory/otus-ha/group_vars/k8s_cluster/k8s-cluster.yml}

[ -f "$INV_FILE" ] || { echo "Inventory YAML not found: $INV_FILE" >&2; exit 1; }

# 1) clone Kubespray (release-2.26)
if [ ! -d kubespray ]; then
  git clone --branch release-2.26 https://github.com/kubernetes-sigs/kubespray.git
fi

cd kubespray
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# 2) prepare inventory in Kubespray
KS_INV="inventory/otus-ha"
rm -rf "$KS_INV"
cp -rfp inventory/sample "$KS_INV"

# cp YAML-inventory
cp "../$INV_FILE" "$KS_INV/hosts.yaml"

# cp group_vars (fix version, calico, )
mkdir -p "$KS_INV/group_vars/etcd" "$KS_INV/group_vars/k8s_cluster"
if [ -f "../$REPO_GV_ETCD" ]; then
  cp "../$REPO_GV_ETCD" "$KS_INV/group_vars/etcd/main.yml"
fi
if [ -f "../$REPO_GV_K8S" ]; then
  cp "../$REPO_GV_K8S" "$KS_INV/group_vars/k8s_cluster/k8s-cluster.yml"
  # check version
  sed -i 's/^kube_version:.*/kube_version: '"$KUBE_VER"'/' "$KS_INV/group_vars/k8s_cluster/k8s-cluster.yml"
else
  cat > "$KS_INV/group_vars/k8s_cluster/k8s-cluster.yml" <<EOF
kube_version: $KUBE_VER
kube_network_plugin: calico
container_manager: containerd
EOF
fi

# 3) check aval
ansible -i "$KS_INV/hosts.yaml" all -m ping

# 4) deploy
ansible-playbook -i "$KS_INV/hosts.yaml" --become --become-user=root cluster.yml
