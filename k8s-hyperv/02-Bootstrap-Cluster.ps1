#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Prepares all nodes, initialises the control plane, joins workers and verifies the cluster.

.DESCRIPTION
    Runs from the Windows host over SSH (no Ansible/WSL needed). Idempotent: every stage
    skips work that is already done, so it is safe to re-run after a failure.
      1. Resolve one Kubernetes version for the whole cluster.
      2. Stage scripts/*.sh on every node.
      3. node-prep.sh on all nodes (swap, modules, sysctl, CRI-O, kube packages, hardening).
      4. cp-init.sh on the control plane (kubeadm init without kube-proxy, kubeconfig).
      5. Mint a short-lived join token and pipe it via stdin to worker-join.sh on each worker,
         then revoke it.
      6. platform-install.sh: Gateway API CRDs, Cilium + Hubble, MetalLB, Istio (ambient + sidecar),
         lab gateways and demo namespaces.
      7. Copy admin kubeconfig to the host, run verify-cluster.sh, and test the gateways from Windows.

.EXAMPLE
    .\02-Bootstrap-Cluster.ps1
    .\02-Bootstrap-Cluster.ps1 -SkipVerify
#>
[CmdletBinding()]
param(
    [switch]$SkipVerify,
    [switch]$KeepTestWorkload,
    [switch]$UpdateHostsFile,      # add <name>.<LabDomain> entries to the Windows hosts file (needs Admin)
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'cluster.config.ps1')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

. $ConfigPath
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$Nodes = @($Nodes | ForEach-Object { [pscustomobject]$_ })
Assert-Tool 'ssh.exe'; Assert-Tool 'scp.exe'
Assert-Config

$cp        = $Nodes | Where-Object { $_.Role -eq 'control-plane' } | Select-Object -First 1
$workers   = @($Nodes | Where-Object { $_.Role -eq 'worker' })
$remoteDir = 'k8s-bootstrap'
$scripts   = Get-ChildItem (Join-Path $PSScriptRoot 'scripts') -Filter '*.sh' | Select-Object -ExpandProperty FullName
if (-not (Test-Path $SshPrivateKey)) { throw "SSH key $SshPrivateKey not found - run 01-Provision-HyperV.ps1 first." }

# Single-quote a value for safe use inside a remote bash command line.
function Quote-Sh([string]$Value) { "'" + ($Value -replace "'", "'\''") + "'" }

# =============================================================================
# 1. Kubernetes version (resolved once, so every node gets the identical build)
# =============================================================================
Write-Step 'Resolving Kubernetes version'
if (-not $KubernetesVersion) {
    $minorNum = $KubernetesMinor.TrimStart('v')
    $KubernetesVersion = (Invoke-RestMethod -Uri "https://dl.k8s.io/release/stable-$minorNum.txt" -UseBasicParsing).ToString().Trim()
}
if ($KubernetesVersion -notmatch '^v\d+\.\d+\.\d+$') { throw "Invalid Kubernetes version '$KubernetesVersion'" }
Write-Ok "Kubernetes $KubernetesVersion"

# =============================================================================
# 2. Connectivity + stage scripts
# =============================================================================
Write-Step 'Staging bootstrap scripts'
foreach ($n in $Nodes) {
    Wait-Ssh -Ip $n.IP -TimeoutSec $SshWaitTimeoutSec
    Invoke-Remote -Ip $n.IP -Command "mkdir -p ~/$remoteDir && chmod 700 ~/$remoteDir"
    Copy-ToRemote -Ip $n.IP -Paths $scripts -RemoteDir $remoteDir
    # Normalise line endings in case the repo was checked out with CRLF on Windows
    Invoke-Remote -Ip $n.IP -Command "sed -i 's/\r$//' ~/$remoteDir/*.sh && chmod 700 ~/$remoteDir/*.sh"
    Write-Ok "$($n.Name) ($($n.IP))"
}

# =============================================================================
# 3. Node preparation on all nodes
# =============================================================================
foreach ($n in $Nodes) {
    Write-Step "node-prep.sh on $($n.Name)"
    $envs = "KUBE_VERSION=$(Quote-Sh $KubernetesVersion) NODE_IP=$(Quote-Sh $n.IP)"
    Invoke-Remote -Ip $n.IP -Command "sudo env $envs bash ~/$remoteDir/node-prep.sh"
}

# =============================================================================
# 4. Control plane
# =============================================================================
Write-Step "cp-init.sh on $($cp.Name)"
$cpEnv = @(
    "NODE_NAME=$(Quote-Sh $cp.Name)"
    "ADVERTISE_IP=$(Quote-Sh $cp.IP)"
    "KUBE_VERSION=$(Quote-Sh $KubernetesVersion)"
    "CLUSTER_NAME=$(Quote-Sh $ClusterName)"
    "POD_CIDR=$(Quote-Sh $PodCidr)"
    "SERVICE_CIDR=$(Quote-Sh $ServiceCidr)"
    "ADMIN_USER=$(Quote-Sh $AdminUser)"
) -join ' '
Invoke-Remote -Ip $cp.IP -Command "sudo env $cpEnv bash ~/$remoteDir/cp-init.sh"

# =============================================================================
# 5. Workers: automated token propagation (stdin only, short TTL, revoked after)
# =============================================================================
$pending = @()
foreach ($w in $workers) {
    $joined = Invoke-Remote -Ip $w.IP -Command 'test -f /etc/kubernetes/kubelet.conf && echo yes || echo no' -Capture
    if ("$joined".Trim() -eq 'yes') { Write-Ok "$($w.Name) already joined" } else { $pending += $w }
}

if ($pending.Count -gt 0) {
    Write-Step 'Creating short-lived bootstrap token'
    $joinCmd = ("$(Invoke-Remote -Ip $cp.IP -Command 'sudo kubeadm token create --ttl 30m --description hyperv-automation --print-join-command' -Capture)").Trim()
    if ($joinCmd -match '^kubeadm join \S+ --token ([a-z0-9]{6})\.[a-z0-9]{16} --discovery-token-ca-cert-hash sha256:[a-f0-9]{64}') {
        $tokenId = $Matches[1]
    } else {
        throw 'Unexpected output from kubeadm token create'
    }
    try {
        foreach ($w in $pending) {
            Write-Step "worker-join.sh on $($w.Name)"
            Invoke-Remote -Ip $w.IP -Command "sudo env NODE_NAME=$(Quote-Sh $w.Name) bash ~/$remoteDir/worker-join.sh" -InputText $joinCmd
        }
    } finally {
        Invoke-Remote -Ip $cp.IP -Command "sudo kubeadm token delete $tokenId >/dev/null" -AllowedExitCodes 0,1
        $joinCmd = $null
        Write-Ok 'Bootstrap token revoked'
    }
}

# =============================================================================
# 6. Platform: Gateway API, Cilium + Hubble, MetalLB, Istio, lab content
# =============================================================================
Write-Step "platform-install.sh on $($cp.Name) (Cilium $CiliumVersion, MetalLB $MetalLbVersion, Istio $IstioVersion)"
$platEnv = @(
    "CP_IP=$(Quote-Sh $cp.IP)"
    "POD_CIDR=$(Quote-Sh $PodCidr)"
    "HELM_VERSION=$(Quote-Sh $HelmVersion)"
    "GATEWAY_API_VERSION=$(Quote-Sh $GatewayApiVersion)"
    "CILIUM_VERSION=$(Quote-Sh $CiliumVersion)"
    "CILIUM_CLI_VERSION=$(Quote-Sh $CiliumCliVersion)"
    "HUBBLE_CLI_VERSION=$(Quote-Sh $HubbleCliVersion)"
    "METALLB_VERSION=$(Quote-Sh $MetalLbVersion)"
    "ISTIO_VERSION=$(Quote-Sh $IstioVersion)"
    "METALLB_POOL=$(Quote-Sh $MetalLbPool)"
    "CILIUM_GATEWAY_IP=$(Quote-Sh $CiliumGatewayIP)"
    "ISTIO_GATEWAY_IP=$(Quote-Sh $IstioGatewayIP)"
    "LAB_DOMAIN=$(Quote-Sh $LabDomain)"
) -join ' '
Invoke-Remote -Ip $cp.IP -Command "sudo env $platEnv bash ~/$remoteDir/platform-install.sh"

Write-Step 'Labelling workers'
Invoke-Remote -Ip $cp.IP -Command "kubectl label node $(($workers | ForEach-Object { $_.Name }) -join ' ') node-role.kubernetes.io/worker= --overwrite >/dev/null && kubectl get nodes -o wide"

# =============================================================================
# 7. Host kubeconfig + verification
# =============================================================================
Write-Step 'Exporting kubeconfig to the host'
$hostKubeconfig = Join-Path $VmRoot 'kubeconfig'
Copy-FromRemote -Ip $cp.IP -RemotePath '.kube/config' -LocalPath $hostKubeconfig
# Restrict the file to the current user (it holds cluster-admin credentials)
& icacls.exe $hostKubeconfig /inheritance:r /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(R,W)" /grant:r "*S-1-5-32-544:(F)" | Out-Null
Write-Ok "$hostKubeconfig  (use: `$env:KUBECONFIG='$hostKubeconfig'; kubectl get nodes)"

if (-not $SkipVerify) {
    Write-Step 'Running verify-cluster.sh'
    $vEnv = @(
        "EXPECTED_NODES=$($Nodes.Count)"
        "WORKERS=$(Quote-Sh (($workers | ForEach-Object { $_.Name }) -join ' '))"
        "EXPECTED_OS=$(Quote-Sh "Ubuntu $UbuntuRelease")"
        "CILIUM_GATEWAY_IP=$(Quote-Sh $CiliumGatewayIP)"
        "ISTIO_GATEWAY_IP=$(Quote-Sh $IstioGatewayIP)"
        "LAB_DOMAIN=$(Quote-Sh $LabDomain)"
        "RUN_CONNECTIVITY_TEST=$(if ($RunCiliumConnectivityTest) { 'true' } else { 'false' })"
        "KEEP_TEST_WORKLOAD=$(if ($KeepTestWorkload) { 'true' } else { 'false' })"
    ) -join ' '
    Invoke-Remote -Ip $cp.IP -Command "env $vEnv bash ~/$remoteDir/verify-cluster.sh"
}

# =============================================================================
# 8. North-south test from Windows (proves MetalLB L2/ARP works on the physical LAN)
# =============================================================================
$labHosts = [ordered]@{
    "hubble.$LabDomain"  = @{ IP = $CiliumGatewayIP; Path = '/' }
    "echo.$LabDomain"    = @{ IP = $CiliumGatewayIP; Path = '/get' }
    "httpbin.$LabDomain" = @{ IP = $IstioGatewayIP;  Path = '/get' }
}
Write-Step 'Testing gateways from the Windows host'
foreach ($h in $labHosts.Keys) {
    $t = $labHosts[$h]
    $code = & curl.exe -s -o NUL -m 10 -w '%{http_code}' --resolve "${h}:80:$($t.IP)" "http://$h$($t.Path)"
    if ($code -eq '200') { Write-Ok "http://$h$($t.Path) via $($t.IP) -> 200" }
    else { Write-Warning "http://$h$($t.Path) via $($t.IP) -> '$code' (check MetalLB speaker logs / host firewall)" }
}

if ($UpdateHostsFile) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Write-Warning '-UpdateHostsFile needs an elevated session; skipped.' }
    else {
        $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
        $begin = '# >>> k8s-hyperv lab >>>'; $end = '# <<< k8s-hyperv lab <<<'
        $content = Get-Content $hostsPath -Raw
        $content = [regex]::Replace($content, "(?s)\r?\n?$([regex]::Escape($begin)).*?$([regex]::Escape($end))\r?\n?", "`r`n")
        $block = @($begin) + ($labHosts.Keys | ForEach-Object { "$($labHosts[$_].IP)`t$_" }) + @($end)
        Set-Content -Path $hostsPath -Value ($content.TrimEnd() + "`r`n" + ($block -join "`r`n") + "`r`n") -Encoding ASCII
        Write-Ok "Hosts file updated: $($labHosts.Keys -join ', ')"
    }
}

Write-Host "`nCluster '$ClusterName' ($KubernetesVersion, CRI-O, Cilium $CiliumVersion, Istio $IstioVersion) is up." -ForegroundColor Green
Write-Host "  Hubble UI : http://hubble.$LabDomain   (Cilium Gateway $CiliumGatewayIP)"
Write-Host "  Echo      : http://echo.$LabDomain/get (Cilium Gateway $CiliumGatewayIP)"
Write-Host "  httpbin   : http://httpbin.$LabDomain/get (Istio Gateway $IstioGatewayIP, ambient + waypoint)"
if (-not $UpdateHostsFile) { Write-Host "  Tip: re-run with -UpdateHostsFile (elevated) or add those names to your hosts file." }
