#!/usr/bin/env bash
# =============================================================================
#  worker-join.sh - join this node to the cluster (run as root, idempotent)
#  The join command is read from STDIN so the token never appears in argv/ps.
#  Usage: echo "kubeadm join 1.2.3.4:6443 --token ... --discovery-token-ca-cert-hash sha256:..." \
#           | sudo NODE_NAME=k8s-node-01 ./worker-join.sh
# =============================================================================
set -euo pipefail

NODE_NAME="${NODE_NAME:-$(hostname -s)}"
CRI_SOCKET="${CRI_SOCKET:-unix:///var/run/crio/crio.sock}"

log() { printf '\033[1;34m[worker-join]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[worker-join] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "failed at line ${LINENO}: ${BASH_COMMAND}"' ERR
[[ ${EUID} -eq 0 ]] || die "must run as root"

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  log "${NODE_NAME} already joined - skipping"
  exit 0
fi

IFS= read -r JOIN_LINE || true
JOIN_LINE="${JOIN_LINE%$'\r'}"
read -r -a ARGS <<< "${JOIN_LINE}"

# Strict validation: no eval, only the expected kubeadm join shape.
[[ ${#ARGS[@]} -ge 7 && "${ARGS[0]}" == "kubeadm" && "${ARGS[1]}" == "join" ]] || die "no valid join command on stdin"
[[ "${ARGS[2]}" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || die "unexpected API endpoint '${ARGS[2]}'"
for a in "${ARGS[@]:3}"; do
  [[ "${a}" =~ ^(--token|--discovery-token-ca-cert-hash|[a-z0-9]{6}\.[a-z0-9]{16}|sha256:[a-f0-9]{64})$ ]] \
    || die "unexpected join argument"
done

log "Joining ${NODE_NAME} to ${ARGS[2]}"
kubeadm join "${ARGS[@]:2}" --node-name "${NODE_NAME}" --cri-socket "${CRI_SOCKET}"

systemctl is-active --quiet kubelet || die "kubelet not active after join"
log "${NODE_NAME} joined successfully"
