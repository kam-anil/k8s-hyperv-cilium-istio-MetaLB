#!/usr/bin/env bash
# =============================================================================
#  node-prep.sh - prepare an Ubuntu 26.04 node for kubeadm + CRI-O + Cilium + Istio
#  (run as root, idempotent)
#    * swap fully disabled            * overlay / br_netfilter + sysctl (+ Cilium rp_filter fix)
#    * CRI-O from isv:cri-o:stable    * pkgs.k8s.io repo + held kubelet/kubeadm/kubectl
#    * light OS hardening
#  Usage: sudo KUBE_VERSION=v1.36.5 NODE_IP=192.168.1.200 ./node-prep.sh
# =============================================================================
set -euo pipefail

# ------------------------------------------------------------- configuration
KUBE_VERSION="${KUBE_VERSION:-}"          # e.g. v1.36.5 ; empty = latest patch of KUBE_MINOR_DEFAULT
KUBE_MINOR_DEFAULT="${KUBE_MINOR_DEFAULT:-v1.36}"
NODE_IP="${NODE_IP:-}"                    # pins kubelet --node-ip (recommended)
CRIO_SOCKET="${CRIO_SOCKET:-unix:///var/run/crio/crio.sock}"
CRIO_REPO_BASE="${CRIO_REPO_BASE:-https://download.opensuse.org/repositories/isv:/cri-o:/stable:}"
# CRI-O's default capability set omits NET_RAW (containerd includes it). Ping-based
# troubleshooting and several Cilium connectivity tests expect it, so add it back.
CRIO_EXTRA_CAPS="${CRIO_EXTRA_CAPS:-NET_RAW}"
INSTALL_HYPERV_TOOLS="${INSTALL_HYPERV_TOOLS:-true}"
EXPECTED_UBUNTU="${EXPECTED_UBUNTU:-26.04}"

# ------------------------------------------------------------- helpers
log()  { printf '\033[1;34m[node-prep]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[node-prep] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[node-prep] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

[[ ${EUID} -eq 0 ]] || die "must run as root"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -q -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# shellcheck source=/dev/null
. /etc/os-release
[[ "${VERSION_ID}" == "${EXPECTED_UBUNTU}" ]] || warn "expected Ubuntu ${EXPECTED_UBUNTU}, found ${VERSION_ID}"
command -v cloud-init >/dev/null && { cloud-init status --wait >/dev/null 2>&1 || true; }

if [[ -z "${KUBE_VERSION}" ]]; then
  KUBE_VERSION="$(curl -fsSL "https://dl.k8s.io/release/stable-${KUBE_MINOR_DEFAULT#v}.txt")"
fi
[[ "${KUBE_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid KUBE_VERSION '${KUBE_VERSION}'"
KUBE_MINOR="${KUBE_VERSION%.*}"            # v1.36 - CRI-O minor must match
log "Kubernetes ${KUBE_VERSION}, CRI-O stream ${KUBE_MINOR}"

# ------------------------------------------------------------- 1. swap
log "Disabling swap"
swapoff -a
sed -ri '/\sswap\s/ s/^([^#])/#\1/' /etc/fstab
while read -r unit; do
  [[ -n "${unit}" ]] && systemctl mask --now "${unit}" >/dev/null 2>&1 || true
done < <(systemctl list-units --type=swap --all --plain --no-legend 2>/dev/null | awk '{print $1}')
systemctl mask swap.target >/dev/null 2>&1 || true
if [[ -e /usr/lib/systemd/zram-generator.conf || -e /etc/systemd/zram-generator.conf ]]; then
  mkdir -p /etc/systemd && printf '# disabled for Kubernetes\n' > /etc/systemd/zram-generator.conf
fi
[[ -z "$(swapon --noheadings --show)" ]] || die "swap still active"

# ------------------------------------------------------------- 2. kernel modules + sysctl
log "Kernel modules and sysctl"
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
# --- required by Kubernetes networking / kubeadm preflight
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
# --- headroom for many pods / watches (Envoy, ztunnel, sidecars)
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 524288
EOF
# systemd >= 245 sets rp_filter on every new interface, which breaks Cilium's lxc*
# endpoints. Cilium's system requirements call for this override.
cat > /etc/sysctl.d/99-zz-override-cilium-rp-filter.conf <<'EOF'
net.ipv4.conf.lxc*.rp_filter = 0
EOF
cat > /etc/sysctl.d/90-hardening.conf <<'EOF'
# --- host hardening compatible with Cilium / Istio
net.ipv4.conf.all.accept_redirects     = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects       = 0
net.ipv4.conf.default.send_redirects   = 0
net.ipv4.conf.all.accept_source_route  = 0
net.ipv6.conf.all.accept_redirects     = 0
net.ipv4.tcp_syncookies                = 1
kernel.dmesg_restrict                  = 1
kernel.kptr_restrict                   = 1
EOF
sysctl --system >/dev/null 2>&1 || warn "sysctl --system reported errors (glob keys are applied by systemd-sysctl for new interfaces)"
for k in net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward; do
  [[ "$(sysctl -n "${k}")" == "1" ]] || die "sysctl ${k} != 1"
done

# ------------------------------------------------------------- 3. base packages
log "Installing base packages"
apt-get update -q
apt-get install "${APT_OPTS[@]}" ca-certificates curl gpg apt-transport-https \
  conntrack socat ethtool ipset iptables jq
if [[ "${INSTALL_HYPERV_TOOLS}" == "true" ]]; then
  apt-get install "${APT_OPTS[@]}" linux-cloud-tools-virtual linux-tools-virtual \
    || warn "Hyper-V tools not installed (non-fatal)"
fi

# A node previously built with containerd: make sure it can't compete with CRI-O
if systemctl list-unit-files containerd.service >/dev/null 2>&1 && systemctl is-enabled --quiet containerd 2>/dev/null; then
  warn "containerd found - stopping and disabling it (CRI-O is the runtime now)"
  systemctl disable --now containerd || true
fi

# ------------------------------------------------------------- 4. repositories
add_repo() {  # name url-base
  local name="$1" base="$2"
  curl -fsSL "${base}/Release.key" | gpg --dearmor --batch --yes -o "/etc/apt/keyrings/${name}-apt-keyring.gpg"
  chmod 0644 "/etc/apt/keyrings/${name}-apt-keyring.gpg"
  echo "deb [signed-by=/etc/apt/keyrings/${name}-apt-keyring.gpg] ${base}/ /" > "/etc/apt/sources.list.d/${name}.list"
}
install -d -m 0755 /etc/apt/keyrings
log "Configuring pkgs.k8s.io ${KUBE_MINOR} and CRI-O ${KUBE_MINOR} repositories"
add_repo kubernetes "https://pkgs.k8s.io/core:/stable:/${KUBE_MINOR}/deb"
add_repo cri-o "${CRIO_REPO_BASE}/${KUBE_MINOR}/deb"
apt-get update -q

# ------------------------------------------------------------- 5. packages
PKG_VER="$(apt-cache madison kubeadm | awk -v v="${KUBE_VERSION#v}" '!f && $3 ~ "^"v"-" {print $3; f=1}')"
[[ -n "${PKG_VER}" ]] || die "kubeadm ${KUBE_VERSION} not found in ${KUBE_MINOR} repo"
log "Installing cri-o, cri-tools + kubelet/kubeadm/kubectl ${PKG_VER}"
# kubeadm >= 1.36.1 no longer depends on cri-tools, so crictl must be requested explicitly.
apt-mark unhold kubelet kubeadm kubectl cri-o cri-tools >/dev/null 2>&1 || true
apt-get install "${APT_OPTS[@]}" --allow-downgrades \
  cri-o cri-tools "kubelet=${PKG_VER}" "kubeadm=${PKG_VER}" "kubectl=${PKG_VER}"
apt-mark hold kubelet kubeadm kubectl cri-o cri-tools >/dev/null
command -v crictl >/dev/null || die "crictl not installed (cri-tools)"

# ------------------------------------------------------------- 6. CRI-O configuration
PAUSE_IMAGE="$(kubeadm config images list --kubernetes-version "${KUBE_VERSION}" 2>/dev/null | grep '/pause:' || true)"
[[ -n "${PAUSE_IMAGE}" ]] || PAUSE_IMAGE="registry.k8s.io/pause:3.10.1"
CAPS=(CHOWN DAC_OVERRIDE FSETID FOWNER SETGID SETUID SETPCAP NET_BIND_SERVICE KILL)
for c in ${CRIO_EXTRA_CAPS}; do CAPS+=("${c}"); done
CAPS_TOML="$(printf '"%s", ' "${CAPS[@]}")"; CAPS_TOML="${CAPS_TOML%, }"

log "Configuring CRI-O (systemd cgroups, pause ${PAUSE_IMAGE}, caps +${CRIO_EXTRA_CAPS:-none})"
cat > /etc/crio/crio.conf.d/20-k8s-lab.conf <<EOF
# managed by node-prep.sh
[crio.runtime]
cgroup_manager = "systemd"
default_capabilities = [ ${CAPS_TOML} ]

[crio.image]
pause_image = "${PAUSE_IMAGE}"
short_name_mode = "disabled"      # resolve short names via docker.io (enforcing | disabled only)

[crio.network]
network_dir = "/etc/cni/net.d/"
plugin_dirs = [ "/opt/cni/bin/" ]
EOF

# Unqualified image names (e.g. "nginx") resolve to Docker Hub, like containerd/Docker.
install -d -m 0755 /etc/containers/registries.conf.d
cat > /etc/containers/registries.conf.d/99-k8s-lab.conf <<'EOF'
unqualified-search-registries = ["docker.io"]
short-name-mode = "permissive"
EOF

# CRI-O ships a sample bridge CNI config. Cilium must be the only primary CNI
# (Istio CNI chains onto Cilium's conflist), so make sure no bridge config is active.
rm -f /etc/cni/net.d/*crio-bridge*.conflist /etc/cni/net.d/*flannel* 2>/dev/null || true

cat > /etc/crictl.yaml <<EOF
runtime-endpoint: ${CRIO_SOCKET}
image-endpoint: ${CRIO_SOCKET}
timeout: 10
EOF

systemctl daemon-reload
systemctl enable crio >/dev/null
systemctl restart crio
CRIO_SOCK_PATH="${CRIO_SOCKET#unix://}"
for _ in $(seq 1 30); do [[ -S "${CRIO_SOCK_PATH}" ]] && crictl info >/dev/null 2>&1 && break; sleep 2; done
[[ -S "${CRIO_SOCK_PATH}" ]] || die "CRI-O socket ${CRIO_SOCK_PATH} missing: see 'journalctl -u crio -b'"
crictl info >/dev/null 2>&1 || die "CRI-O socket exists but 'crictl info' fails: $(crictl info 2>&1 | tail -n 1)"
EFFECTIVE_CRIO="$(crio config 2>/dev/null)"
grep -qE '^\s*#?\s*cgroup_manager = "systemd"' <<< "${EFFECTIVE_CRIO}" || die "CRI-O is not using the systemd cgroup manager"

# kubelet: pin the node IP so the API advertises the LAN address
if [[ -n "${NODE_IP}" ]]; then
  echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" > /etc/default/kubelet
fi
systemctl enable kubelet >/dev/null   # crash-loops until kubeadm init/join: expected

# ------------------------------------------------------------- 7. hardening extras
log "Hardening: sshd drop-in, unattended-upgrades exclusion, journald cap"
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-k8s-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
EOF
sshd -t && systemctl try-reload-or-restart ssh.service || warn "sshd reload skipped"

cat > /etc/apt/apt.conf.d/51-k8s-no-auto-upgrade <<'EOF'
Unattended-Upgrade::Package-Blacklist { "kubelet"; "kubeadm"; "kubectl"; "cri-o"; "cri-tools"; "kubernetes-cni"; };
EOF

install -d -m 0755 /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=1G\n' > /etc/systemd/journald.conf.d/10-k8s.conf
systemctl restart systemd-journald

log "Done: $(kubeadm version -o short), $(crio --version 2>/dev/null | awk 'NR==1{print "CRI-O " $3}'), cgroup=systemd, swap off"
