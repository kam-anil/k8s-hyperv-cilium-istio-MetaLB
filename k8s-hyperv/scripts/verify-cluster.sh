#!/usr/bin/env bash
# =============================================================================
#  verify-cluster.sh - post-install validation (run as the admin user on the CP)
#    1. nodes Ready, Ubuntu 26.04, CRI-O runtime
#    2. Cilium: healthy, kube-proxy replacement active, no kube-proxy, Hubble relay/UI/flows
#    3. Gateway API classes, MetalLB, Istio control plane + ambient data plane
#    4. NGINX spread across workers + per-worker Service/DNS/egress probes
#    5. Istio sidecar mode (mTLS) and ambient mode (HBONE + waypoint)
#    6. Gateways reachable on their MetalLB IPs (Cilium + Istio)
#  Usage: EXPECTED_NODES=3 WORKERS="k8s-node-01 k8s-node-02" ./verify-cluster.sh
# =============================================================================
set -euo pipefail

EXPECTED_NODES="${EXPECTED_NODES:-3}"
WORKERS="${WORKERS:-$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}')}"
EXPECTED_OS="${EXPECTED_OS:-Ubuntu 26.04}"
EXPECTED_RUNTIME="${EXPECTED_RUNTIME:-cri-o}"
CILIUM_GATEWAY_IP="${CILIUM_GATEWAY_IP:-}"
ISTIO_GATEWAY_IP="${ISTIO_GATEWAY_IP:-}"
LAB_DOMAIN="${LAB_DOMAIN:-lab.local}"
RUN_CONNECTIVITY_TEST="${RUN_CONNECTIVITY_TEST:-false}"
NS="${NS:-smoke-test}"
NGINX_IMAGE="${NGINX_IMAGE:-docker.io/library/nginx:stable-alpine}"
CURL_IMAGE="${CURL_IMAGE:-docker.io/curlimages/curl:8.16.0}"
EXTERNAL_URL="${EXTERNAL_URL:-https://dl.k8s.io/release/stable.txt}"
KEEP_TEST_WORKLOAD="${KEEP_TEST_WORKLOAD:-false}"
export PATH="/usr/local/bin:${PATH}"
if ! istioctl version --remote=false >/dev/null 2>&1; then
  echo "istioctl is not executable by $(id -un) - run: sudo chmod -R a+rX /opt/istio-*" >&2
fi

PASS=0; FAIL=0
ok()   { printf '  \033[1;32m[PASS]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
hdr()  { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "${desc}"; else bad "${desc}"; fi; }
PF_PID=""
cleanup() {
  [[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null || true
  [[ "${KEEP_TEST_WORKLOAD}" == "true" ]] || kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ------------------------------------------------------------- 1. nodes
hdr "Nodes"
check "all nodes report Ready" kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide
count="$(kubectl get nodes --no-headers | wc -l)"
[[ "${count}" -eq "${EXPECTED_NODES}" ]] && ok "${count}/${EXPECTED_NODES} nodes registered" || bad "found ${count} nodes, expected ${EXPECTED_NODES}"
while IFS=$'\t' read -r name os runtime; do
  [[ "${os}" == *"${EXPECTED_OS}"* ]]      && ok "${name}: ${os}"        || bad "${name}: OS is '${os}'"
  [[ "${runtime}" == "${EXPECTED_RUNTIME}"* ]] && ok "${name}: ${runtime}" || bad "${name}: runtime is '${runtime}'"
done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.osImage}{"\t"}{.status.nodeInfo.containerRuntimeVersion}{"\n"}{end}')

# ------------------------------------------------------------- 2. Cilium + Hubble
hdr "Cilium (eBPF) and Hubble"
check "cilium status: all components healthy" cilium status --wait --wait-duration 5m
if kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1; then bad "kube-proxy DaemonSet present"; else ok "kube-proxy not deployed"; fi
agent_status="$(kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null || true)"
kpr="$(awk '/^KubeProxyReplacement:/{sub(/^KubeProxyReplacement:[ \t]*/,""); print}' <<< "${agent_status}")"
[[ "${kpr}" == True* ]] && ok "KubeProxyReplacement: ${kpr}" || bad "KubeProxyReplacement: '${kpr}'"
routing="$(awk '/^Routing:/{sub(/^Routing:[ \t]*/,""); print}' <<< "${agent_status}")"
[[ "${routing}" == *Native* ]] && ok "Routing: ${routing}" || bad "Routing: '${routing}'"
cfg="$(kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.bpf-lb-sock-hostns-only} {.data.cni-exclusive} {.data.enable-gateway-api}')"
[[ "${cfg}" == "true false true" ]] && ok "Istio/Gateway settings (sock-hostns-only=true, cni-exclusive=false, gateway-api=true)" || bad "cilium-config: '${cfg}'"
check "coredns rolled out"      kubectl -n kube-system rollout status deployment/coredns --timeout=180s
check "hubble-relay rolled out" kubectl -n kube-system rollout status deployment/hubble-relay --timeout=180s
check "hubble-ui rolled out"    kubectl -n kube-system rollout status deployment/hubble-ui --timeout=180s
cilium hubble port-forward >/dev/null 2>&1 & PF_PID=$!
sleep 5
check "hubble CLI -> relay (hubble status)" hubble status --server localhost:4245
flows="$(hubble observe --server localhost:4245 --last 50 -o compact 2>/dev/null | wc -l || true)"
[[ "${flows}" -gt 0 ]] && ok "Hubble is recording flows (${flows} recent)" || bad "no Hubble flows returned"

# ------------------------------------------------------------- 3. Gateway API, MetalLB, Istio
hdr "Gateway API, MetalLB, Istio"
check "GatewayClass cilium Accepted" kubectl wait --for=condition=Accepted gatewayclass/cilium --timeout=60s
check "GatewayClass istio Accepted"  kubectl wait --for=condition=Accepted gatewayclass/istio --timeout=60s
check "MetalLB controller ready"     kubectl -n metallb-system rollout status deployment/metallb-controller --timeout=120s
check "MetalLB speakers ready"       kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout=120s
check "MetalLB IPAddressPool present" kubectl -n metallb-system get ipaddresspool lan-pool
check "istiod ready"                 kubectl -n istio-system rollout status deployment/istiod --timeout=120s
check "istio-cni on all nodes"       kubectl -n istio-system rollout status daemonset/istio-cni-node --timeout=120s
check "ztunnel on all nodes"         kubectl -n istio-system rollout status daemonset/ztunnel --timeout=120s
istioctl version 2>/dev/null | sed 's/^/  /' || true

# ------------------------------------------------------------- 4. generic workload
hdr "Test workload (${NGINX_IMAGE})"
kubectl delete namespace "${NS}" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
worker_count="$(wc -w <<< "${WORKERS}")"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: { name: nginx, namespace: ${NS}, labels: { app: nginx } }
spec:
  replicas: ${worker_count}
  selector: { matchLabels: { app: nginx } }
  template:
    metadata: { labels: { app: nginx } }
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector: { matchLabels: { app: nginx } }
      containers:
        - name: nginx
          image: ${NGINX_IMAGE}
          ports: [ { containerPort: 80 } ]
          readinessProbe: { httpGet: { path: /, port: 80 }, periodSeconds: 3 }
          resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 64Mi } }
---
apiVersion: v1
kind: Service
metadata: { name: nginx, namespace: ${NS} }
spec:
  selector: { app: nginx }
  ports: [ { port: 80, targetPort: 80 } ]
EOF
check "nginx deployment available" kubectl -n "${NS}" rollout status deployment/nginx --timeout=240s
kubectl -n "${NS}" get pods -o wide
placed="$(kubectl -n "${NS}" get pods -l app=nginx -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | tr '\n' ' ')"
for w in ${WORKERS}; do
  [[ " ${placed} " == *" ${w} "* ]] && ok "nginx replica scheduled on ${w}" || bad "no nginx replica on ${w}"
done

hdr "Connectivity from each worker (eBPF service LB, DNS, egress)"
for w in ${WORKERS}; do
  pod="probe-${w}"
  kubectl -n "${NS}" run "${pod}" --image="${CURL_IMAGE}" --restart=Never \
    --overrides="{\"spec\":{\"nodeName\":\"${w}\"}}" --command -- sh -c "
      curl -fsS -o /dev/null -m 10 http://nginx.${NS}.svc.cluster.local && echo SVC_OK
      nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo DNS_OK
      curl -fsS -o /dev/null -m 15 ${EXTERNAL_URL} && echo EGRESS_OK
      exit 0" >/dev/null
  kubectl -n "${NS}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod}" --timeout=180s >/dev/null 2>&1 || true
  out="$(kubectl -n "${NS}" logs "${pod}" 2>/dev/null || true)"
  [[ "${out}" == *SVC_OK* ]]    && ok "${w}: pod -> ClusterIP (Cilium eBPF LB)" || bad "${w}: Service unreachable"
  [[ "${out}" == *DNS_OK* ]]    && ok "${w}: CoreDNS resolution"                || bad "${w}: DNS lookup failed"
  [[ "${out}" == *EGRESS_OK* ]] && ok "${w}: external egress"                   || bad "${w}: no external egress"
done

# ------------------------------------------------------------- 5. Istio data plane modes
hdr "Istio sidecar mode (namespace mesh-sidecar)"
if kubectl get ns mesh-sidecar >/dev/null 2>&1; then
  ctrs="$(kubectl -n mesh-sidecar get pod -l app=httpbin -o jsonpath='{.items[0].spec.containers[*].name} {.items[0].spec.initContainers[*].name}')"
  [[ "${ctrs}" == *istio-proxy* ]] && ok "httpbin has istio-proxy sidecar" || bad "no sidecar in mesh-sidecar/httpbin (${ctrs})"
  code="$(kubectl -n mesh-sidecar exec deploy/curl -c curl -- curl -s -o /dev/null -w '%{http_code}' http://httpbin:8000/get 2>/dev/null || true)"
  [[ "${code}" == "200" ]] && ok "curl -> httpbin via sidecars: HTTP 200" || bad "sidecar request returned '${code}'"
  hdrs="$(kubectl -n mesh-sidecar exec deploy/curl -c curl -- curl -s http://httpbin:8000/headers 2>/dev/null || true)"
  [[ "${hdrs}" == *X-Forwarded-Client-Cert* ]] && ok "mTLS between sidecars (X-Forwarded-Client-Cert present)" || bad "no XFCC header - mTLS not observed"
else
  bad "namespace mesh-sidecar missing"
fi

hdr "Istio ambient mode (namespace mesh-ambient)"
if kubectl get ns mesh-ambient >/dev/null 2>&1; then
  ctrs="$(kubectl -n mesh-ambient get pod -l app=httpbin -o jsonpath='{.items[0].spec.containers[*].name}')"
  [[ "${ctrs}" != *istio-proxy* ]] && ok "httpbin runs without a sidecar (${ctrs})" || bad "unexpected sidecar in ambient namespace"
  # Column layout of `ztunnel-config workload` varies by release, so match the row and the
  # protocol word rather than fixed positions; fall back to JSON output.
  zt="$(istioctl ztunnel-config workload 2>/dev/null || true)"
  row="$(grep -E '^mesh-ambient[[:space:]]+httpbin' <<< "${zt}" | head -n 1 || true)"
  if grep -qw 'HBONE' <<< "${row}"; then
    hbone="HBONE"
  else
    ztj="$(istioctl ztunnel-config workload -o json 2>/dev/null || true)"
    hbone="$(jq -r '[.. | objects | select((.namespace? == "mesh-ambient") and ((.name? // "") | startswith("httpbin"))) | .protocol? // empty][0] // empty' <<< "${ztj}" 2>/dev/null || true)"
  fi
  [[ "${hbone}" == "HBONE" ]] && ok "ztunnel captures httpbin (protocol HBONE)" || bad "ztunnel protocol for httpbin: '${hbone}' (row: ${row:-none})"
  check "waypoint proxy Programmed" kubectl -n mesh-ambient wait --for=condition=Programmed gateway/waypoint --timeout=120s
  code="$(kubectl -n mesh-ambient exec deploy/curl -- curl -s -o /dev/null -w '%{http_code}' http://httpbin:8000/get 2>/dev/null || true)"
  [[ "${code}" == "200" ]] && ok "curl -> httpbin via ztunnel + waypoint: HTTP 200" || bad "ambient request returned '${code}'"
else
  bad "namespace mesh-ambient missing"
fi

# ------------------------------------------------------------- 6. north-south via MetalLB
hdr "Gateways on MetalLB addresses"
gw_check() {  # ns gateway expected_ip host path
  local ns="$1" gw="$2" want="$3" host="$4" path="$5" addr code
  addr="$(kubectl -n "${ns}" get gateway "${gw}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  if [[ -z "${addr}" ]]; then bad "${gw}: no address assigned"; return; fi
  [[ -z "${want}" || "${addr}" == "${want}" ]] && ok "${gw}: MetalLB address ${addr}" || bad "${gw}: got ${addr}, expected ${want}"
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' --resolve "${host}:80:${addr}" "http://${host}${path}" || true)"
  [[ "${code}" == "200" ]] && ok "http://${host}${path} -> ${code}" || bad "http://${host}${path} -> '${code}'"
}
gw_check infra-gateways cilium-gw "${CILIUM_GATEWAY_IP}" "hubble.${LAB_DOMAIN}"  "/"
gw_check infra-gateways cilium-gw "${CILIUM_GATEWAY_IP}" "echo.${LAB_DOMAIN}"    "/get"
gw_check istio-ingress  istio-gw  "${ISTIO_GATEWAY_IP}"  "httpbin.${LAB_DOMAIN}" "/get"

# ------------------------------------------------------------- optional: full Cilium test suite
if [[ "${RUN_CONNECTIVITY_TEST}" == "true" ]]; then
  hdr "cilium connectivity test (long)"
  check "cilium connectivity test" cilium connectivity test --test-namespace cilium-test --timeout 20m
  kubectl delete namespace cilium-test --ignore-not-found --wait=false >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------- summary
hdr "Summary"
printf '  %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]] || exit 1
