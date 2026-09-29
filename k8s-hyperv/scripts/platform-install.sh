#!/usr/bin/env bash
# =============================================================================
#  platform-install.sh - cluster platform layer (run as root on the control plane, idempotent)
#
#    1. CLIs (sha256-verified): helm, cilium, hubble, istioctl (+ Istio samples)
#    2. Gateway API CRDs (standard channel)            - must precede Cilium
#    3. Cilium (eBPF, kube-proxy replacement, native routing, Gateway API, Hubble relay/UI/metrics)
#    4. MetalLB (L2 mode) + IPAddressPool from the LAN
#    5. Istio ambient profile (istiod + istio-cni + ztunnel); sidecar injection also available
#    6. Lab content:
#         Gateway "cilium-gw" (class cilium) -> hubble.<domain>, echo.<domain>
#         Gateway "istio-gw"  (class istio)  -> httpbin.<domain> (ambient + waypoint)
#         namespaces mesh-sidecar (sidecar mode) and mesh-ambient (ambient mode)
#
#  Usage: sudo CP_IP=192.168.1.200 METALLB_POOL=192.168.1.220-192.168.1.239 ./platform-install.sh
# =============================================================================
set -euo pipefail

# ------------------------------------------------------------- configuration
CP_IP="${CP_IP:?CP_IP (API server address) is required}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
HELM_VERSION="${HELM_VERSION:-v4.3.0}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.6.1}"
CILIUM_VERSION="${CILIUM_VERSION:-1.20.2}"
CILIUM_CLI_VERSION="${CILIUM_CLI_VERSION:-v0.20.1}"
HUBBLE_CLI_VERSION="${HUBBLE_CLI_VERSION:-v1.19.4}"
METALLB_VERSION="${METALLB_VERSION:-0.16.1}"
ISTIO_VERSION="${ISTIO_VERSION:-1.31.1}"
METALLB_POOL="${METALLB_POOL:?METALLB_POOL (e.g. 192.168.1.220-192.168.1.239) is required}"
CILIUM_GATEWAY_IP="${CILIUM_GATEWAY_IP:-}"
ISTIO_GATEWAY_IP="${ISTIO_GATEWAY_IP:-}"
LAB_DOMAIN="${LAB_DOMAIN:-lab.local}"
DEPLOY_LAB_CONTENT="${DEPLOY_LAB_CONTENT:-true}"

LAB_DIR=/etc/kubernetes/lab
ISTIO_HOME="/opt/istio-${ISTIO_VERSION}"
export KUBECONFIG=/etc/kubernetes/admin.conf
export PATH="/usr/local/bin:${PATH}"
export HELM_CACHE_HOME=/root/.cache/helm HELM_CONFIG_HOME=/root/.config/helm HELM_DATA_HOME=/root/.local/share/helm

log()  { printf '\n\033[1;34m[platform]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[platform] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[platform] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "failed at line ${LINENO}: ${BASH_COMMAND}"' ERR
[[ ${EUID} -eq 0 ]] || die "must run as root"
install -d -m 0700 "${LAB_DIR}"

retry() {  # retry <attempts> <sleep> <cmd...>
  local n="$1" s="$2"; shift 2
  for ((i = 1; i <= n; i++)); do "$@" && return 0; sleep "${s}"; done
  return 1
}

# Download + SHA256 verification (compares hashes directly; works with any sum-file format)
fetch_verified() {  # url sha_url dest
  local url="$1" sha_url="$2" dest="$3" expected actual
  expected="$(curl -fsSL "${sha_url}" | awk '{print $1; exit}')"
  [[ "${expected}" =~ ^[a-f0-9]{64}$ ]] || die "no valid checksum at ${sha_url}"
  curl -fsSL --retry 3 -o "${dest}" "${url}"
  actual="$(sha256sum "${dest}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] || die "checksum mismatch for ${url}"
}

# ------------------------------------------------------------- 1. CLIs
log "1/6 Installing CLIs"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

if ! helm version --short 2>/dev/null | grep -q "^${HELM_VERSION}"; then
  fetch_verified "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
                 "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" "${TMP}/helm.tgz"
  tar -xzf "${TMP}/helm.tgz" -C "${TMP}" linux-amd64/helm
  install -m 0755 "${TMP}/linux-amd64/helm" /usr/local/bin/helm
fi
if ! cilium version --client 2>/dev/null | grep -q "cilium-cli: ${CILIUM_CLI_VERSION}"; then
  base="https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz"
  fetch_verified "${base}" "${base}.sha256sum" "${TMP}/cilium.tgz"
  tar --no-same-owner -xzf "${TMP}/cilium.tgz" -C "${TMP}" cilium
  install -m 0755 -o root -g root "${TMP}/cilium" /usr/local/bin/cilium
fi
if ! hubble version 2>/dev/null | grep -q "${HUBBLE_CLI_VERSION#v}"; then
  base="https://github.com/cilium/hubble/releases/download/${HUBBLE_CLI_VERSION}/hubble-linux-amd64.tar.gz"
  fetch_verified "${base}" "${base}.sha256sum" "${TMP}/hubble.tgz"
  tar --no-same-owner -xzf "${TMP}/hubble.tgz" -C "${TMP}" hubble
  install -m 0755 -o root -g root "${TMP}/hubble" /usr/local/bin/hubble
fi
if [[ ! -x "${ISTIO_HOME}/bin/istioctl" ]]; then
  base="https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz"
  fetch_verified "${base}" "${base}.sha256" "${TMP}/istio.tgz"
  tar --no-same-owner --no-same-permissions -xzf "${TMP}/istio.tgz" -C /opt
fi
# root's tar keeps archive owners/modes (the Istio tree ships as 0750), which hides istioctl
# from non-root users. Normalise on every run so existing installs are repaired too.
chown -R root:root "${ISTIO_HOME}"
chmod -R a+rX "${ISTIO_HOME}"
chown root:root /usr/local/bin/cilium /usr/local/bin/hubble /usr/local/bin/helm
chmod 0755 /usr/local/bin/cilium /usr/local/bin/hubble /usr/local/bin/helm
ln -sfn "${ISTIO_HOME}/bin/istioctl" /usr/local/bin/istioctl
ln -sfn "${ISTIO_HOME}" /opt/istio            # samples at /opt/istio/samples for practice
for bin in kubectl cilium hubble istioctl helm; do
  "${bin}" completion bash > "/etc/bash_completion.d/${bin}" 2>/dev/null || true
done
echo "  helm $(helm version --short) | $(cilium version --client 2>/dev/null | head -1) | hubble $(hubble version | awk '{print $2}') | istioctl $(istioctl version --remote=false 2>/dev/null)"

# ------------------------------------------------------------- 2. Gateway API CRDs
log "2/6 Gateway API ${GATEWAY_API_VERSION} CRDs (standard channel)"
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
kubectl wait --for=condition=Established --timeout=120s \
  crd/gatewayclasses.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io crd/grpcroutes.gateway.networking.k8s.io \
  crd/referencegrants.gateway.networking.k8s.io crd/tlsroutes.gateway.networking.k8s.io >/dev/null

# ------------------------------------------------------------- 3. Cilium
log "3/6 Cilium ${CILIUM_VERSION} (eBPF kube-proxy replacement, native routing, Gateway API, Hubble)"
cat > "${LAB_DIR}/cilium-values.yaml" <<EOF
# --- datapath: eBPF, no kube-proxy
kubeProxyReplacement: true
k8sServiceHost: ${CP_IP}
k8sServicePort: 6443
ipam:
  mode: kubernetes                 # use the per-node podCIDRs kubeadm allocates from ${POD_CIDR}
routingMode: native                # all nodes share one L2 segment: no VXLAN encapsulation
ipv4NativeRoutingCIDR: ${POD_CIDR}
autoDirectNodeRoutes: true
enableIPv4Masquerade: true
bpf:
  masquerade: false                # Istio ambient: BPF masquerade breaks link-local health probes
# --- Istio coexistence (required with kubeProxyReplacement=true)
socketLB:
  hostNamespaceOnly: true          # keep socket-LB out of pod netns so sidecars/ztunnel see real VIPs
cni:
  exclusive: false                 # let istio-cni chain onto 05-cilium.conflist
# --- L7 / Gateway API
l7Proxy: true
gatewayAPI:
  enabled: true
  enableAlpn: true
  enableAppProtocol: true
l2announcements:
  enabled: false                   # MetalLB owns L2 announcements in this lab
# --- small-cluster sizing
operator:
  replicas: 1
  prometheus:
    enabled: true
prometheus:
  enabled: true
# --- observability
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
  metrics:
    enableOpenMetrics: true
    enabled:
      - dns
      - drop
      - tcp
      - flow
      - port-distribution
      - icmp
      - "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction"
EOF
helm upgrade --install cilium cilium --repo https://helm.cilium.io --version "${CILIUM_VERSION}" \
  --namespace kube-system -f "${LAB_DIR}/cilium-values.yaml"
cilium status --wait --wait-duration 10m >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=600s
kubectl -n kube-system rollout status deployment/coredns --timeout=300s
kubectl -n kube-system rollout status deployment/hubble-relay --timeout=300s
kubectl -n kube-system rollout status deployment/hubble-ui --timeout=300s
cilium status | sed -n '1,12p'

# ------------------------------------------------------------- 4. MetalLB
log "4/6 MetalLB ${METALLB_VERSION} (L2 mode, pool ${METALLB_POOL})"
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
EOF
helm upgrade --install metallb metallb --repo https://metallb.github.io/metallb --version "${METALLB_VERSION}" \
  --namespace metallb-system --set frrk8s.enabled=false --set speaker.frr.enabled=false
kubectl -n metallb-system rollout status deployment/metallb-controller --timeout=300s
kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout=300s
cat > "${LAB_DIR}/metallb-pool.yaml" <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lan-pool
  namespace: metallb-system
spec:
  addresses:
    - ${METALLB_POOL}
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lan-l2
  namespace: metallb-system
spec:
  ipAddressPools: [ lan-pool ]
EOF
# The validating webhook needs a few seconds after rollout before it accepts requests
retry 30 5 kubectl apply -f "${LAB_DIR}/metallb-pool.yaml" >/dev/null || die "MetalLB pool could not be applied"

# ------------------------------------------------------------- 5. Istio
log "5/6 Istio ${ISTIO_VERSION} (ambient profile: istiod + istio-cni + ztunnel)"
cat > "${LAB_DIR}/istio-ambient.yaml" <<'EOF'
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: lab
spec:
  # "ambient" installs istiod, istio-cni and ztunnel. Sidecar injection keeps working for
  # namespaces labelled istio-injection=enabled, so both data plane modes run side by side.
  profile: ambient
  meshConfig:
    accessLogFile: /dev/stdout
  components:
    pilot:
      k8s:
        resources:
          requests: { cpu: 200m, memory: 512Mi }   # default 500m/2Gi is too much for 4 GB lab nodes
  values:
    cni:
      cniConfDir: /etc/cni/net.d     # CRI-O network_dir
      cniBinDir: /opt/cni/bin        # CRI-O plugin_dirs
EOF
istioctl x precheck || warn "istioctl precheck reported issues (see above)"
istioctl install -y -f "${LAB_DIR}/istio-ambient.yaml"
kubectl -n istio-system rollout status deployment/istiod --timeout=300s
kubectl -n istio-system rollout status daemonset/istio-cni-node --timeout=300s
kubectl -n istio-system rollout status daemonset/ztunnel --timeout=300s
retry 30 5 kubectl wait --for=condition=Accepted gatewayclass/istio --timeout=10s >/dev/null
retry 30 5 kubectl wait --for=condition=Accepted gatewayclass/cilium --timeout=10s >/dev/null

# ------------------------------------------------------------- 6. lab content
# Pins the Gateway's LoadBalancer IP. spec.infrastructure.annotations is propagated to the
# generated Service by both Cilium and Istio; if an implementation ignores it, annotate directly.
pin_gateway_ip() {  # ns gateway ip
  local ns="$1" gw="$2" ip="$3" cur svc
  [[ -n "${ip}" ]] || return 0
  retry 60 5 kubectl -n "${ns}" wait --for=condition=Programmed "gateway/${gw}" --timeout=5s >/dev/null || true
  cur="$(kubectl -n "${ns}" get gateway "${gw}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  [[ "${cur}" == "${ip}" ]] && return 0
  svc="$(kubectl -n "${ns}" get svc -l "gateway.networking.k8s.io/gateway-name=${gw}" -o name 2>/dev/null | head -n1)"
  [[ -n "${svc}" ]] || svc="$(kubectl -n "${ns}" get svc -l "io.cilium.gateway/owning-gateway=${gw}" -o name 2>/dev/null | head -n1)"
  if [[ -n "${svc}" ]]; then
    warn "${gw} got '${cur:-none}', re-pinning ${svc} to ${ip}"
    kubectl -n "${ns}" annotate "${svc}" "metallb.io/loadBalancerIPs=${ip}" --overwrite >/dev/null
    retry 30 5 bash -c "[[ \"\$(kubectl -n ${ns} get gateway ${gw} -o jsonpath='{.status.addresses[0].value}')\" == '${ip}' ]]" \
      || warn "${gw} is not on ${ip}; check 'kubectl -n ${ns} describe gateway ${gw}'"
  fi
}

if [[ "${DEPLOY_LAB_CONTENT}" == "true" ]]; then
  log "6/6 Lab content: gateways, sidecar + ambient namespaces, sample apps"
  SAMPLES="${ISTIO_HOME}/samples"

  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata: { name: infra-gateways }
---
apiVersion: v1
kind: Namespace
metadata: { name: demo-cilium }
---
apiVersion: v1
kind: Namespace
metadata:
  name: mesh-sidecar
  labels: { istio-injection: enabled }            # Istio sidecar mode
---
apiVersion: v1
kind: Namespace
metadata:
  name: mesh-ambient
  labels: { istio.io/dataplane-mode: ambient }    # Istio ambient mode (ztunnel L4 mTLS)
---
apiVersion: v1
kind: Namespace
metadata: { name: istio-ingress }
EOF

  # Sample workloads (fully-qualified images from the Istio release samples)
  for ns in demo-cilium mesh-sidecar mesh-ambient; do
    kubectl -n "${ns}" apply -f "${SAMPLES}/httpbin/httpbin.yaml" >/dev/null
  done
  for ns in mesh-sidecar mesh-ambient; do
    kubectl -n "${ns}" apply -f "${SAMPLES}/curl/curl.yaml" >/dev/null
  done
  for ns in demo-cilium mesh-sidecar mesh-ambient; do
    kubectl -n "${ns}" rollout status deployment/httpbin --timeout=300s
  done
  kubectl -n mesh-sidecar rollout status deployment/curl --timeout=300s
  kubectl -n mesh-ambient rollout status deployment/curl --timeout=300s

  # L7 for ambient: a namespace-wide waypoint proxy
  istioctl waypoint apply -n mesh-ambient --enroll-namespace --wait

  # --- Gateway (class cilium): Hubble UI + echo app
  kubectl apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cilium-gw
  namespace: infra-gateways
spec:
  gatewayClassName: cilium
  infrastructure:
    annotations:
      metallb.io/loadBalancerIPs: "${CILIUM_GATEWAY_IP}"
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces: { from: All }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hubble-ui
  namespace: kube-system
spec:
  parentRefs: [ { name: cilium-gw, namespace: infra-gateways } ]
  hostnames: [ "hubble.${LAB_DOMAIN}" ]
  rules:
    - backendRefs: [ { name: hubble-ui, port: 80 } ]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo
  namespace: demo-cilium
spec:
  parentRefs: [ { name: cilium-gw, namespace: infra-gateways } ]
  hostnames: [ "echo.${LAB_DOMAIN}" ]
  rules:
    - backendRefs: [ { name: httpbin, port: 8000 } ]
EOF

  # --- Gateway (class istio): httpbin in the ambient mesh
  kubectl apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: istio-gw
  namespace: istio-ingress
spec:
  gatewayClassName: istio
  infrastructure:
    annotations:
      metallb.io/loadBalancerIPs: "${ISTIO_GATEWAY_IP}"
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces: { from: All }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin
  namespace: mesh-ambient
spec:
  parentRefs: [ { name: istio-gw, namespace: istio-ingress } ]
  hostnames: [ "httpbin.${LAB_DOMAIN}" ]
  rules:
    - backendRefs: [ { name: httpbin, port: 8000 } ]
EOF

  pin_gateway_ip infra-gateways cilium-gw "${CILIUM_GATEWAY_IP}"
  pin_gateway_ip istio-ingress  istio-gw  "${ISTIO_GATEWAY_IP}"
  kubectl -n infra-gateways wait --for=condition=Programmed gateway/cilium-gw --timeout=300s >/dev/null
  kubectl -n istio-ingress  wait --for=condition=Programmed gateway/istio-gw  --timeout=300s >/dev/null
fi

log "Platform ready"
kubectl get gatewayclass
kubectl get gateway -A
kubectl get svc -A --field-selector spec.type=LoadBalancer
