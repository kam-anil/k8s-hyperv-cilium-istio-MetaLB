#!/usr/bin/env bash
# =============================================================================
#  cp-init.sh - kubeadm init (CRI-O, no kube-proxy) + kubeconfig (run as root, idempotent)
#  The CNI (Cilium, full kube-proxy replacement) is installed by platform-install.sh
#  after the workers join, so nodes stay NotReady until then - that is expected.
#  Usage: sudo NODE_NAME=k8s-cp-01 ADVERTISE_IP=192.168.1.200 KUBE_VERSION=v1.36.5 \
#              ADMIN_USER=k8sadmin ./cp-init.sh
# =============================================================================
set -euo pipefail

# ------------------------------------------------------------- configuration
NODE_NAME="${NODE_NAME:-$(hostname -s)}"
ADVERTISE_IP="${ADVERTISE_IP:?ADVERTISE_IP is required}"
KUBE_VERSION="${KUBE_VERSION:-$(kubeadm version -o short)}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-${ADVERTISE_IP}:6443}"   # use a DNS name/VIP for future HA
CLUSTER_NAME="${CLUSTER_NAME:-kubernetes}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
CRI_SOCKET="${CRI_SOCKET:-unix:///var/run/crio/crio.sock}"
ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-}}"
KUBEADM_CONFIG=/etc/kubernetes/kubeadm-config.yaml

log()  { printf '\033[1;34m[cp-init]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[cp-init] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "failed at line ${LINENO}: ${BASH_COMMAND}"' ERR
[[ ${EUID} -eq 0 ]] || die "must run as root"
export KUBECONFIG=/etc/kubernetes/admin.conf

# ------------------------------------------------------------- 1. kubeadm init
if [[ -f /etc/kubernetes/admin.conf ]]; then
  log "Control plane already initialised - skipping kubeadm init"
else
  log "Writing ${KUBEADM_CONFIG}"
  install -d -m 0755 /etc/kubernetes
  cat > "${KUBEADM_CONFIG}" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${ADVERTISE_IP}
  bindPort: 6443
nodeRegistration:
  name: ${NODE_NAME}
  criSocket: ${CRI_SOCKET}
  kubeletExtraArgs:
    - name: node-ip
      value: ${ADVERTISE_IP}
# Cilium runs with kubeProxyReplacement=true, so kube-proxy is never deployed.
skipPhases:
  - addon/kube-proxy
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: ${CLUSTER_NAME}
kubernetesVersion: ${KUBE_VERSION}
controlPlaneEndpoint: ${CONTROL_PLANE_ENDPOINT}
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
  dnsDomain: cluster.local
apiServer:
  certSANs:
    - ${ADVERTISE_IP}
    - ${NODE_NAME}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
containerRuntimeEndpoint: ${CRI_SOCKET}
EOF
  kubeadm config validate --config "${KUBEADM_CONFIG}"

  log "Pre-pulling control plane images via CRI-O"
  kubeadm config images pull --config "${KUBEADM_CONFIG}"

  log "kubeadm init (${KUBE_VERSION}, CRI-O, no kube-proxy, pods ${POD_CIDR})"
  kubeadm init --config "${KUBEADM_CONFIG}" | tee /var/log/kubeadm-init.log
  chmod 0600 /var/log/kubeadm-init.log     # contains a bootstrap token
fi

# ------------------------------------------------------------- 2. kubeconfig for non-root user
if [[ -n "${ADMIN_USER}" && "${ADMIN_USER}" != "root" ]]; then
  ADMIN_HOME="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
  [[ -n "${ADMIN_HOME}" ]] || die "user ${ADMIN_USER} not found"
  install -d -m 0700 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "${ADMIN_HOME}/.kube"
  install -m 0600 -o "${ADMIN_USER}" -g "${ADMIN_USER}" /etc/kubernetes/admin.conf "${ADMIN_HOME}/.kube/config"
  grep -q 'kubectl completion bash' "${ADMIN_HOME}/.bashrc" 2>/dev/null || \
    echo 'source <(kubectl completion bash); alias k=kubectl; complete -o default -F __start_kubectl k' >> "${ADMIN_HOME}/.bashrc"
  log "kubeconfig installed for ${ADMIN_USER}"
fi

log "Waiting for API server readiness"
for _ in $(seq 1 60); do kubectl get --raw='/readyz' >/dev/null 2>&1 && break; sleep 5; done
kubectl get --raw='/readyz' >/dev/null || die "API server not ready"

if kubectl -n kube-system get daemonset kube-proxy >/dev/null 2>&1; then
  die "kube-proxy DaemonSet exists; this cluster expects Cilium kube-proxy replacement"
fi
log "Control plane initialised (NotReady until Cilium is installed)"
kubectl get nodes -o wide
