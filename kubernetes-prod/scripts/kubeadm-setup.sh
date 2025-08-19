#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:-}"
JOIN_CMD="${2:-}"

if [[ -z "$ROLE" || ! "$ROLE" =~ ^(master|worker)$ ]]; then
  echo "Usage:"
  echo "  master: sudo bash $0 master"
  echo "  worker: sudo bash $0 worker \"kubeadm join <...> --token ... --discovery-token-ca-cert-hash sha256:...\""
  exit 1
fi

echo "[0] Disable swap + sysctl"
swapoff -a || true
sed -ri 's/^\s*([^#].*\sswap\s)/#\1/' /etc/fstab || true
cat >/etc/modules-load.d/k8s.conf <<'EOM'
overlay
br_netfilter
EOM
cat >/etc/sysctl.d/99-k8s.conf <<'EOM'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOM
modprobe overlay || true
modprobe br_netfilter || true
sysctl --system >/dev/null

echo "[1] Install containerd (Docker repo)"
apt-get update -y
apt-get install -y ca-certificates curl gnupg apt-transport-https lsb-release
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
  >/etc/apt/sources.list.d/docker.list
sed -i 's/\r$//' /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y containerd.io

echo "[2] Configure containerd (enable CRI + SystemdCgroup)"
# clear config v2 no disabled_plugins
containerd config default >/etc/containerd/config.toml
# remove disabled_plugins, swithc on systemd cgroups (runc v2)
sed -i -E 's/^disabled_plugins = .*$//' /etc/containerd/config.toml
sed -i -E 's#SystemdCgroup = false#SystemdCgroup = true#g' /etc/containerd/config.toml
systemctl enable --now containerd

# crictl on containerd
cat >/etc/crictl.yaml <<'EOM'
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
EOM

echo "[3] Install kubeadm/kubelet/kubectl 1.30.* (далее апгрейд до 1.31)"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet=1.30.* kubeadm=1.30.* kubectl=1.30.*
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

if [[ "$ROLE" == "master" ]]; then
  echo "[4] kubeadm init (master)"
  ADVERTISE_IP=$(ip -4 addr show | awk '/inet 10\./{print $2}' | cut -d/ -f1 | head -1)
  POD_CIDR="10.244.0.0/16"
  kubeadm init \
    --kubernetes-version v1.30.0 \
    --apiserver-advertise-address "${ADVERTISE_IP}" \
    --pod-network-cidr "${POD_CIDR}"

  # kubeconfig for current user (ubuntu)
  mkdir -p $HOME/.kube
  cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
  chown "$(id -u)":"$(id -g)" $HOME/.kube/config

  echo "[5] Flannel CNI"
  kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

  echo "[6] Сгенерирую join-команду"
  kubeadm token create --print-join-command | tee $HOME/join-command.sh
  chmod +x $HOME/join-command.sh
  echo "===> Скопируй и выполни на воркерах:  sudo $HOME/join-command.sh"

else
  echo "[4] kubeadm join (worker)"
  if [[ -z "$JOIN_CMD" ]]; then
    echo "ERROR: для worker нужно передать join-команду вторым аргументом."
    echo "Пример: sudo bash $0 worker \"kubeadm join 10.10.0.23:6443 --token ... --discovery-token-ca-cert-hash sha256:...\""
    exit 2
  fi
  # kubelet start after join (create /var/lib/kubelet/config.yaml)
  eval "$JOIN_CMD"
fi

echo "DONE: $ROLE setup finished."
