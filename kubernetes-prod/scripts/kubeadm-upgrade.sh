#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:-}"
if [[ -z "$ROLE" || ! "$ROLE" =~ ^(master|worker)$ ]]; then
  echo "Usage: sudo bash $0 {master|worker}"
  exit 1
fi

echo "[1] switch to на v1.31"
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update -y

echo "[2] Обновляю kubeadm до 1.31.*"
apt-mark unhold kubeadm kubelet kubectl || true
apt-get install -y kubeadm=1.31.*

if [[ "$ROLE" == "master" ]]; then
  echo "[3] kubeadm upgrade apply (control-plane)"
  kubeadm upgrade plan
  kubeadm upgrade apply v1.31.0 -y || kubeadm upgrade apply "v1.31.*" -y

  echo "[4] kubelet/kubectl → 1.31.*"
  apt-get install -y kubelet=1.31.* kubectl=1.31.*
  systemctl daemon-reload && systemctl restart kubelet

  echo "[5] check"
  kubectl version --short
  kubectl get nodes -o wide

else
  echo "[3] kubeadm upgrade node (worker)"
  kubeadm upgrade node

  echo "[4] kubelet/kubectl → 1.31.*"
  apt-get install -y kubelet=1.31.* kubectl=1.31.*
  systemctl daemon-reload && systemctl restart kubelet

  echo "ready for worker. get uncordon on master."
fi

apt-mark hold kubelet kubeadm kubectl
echo "DONE: $ROLE upgraded to 1.31.*"
