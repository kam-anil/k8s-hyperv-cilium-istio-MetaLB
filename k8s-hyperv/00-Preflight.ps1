#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only pre-flight check of the Windows host before provisioning the lab.

.DESCRIPTION
    Checks Hyper-V, CLI tools, qemu-img, the Intel NIC / vSwitch, the storage drive
    (NTFS/ReFS, free space, USB), RAM, planned IP addresses, and Internet reachability of
    every download source the build uses. Prints PASS / WARN / FAIL and exits 1 on any FAIL.

    Nothing is changed unless -ApplyHostTuning or -AddDefenderExclusion is given.

.PARAMETER ApplyHostTuning
    For USB-attached lab storage: disables USB selective suspend and system sleep /
    hibernate on AC power for the active power plan.

.PARAMETER AddDefenderExclusion
    Excludes $VmRoot from Microsoft Defender real-time scanning (faster VM disk I/O;
    files there are no longer scanned).

.EXAMPLE
    .\00-Preflight.ps1
    .\00-Preflight.ps1 -ApplyHostTuning
#>
[CmdletBinding()]
param(
    [switch]$ApplyHostTuning,
    [switch]$AddDefenderExclusion,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'cluster.config.ps1')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
. $ConfigPath
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$Nodes = @($Nodes | ForEach-Object { [pscustomobject]$_ })

$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Area, [string]$Check, [ValidateSet('PASS','WARN','FAIL')][string]$Status, [string]$Detail) {
    $results.Add([pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail })
    $color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$Status]
    Write-Host ("  [{0}] {1,-10} {2}: {3}" -f $Status, $Area, $Check, $Detail) -ForegroundColor $color
}

Write-Step "Pre-flight checks ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"

# ------------------------------------------------------------- configuration
try { Assert-Config; Add-Result 'Config' 'cluster.config.ps1' 'PASS' "$($Nodes.Count) nodes, pool $MetalLbPool" }
catch { Add-Result 'Config' 'cluster.config.ps1' 'FAIL' $_.Exception.Message }

# ------------------------------------------------------------- host platform
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
Add-Result 'Host' 'Windows' 'PASS' "$($os.Caption) build $($os.BuildNumber)"
Add-Result 'Host' 'PowerShell' 'PASS' "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

if ($cs.HypervisorPresent) { Add-Result 'Hyper-V' 'Hypervisor running' 'PASS' 'HypervisorPresent = True' }
else { Add-Result 'Hyper-V' 'Hypervisor running' 'FAIL' 'Enable Hyper-V (and virtualization in firmware), then reboot' }

if (Get-Command New-VM -ErrorAction SilentlyContinue) {
    try { $vmHost = Get-VMHost; Add-Result 'Hyper-V' 'PowerShell module' 'PASS' "default VM path $($vmHost.VirtualMachinePath)" }
    catch { Add-Result 'Hyper-V' 'PowerShell module' 'FAIL' "Get-VMHost failed: $($_.Exception.Message)" }
} else {
    Add-Result 'Hyper-V' 'PowerShell module' 'FAIL' 'Enable "Hyper-V Module for Windows PowerShell" (Hyper-V Management Tools)'
}

# ------------------------------------------------------------- tools
foreach ($tool in 'ssh.exe', 'scp.exe', 'ssh-keygen.exe') {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) { Add-Result 'Tools' $tool 'PASS' $cmd.Source }
    else { Add-Result 'Tools' $tool 'FAIL' 'Install OpenSSH Client: Settings > System > Optional features' }
}
foreach ($tool in 'curl.exe', 'fsutil.exe', 'icacls.exe') {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) { Add-Result 'Tools' $tool 'PASS' $cmd.Source } else { Add-Result 'Tools' $tool 'FAIL' 'missing from Windows' }
}
$qemu = @($QemuImgPath, (Get-Command qemu-img.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
          "$env:ProgramFiles\qemu\qemu-img.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
$baseCached = Test-Path (Join-Path $ImageCacheDir "ubuntu-$UbuntuRelease-base.vhdx")
if ($qemu) {
    $ver = (& $qemu --version | Select-Object -First 1)
    Add-Result 'Tools' 'qemu-img' 'PASS' "$qemu ($ver)"
} elseif ($baseCached) {
    Add-Result 'Tools' 'qemu-img' 'PASS' 'not installed, but the converted base VHDX is already cached'
} elseif (Get-Command winget.exe -ErrorAction SilentlyContinue) {
    Add-Result 'Tools' 'qemu-img' 'WARN' '01-Provision will install QEMU via winget; installing it yourself first is more reliable'
} else {
    Add-Result 'Tools' 'qemu-img' 'FAIL' 'Install QEMU for Windows (or set $QemuImgPath); winget is not available to do it automatically'
}

# ------------------------------------------------------------- network
$sw = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if ($sw) {
    if ($sw.SwitchType -eq 'External') { Add-Result 'Network' "vSwitch $SwitchName" 'PASS' "exists, bound to $($sw.NetAdapterInterfaceDescription)" }
    else { Add-Result 'Network' "vSwitch $SwitchName" 'FAIL' "exists but is $($sw.SwitchType), must be External" }
} else {
    $nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
        $_.InterfaceDescription -match $NicMatch -and $_.Status -eq 'Up' -and $_.NdisPhysicalMedium -eq 14 })
    if ($nics.Count -gt 0) {
        $bound = Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue | Where-Object { $_.NetAdapterInterfaceDescription -eq $nics[0].InterfaceDescription }
        if ($bound) { Add-Result 'Network' 'Intel NIC' 'FAIL' "$($nics[0].InterfaceDescription) already bound to switch '$($bound.Name)'" }
        else { Add-Result 'Network' 'Intel NIC' 'PASS' "$($nics[0].Name): $($nics[0].InterfaceDescription), $($nics[0].LinkSpeed) (switch will be created; brief network drop)" }
    } else {
        Add-Result 'Network' 'Intel NIC' 'FAIL' "no wired adapter matching '$NicMatch' with Status Up"
    }
}

# Use the same adapter 01-Provision uses: the switch's management vNIC if the switch exists,
# otherwise the Intel NIC. Only fall back to the lowest-metric default route (which may be Wi-Fi).
$lanIf = Get-NetAdapter -Name "vEthernet ($SwitchName)" -ErrorAction SilentlyContinue
if (-not $lanIf) {
    $lanIf = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
        $_.InterfaceDescription -match $NicMatch -and $_.Status -eq 'Up' } | Select-Object -First 1
}
$lanCfg  = if ($lanIf) { Get-NetIPConfiguration -InterfaceIndex $lanIf.ifIndex -ErrorAction SilentlyContinue }
$lanAddr = if ($lanIf) { Get-NetIPAddress -InterfaceIndex $lanIf.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                         Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1 }
$gw = if ($Gateway) { $Gateway } elseif ($lanCfg -and $lanCfg.IPv4DefaultGateway) { $lanCfg.IPv4DefaultGateway[0].NextHop } else { $null }
$prefix = if ($PrefixLength) { $PrefixLength } elseif ($lanAddr) { $lanAddr.PrefixLength } else { 24 }
if ($lanIf -and $lanAddr) {
    Add-Result 'Network' 'Lab LAN adapter' 'PASS' "$($lanIf.Name): $($lanAddr.IPAddress)/$($lanAddr.PrefixLength), gateway $gw"
}
$otherDefault = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
if ($lanIf -and $otherDefault -and $otherDefault.ifIndex -ne $lanIf.ifIndex) {
    $otherName = (Get-NetAdapter -InterfaceIndex $otherDefault.ifIndex -ErrorAction SilentlyContinue).Name
    Add-Result 'Network' 'Default route' 'WARN' "host's preferred internet route is '$otherName' via $($otherDefault.NextHop), not the lab adapter"
}
if ($gw) {
    $bad = @(@($Nodes | ForEach-Object { $_.IP }) + $MetalLbPool.Split('-').Trim() | Where-Object { -not (Test-SameSubnet $_ $gw $prefix) })
    if ($bad.Count -eq 0) { Add-Result 'Network' 'Addressing' 'PASS' "nodes and MetalLB pool are inside $gw/$prefix" }
    else { Add-Result 'Network' 'Addressing' 'FAIL' "outside the lab LAN $gw/${prefix}: $($bad -join ', ') - edit cluster.config.ps1" }
} else {
    Add-Result 'Network' 'Addressing' 'WARN' 'could not determine the lab LAN gateway; set $Gateway in cluster.config.ps1'
}

$existingVms = @(Get-VM -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
foreach ($ip in @($Nodes | ForEach-Object { $_.IP }) + @($CiliumGatewayIP, $IstioGatewayIP)) {
    $owner = $Nodes | Where-Object { $_.IP -eq $ip } | Select-Object -First 1
    if (Test-IpInUse $ip) {
        if ($owner -and $existingVms -contains $owner.Name) { Add-Result 'Network' "IP $ip" 'PASS' "in use by existing VM $($owner.Name)" }
        elseif (-not $owner -and @($Nodes | Where-Object { $existingVms -contains $_.Name }).Count -gt 0) {
            Add-Result 'Network' "IP $ip" 'PASS' 'answering - expected once MetalLB has assigned it to a Gateway'
        }
        else { Add-Result 'Network' "IP $ip" 'FAIL' 'answers ping - already taken on the LAN' }
    } else {
        Add-Result 'Network' "IP $ip" 'PASS' 'free (no ping reply; also confirm it is outside the DHCP range)'
    }
}

# ------------------------------------------------------------- storage
$qualifier = Split-Path -Path $VmRoot -Qualifier
$letter    = $qualifier.TrimEnd(':')
$vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
if (-not $vol) {
    Add-Result 'Storage' "Drive $qualifier" 'FAIL' 'not found - connect the SSD / fix the drive letter'
} else {
    if ($vol.FileSystem -in @('NTFS', 'ReFS')) { Add-Result 'Storage' 'Filesystem' 'PASS' $vol.FileSystem }
    else { Add-Result 'Storage' 'Filesystem' 'FAIL' "$($vol.FileSystem) - Hyper-V needs NTFS or ReFS" }
    $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 1)
    $maxGB  = [math]::Round((($Nodes | Measure-Object -Property DiskBytes -Sum).Sum / 1GB) + 5, 0)
    if ($freeGB -lt $MinFreeSpaceGB) { Add-Result 'Storage' 'Free space' 'FAIL' "$freeGB GB (< $MinFreeSpaceGB GB minimum)" }
    elseif ($freeGB -lt $maxGB)      { Add-Result 'Storage' 'Free space' 'WARN' "$freeGB GB (disks can grow to ~$maxGB GB)" }
    else                             { Add-Result 'Storage' 'Free space' 'PASS' "$freeGB GB free (max disk growth ~$maxGB GB)" }
    $bus = (Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue | Get-Disk -ErrorAction SilentlyContinue).BusType
    if ("$bus" -eq 'USB') { Add-Result 'Storage' 'Bus' 'WARN' 'USB-attached: keep connected; consider -ApplyHostTuning' }
    else { Add-Result 'Storage' 'Bus' 'PASS' "$bus" }
}

# ------------------------------------------------------------- memory
$needGB = [math]::Round(($Nodes | Measure-Object -Property MemoryBytes -Sum).Sum / 1GB, 0)
$freeRamGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
$totalRamGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
$runningLab = @(Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' -and ($Nodes.Name -contains $_.Name) }).Count
if ($runningLab -gt 0) { Add-Result 'Memory' 'RAM' 'PASS' "lab VMs already running ($runningLab); host total $totalRamGB GB" }
elseif ($freeRamGB -ge $needGB + 2) { Add-Result 'Memory' 'RAM' 'PASS' "$freeRamGB GB free, VMs need $needGB GB (static)" }
elseif ($freeRamGB -ge $needGB) { Add-Result 'Memory' 'RAM' 'WARN' "$freeRamGB GB free, VMs need $needGB GB - little headroom for the host" }
else { Add-Result 'Memory' 'RAM' 'FAIL' "$freeRamGB GB free, VMs need $needGB GB - close apps or reduce MemoryBytes" }

# ------------------------------------------------------------- internet sources
$sources = [ordered]@{
    'Ubuntu images'   = "$UbuntuBaseUrl/SHA256SUMS"
    'Kubernetes rel.' = 'https://dl.k8s.io/release/stable.txt'
    'pkgs.k8s.io'     = "https://pkgs.k8s.io/core:/stable:/$KubernetesMinor/deb/Release"
    'CRI-O repo'      = "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$KubernetesMinor/deb/Release"
    'registry.k8s.io' = 'https://registry.k8s.io/v2/'
    'quay.io'         = 'https://quay.io/v2/'
    'ghcr.io'         = 'https://ghcr.io/v2/'
    'Docker Hub'      = 'https://registry-1.docker.io/v2/'
    'GitHub releases' = "https://github.com/istio/istio/releases/download/$IstioVersion/istio-$IstioVersion-linux-amd64.tar.gz.sha256"
    'Helm (get.helm)' = "https://get.helm.sh/helm-$HelmVersion-linux-amd64.tar.gz.sha256sum"
    'Cilium charts'   = 'https://helm.cilium.io/index.yaml'
    'MetalLB charts'  = 'https://metallb.github.io/metallb/index.yaml'
}
foreach ($name in $sources.Keys) {
    $code = & curl.exe -s -o NUL -m 15 -L -w '%{http_code}' $sources[$name]
    if ($code -match '^(2|3)\d\d$' -or ($code -eq '401' -and $name -notmatch 'repo|pkgs|images|releases|Helm|charts')) {
        Add-Result 'Internet' $name 'PASS' "HTTP $code"
    } elseif ($code -eq '000') {
        Add-Result 'Internet' $name 'FAIL' 'unreachable (DNS, proxy or firewall)'
    } else {
        Add-Result 'Internet' $name 'WARN' "HTTP $code from $($sources[$name])"
    }
}

# ------------------------------------------------------------- optional host tuning
if ($ApplyHostTuning) {
    Write-Step 'Applying host tuning for USB-attached lab storage'
    # USB selective suspend = Disabled (AC) on the active plan
    & powercfg.exe /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
    & powercfg.exe /setactive SCHEME_CURRENT
    & powercfg.exe /change standby-timeout-ac 0
    & powercfg.exe /change hibernate-timeout-ac 0
    Write-Ok 'USB selective suspend off; sleep and hibernate on AC disabled'
    Write-Info 'Also untick "Allow the computer to turn off this device" on USB Root Hub / xHCI controllers in Device Manager.'
}
if ($AddDefenderExclusion) {
    New-Item -ItemType Directory -Force -Path $VmRoot | Out-Null
    Add-MpPreference -ExclusionPath $VmRoot
    Write-Ok "Defender real-time scanning excluded for $VmRoot"
}

# ------------------------------------------------------------- summary
$fail = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warn = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
Write-Host ''
if ($fail -eq 0) {
    Write-Host "Pre-flight OK: $($results.Count - $warn) passed, $warn warning(s). Next: .\01-Provision-HyperV.ps1" -ForegroundColor Green
} else {
    Write-Host "Pre-flight FAILED: $fail failure(s), $warn warning(s). Fix the FAIL items above and re-run." -ForegroundColor Red
    exit 1
}
