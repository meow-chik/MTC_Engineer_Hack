#!/usr/bin/env bash
set -euo pipefail

K8S_VERSION="1.36.5"
POD_CIDR="10.244.0.0/16"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

swapoff -a
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

modprobe overlay
modprobe br_netfilter
cat >/etc/modules-load.d/k8s.conf <<'MODULES'
overlay
br_netfilter
MODULES
cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'SYSCTL'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
SYSCTL
sysctl --system

apt-get update
apt-get install -y ca-certificates curl gpg apt-transport-https containerd

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION%.*}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet="${K8S_VERSION}-1.1" kubeadm="${K8S_VERSION}-1.1" kubectl="${K8S_VERSION}-1.1"
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  kubeadm init --kubernetes-version "v${K8S_VERSION}" --pod-network-cidr "${POD_CIDR}"
fi

USER_NAME="${SUDO_USER:-${USER}}"
USER_HOME=$(getent passwd "${USER_NAME}" | cut -d: -f6)
mkdir -p "${USER_HOME}/.kube"
cp -f /etc/kubernetes/admin.conf "${USER_HOME}/.kube/config"
chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.kube/config"

export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl apply -f https://github.com/flannel-io/flannel/releases/download/v0.27.4/kube-flannel.yml

# Single-node demo: allow workloads on the control-plane node.
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
kubectl taint nodes --all node-role.kubernetes.io/master- || true

kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo
kubectl get nodes -o wide
