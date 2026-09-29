# =============================================================================
#  cluster.config.ps1  -  Single source of truth for the Hyper-V + kubeadm build
#  Dot-sourced by 00-Preflight, 01-Provision-HyperV, 02-Bootstrap-Cluster and 03-Manage-Lab.
#  Edit the values in this file only.
#  Note: PSScriptAnalyzer "assigned but never used" warnings are expected (dot-sourced file).
# =============================================================================

# ---------------------------------------------------------------- Hyper-V host
$SwitchName      = 'External_switch_Intel'   # External vSwitch to use / create
$NicMatch        = 'Intel'                   # Regex matched against NIC InterfaceDescription
# Everything lives under $VmRoot on the external SSD (must be NTFS or ReFS):
#   <VmRoot>\_images\                    cloud image, checksums, converted base VHDX
#   <VmRoot>\<vm>\Virtual Machines\      VM configuration (.vmcx/.vmrs)
#   <VmRoot>\<vm>\Snapshots\             checkpoint configuration
#   <VmRoot>\<vm>\<vm>.vhdx (+ .avhdx)    OS disk and checkpoint differencing disks
#   <VmRoot>\<vm>\<vm>-cidata.iso         cloud-init seed
#   <VmRoot>\known_hosts, kubeconfig
$VmRoot          = 'F:\k8s-cluster-automation'
$ImageCacheDir   = Join-Path $VmRoot '_images'
$MinFreeSpaceGB  = 40     # hard minimum free space on the drive before provisioning
$VmAutoStartDelaySec = 90 # delay VM auto-start after host boot so the USB SSD is mounted first

# ---------------------------------------------------------------- Ubuntu image
# Official Ubuntu Server 26.04 LTS (Resolute Raccoon) cloud image, amd64 baseline.
$UbuntuRelease   = '26.04'
$UbuntuBaseUrl   = "https://cloud-images.ubuntu.com/releases/$UbuntuRelease/release"
$UbuntuImageName = "ubuntu-$UbuntuRelease-server-cloudimg-amd64.img"   # qcow2
$QemuImgPath     = ''   # '' = auto-detect, or install QEMU via winget if missing

# ---------------------------------------------------------------- LAN addressing
# Pick addresses OUTSIDE your router's DHCP pool (or reserve them on the router).
# Leave Gateway / DnsServers / PrefixLength empty to auto-detect them from the
# host's "vEthernet (<SwitchName>)" adapter.
$PrefixLength    = $null            # e.g. 24
$Gateway         = ''               # e.g. '192.168.1.1'
$DnsServers      = @()              # e.g. @('192.168.1.1','1.1.1.1')
$SearchDomain    = 'lab.local'

# Static MACs (Hyper-V OUI 00-15-5D) make the netplan match deterministic and let
# you add DHCP reservations on your router as a belt-and-braces measure.
$Nodes = @(
    @{ Name = 'k8s-cp-01';   Role = 'control-plane'; IP = '192.168.1.200'; Mac = '00155D6E0A01'; Cpu = 2; MemoryBytes = 4GB; DiskBytes = 30GB }
    @{ Name = 'k8s-node-01'; Role = 'worker';        IP = '192.168.1.201'; Mac = '00155D6E0A02'; Cpu = 2; MemoryBytes = 4GB; DiskBytes = 30GB }
    @{ Name = 'k8s-node-02'; Role = 'worker';        IP = '192.168.1.202'; Mac = '00155D6E0A03'; Cpu = 2; MemoryBytes = 4GB; DiskBytes = 30GB }
)

# ---------------------------------------------------------------- Access
$AdminUser        = 'k8sadmin'
$SshPrivateKey    = Join-Path $env:USERPROFILE '.ssh\id_ed25519_k8s_hyperv'  # generated if missing
$SshKnownHosts    = Join-Path $VmRoot 'known_hosts'                          # dedicated, reset on rebuild
$Timezone         = 'Etc/UTC'

# ---------------------------------------------------------------- Kubernetes + CRI-O
# Cilium 1.20 is e2e-tested up to Kubernetes 1.36, so the cluster tracks the 1.36 line.
# CRI-O is installed from the matching minor stream (isv:cri-o:stable:v1.36).
$KubernetesMinor   = 'v1.36'
$KubernetesVersion = ''                 # '' = latest patch of $KubernetesMinor (e.g. v1.36.5)
$ClusterName       = 'hyperv-k8s'
$PodCidr           = '10.244.0.0/16'    # Cilium IPAM mode "kubernetes" + native routing CIDR
$ServiceCidr       = '10.96.0.0/12'

# ---------------------------------------------------------------- Platform stack (pinned, verified compatible)
$HelmVersion        = 'v4.3.0'
$GatewayApiVersion  = 'v1.6.1'          # exact version Cilium 1.20 conformance-tests; Istio 1.31 builds on v1.6.0
$CiliumVersion      = '1.20.2'
$CiliumCliVersion   = 'v0.20.1'
$HubbleCliVersion   = 'v1.19.4'
$MetalLbVersion     = '0.16.1'          # Helm chart version (app v0.16.1), L2 mode
$IstioVersion       = '1.31.1'          # ambient profile: istiod + istio-cni + ztunnel (sidecar mode also works)

# ---------------------------------------------------------------- MetalLB + Gateways
# LAN range handed out to LoadBalancer Services. Must be in the node subnet, outside DHCP,
# and must not include node IPs.
$MetalLbPool        = '192.168.1.220-192.168.1.239'
$CiliumGatewayIP    = '192.168.1.220'   # Gateway (class "cilium")  -> Hubble UI, echo app
$IstioGatewayIP     = '192.168.1.221'   # Gateway (class "istio")   -> httpbin (ambient)
$LabDomain          = 'lab.local'       # hubble.lab.local, echo.lab.local, httpbin.lab.local
$RunCiliumConnectivityTest = $false     # full `cilium connectivity test` (~10-15 min)

# ---------------------------------------------------------------- Timeouts (seconds)
$SshWaitTimeoutSec      = 900
$CloudInitWaitTimeoutSec = 900
