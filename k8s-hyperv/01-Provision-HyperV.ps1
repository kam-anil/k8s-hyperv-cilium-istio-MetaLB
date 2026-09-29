#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Idempotently provisions 3 Ubuntu Server 26.04 VMs on Hyper-V for a kubeadm cluster.
    Run 00-Preflight.ps1 first; run 02-Bootstrap-Cluster.ps1 afterwards.

.DESCRIPTION
    0. Validates the storage target ($VmRoot: drive present, NTFS/ReFS, free space, USB warning).
    1. Verifies or creates the external vSwitch bound to the active Intel NIC.
    2. Downloads + SHA256-verifies the official Ubuntu 26.04 cloud image and converts it to VHDX.
    3. Builds a per-VM NoCloud seed ISO (user-data, meta-data, network-config).
    4. Creates Gen2 VMs (Secure Boot, MicrosoftUEFICertificateAuthority template, static MAC).
    5. Starts the VMs and waits until SSH and cloud-init have completed on every node.

.PARAMETER Recreate
    Destroys and rebuilds VMs defined in the config (their disks are deleted).

.EXAMPLE
    .\01-Provision-HyperV.ps1
    .\01-Provision-HyperV.ps1 -Recreate
#>
[CmdletBinding()]
param(
    [switch]$Recreate,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'cluster.config.ps1')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # huge speed-up for web cmdlets on PS 5.1

. $ConfigPath
. (Join-Path $PSScriptRoot 'lib\common.ps1')

# =============================================================================
# 0. Pre-flight
# =============================================================================
Write-Step 'Pre-flight checks'
if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    throw 'Hyper-V PowerShell module not found. Enable Hyper-V (incl. management tools) and reboot.'
}
[void](Get-VMHost)
Assert-Tool 'ssh.exe'; Assert-Tool 'ssh-keygen.exe'
$Nodes = @($Nodes | ForEach-Object { [pscustomobject]$_ })
Assert-Config
Write-Ok 'Hyper-V, OpenSSH client and configuration look good'

# =============================================================================
# 0b. Storage target (external SSD)
# =============================================================================
Write-Step "Storage location $VmRoot"
$qualifier = Split-Path -Path $VmRoot -Qualifier
$letter    = $qualifier.TrimEnd(':')
$vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
if (-not $vol) { throw "Drive $qualifier not found. Connect the external SSD (or fix the drive letter) and re-run." }
if ($vol.FileSystem -notin @('NTFS', 'ReFS')) {
    throw "Drive $qualifier is formatted $($vol.FileSystem). Hyper-V VHDX files and checkpoints need NTFS or ReFS (exFAT/FAT32 are not supported)."
}
$freeGB = [math]::Round($vol.SizeRemaining / 1GB, 1)
if ($freeGB -lt $MinFreeSpaceGB) { throw "Only $freeGB GB free on $qualifier; at least $MinFreeSpaceGB GB is required." }
$maxGrowthGB = [math]::Round((($Nodes | Measure-Object -Property DiskBytes -Sum).Sum / 1GB) + 5, 0)
if ($freeGB -lt $maxGrowthGB) {
    Write-Warning "$freeGB GB free; the dynamic disks can grow to ~$maxGrowthGB GB plus checkpoints. Monitor free space."
}
$bus = (Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue | Get-Disk -ErrorAction SilentlyContinue).BusType
if ("$bus" -eq 'USB') {
    Write-Warning "$qualifier is USB-attached. Keep it connected while VMs run; unplugging it will crash them. VM auto-start is delayed $VmAutoStartDelaySec s after host boot."
}
New-Item -ItemType Directory -Force -Path $VmRoot, $ImageCacheDir | Out-Null
Write-Ok "$qualifier $($vol.FileSystem), $freeGB GB free, bus: $bus"

# =============================================================================
# 1. External virtual switch
# =============================================================================
Write-Step "Virtual switch '$SwitchName'"
$switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if ($switch) {
    if ($switch.SwitchType -ne 'External') { throw "Switch '$SwitchName' exists but is $($switch.SwitchType), not External." }
    if (-not $switch.AllowManagementOS)    { Set-VMSwitch -Name $SwitchName -AllowManagementOS $true }
    Write-Ok "Exists (bound to: $($switch.NetAdapterInterfaceDescription))"
} else {
    $defaultRouteIfs = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ifIndex)
    $candidates = @(Get-NetAdapter -Physical | Where-Object {
        $_.InterfaceDescription -match $NicMatch -and $_.Status -eq 'Up' -and $_.NdisPhysicalMedium -eq 14   # 14 = 802.3 wired
    } | Sort-Object @{ Expression = { $defaultRouteIfs -contains $_.ifIndex }; Descending = $true }, ifIndex)

    if ($candidates.Count -eq 0) {
        throw "No active wired physical adapter matching '$NicMatch' found. Check 'Get-NetAdapter -Physical'."
    }
    $nic = $candidates[0]
    $alreadyBound = Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue |
        Where-Object { $_.NetAdapterInterfaceDescription -eq $nic.InterfaceDescription }
    if ($alreadyBound) {
        throw "NIC '$($nic.InterfaceDescription)' is already bound to external switch '$($alreadyBound.Name)'. Rename that switch to '$SwitchName' or set `$SwitchName to it."
    }

    Write-Warning "Creating external switch on '$($nic.Name)' ($($nic.InterfaceDescription)). Host network will drop for a few seconds."
    New-VMSwitch -Name $SwitchName -NetAdapterName $nic.Name -AllowManagementOS $true `
        -Notes 'Managed by 01-Provision-HyperV.ps1 (Kubernetes lab)' | Out-Null

    # Wait for the management vNIC to regain an IPv4 address (DHCP or migrated static).
    $deadline = (Get-Date).AddSeconds(90)
    do {
        Start-Sleep -Seconds 3
        $mgmt = Get-NetAdapter -Name "vEthernet ($SwitchName)" -ErrorAction SilentlyContinue
        $hasIp = $mgmt -and (Get-NetIPAddress -InterfaceIndex $mgmt.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                             Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*' })
    } until ($hasIp -or (Get-Date) -gt $deadline)
    if (-not $hasIp) { throw "vEthernet ($SwitchName) did not obtain an IPv4 address within 90 s." }
    Write-Ok "Created and bound to $($nic.InterfaceDescription)"
}

# =============================================================================
# 2. Resolve LAN gateway / DNS / prefix
# =============================================================================
Write-Step 'Resolving LAN addressing'
$mgmt   = Get-NetAdapter -Name "vEthernet ($SwitchName)" -ErrorAction SilentlyContinue
if ($mgmt) {
    $ipCfg  = Get-NetIPConfiguration -InterfaceIndex $mgmt.ifIndex -ErrorAction SilentlyContinue
    $hostIp = Get-NetIPAddress -InterfaceIndex $mgmt.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    if (-not $Gateway -and $ipCfg -and $ipCfg.IPv4DefaultGateway) { $Gateway = $ipCfg.IPv4DefaultGateway[0].NextHop }
    if (-not $PrefixLength -and $hostIp)               { $PrefixLength = [int]$hostIp.PrefixLength }
    if (@($DnsServers).Count -eq 0) {
        $DnsServers = @((Get-DnsClientServerAddress -InterfaceIndex $mgmt.ifIndex -AddressFamily IPv4).ServerAddresses)
    }
}
if (-not $Gateway)                 { throw 'Could not determine the LAN gateway. Set $Gateway in cluster.config.ps1.' }
if (-not $PrefixLength)            { throw 'Could not determine the LAN prefix. Set $PrefixLength in cluster.config.ps1.' }
if (@($DnsServers).Count -eq 0)    { $DnsServers = @($Gateway) }
foreach ($n in $Nodes) {
    if (-not (Test-SameSubnet $n.IP $Gateway $PrefixLength)) {
        throw "Node $($n.Name) IP $($n.IP) is not in the gateway subnet $Gateway/$PrefixLength."
    }
    if (Test-CidrOverlap "$Gateway/$PrefixLength" $PodCidr) { throw "LAN $Gateway/$PrefixLength overlaps PodCidr $PodCidr." }
}
foreach ($poolIp in $MetalLbPool.Split('-').Trim()) {
    if (-not (Test-SameSubnet $poolIp $Gateway $PrefixLength)) { throw "MetalLbPool address $poolIp is not in $Gateway/$PrefixLength." }
}
Write-Ok "Gateway $Gateway  Prefix /$PrefixLength  DNS $($DnsServers -join ', ')  MetalLB pool $MetalLbPool"

# =============================================================================
# 3. SSH key pair
# =============================================================================
Write-Step 'SSH key'
if (-not (Test-Path $SshPrivateKey)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $SshPrivateKey) | Out-Null
    # Empty passphrase quoting differs between Windows PowerShell and PowerShell 7.3+
    $emptyPass = if ($PSVersionTable.PSVersion.Major -ge 7 -and
                     (Get-Variable PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue) -ne 'Legacy') { '' } else { '""' }
    & ssh-keygen.exe -q -t ed25519 -C "$AdminUser@k8s-hyperv" -N $emptyPass -f $SshPrivateKey
    if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen failed' }
    Write-Ok "Generated $SshPrivateKey"
} else { Write-Ok "Using $SshPrivateKey" }
$SshPublicKey = (Get-Content "$SshPrivateKey.pub" -Raw).Trim()

# =============================================================================
# 4. Ubuntu 26.04 cloud image -> base VHDX (cached)
# =============================================================================
Write-Step "Ubuntu $UbuntuRelease cloud image"
$baseVhdx = Join-Path $ImageCacheDir "ubuntu-$UbuntuRelease-base.vhdx"
if (-not (Test-Path $baseVhdx)) {
    $qcow = Join-Path $ImageCacheDir $UbuntuImageName
    $sums = Join-Path $ImageCacheDir 'SHA256SUMS'

    & curl.exe -fsSL --retry 3 -o $sums "$UbuntuBaseUrl/SHA256SUMS"
    if ($LASTEXITCODE -ne 0) { throw 'Failed to download SHA256SUMS' }
    $sumLine = Select-String -Path $sums -Pattern ([regex]::Escape("*$UbuntuImageName") + '$') | Select-Object -First 1
    if (-not $sumLine) { throw "No checksum for $UbuntuImageName in SHA256SUMS" }
    $expected = $sumLine.Line.Split(' ')[0]

    $needDownload = -not (Test-Path $qcow) -or ((Get-FileHash $qcow -Algorithm SHA256).Hash -ne $expected.ToUpper())
    if ($needDownload) {
        Write-Info "Downloading $UbuntuImageName (~850 MB)..."
        & curl.exe -fL --retry 5 --retry-delay 5 -o $qcow "$UbuntuBaseUrl/$UbuntuImageName"
        if ($LASTEXITCODE -ne 0) { throw 'Image download failed' }
        if ((Get-FileHash $qcow -Algorithm SHA256).Hash -ne $expected.ToUpper()) { throw 'SHA256 mismatch on downloaded image' }
    }
    Write-Ok 'Image checksum verified'

    # qemu-img is required: Hyper-V cannot read qcow2 natively.
    if (-not $QemuImgPath) {
        $QemuImgPath = @(
            (Get-Command qemu-img.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
            "$env:ProgramFiles\qemu\qemu-img.exe"
        ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    }
    if (-not $QemuImgPath) {
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            throw 'qemu-img not found and winget unavailable. Install QEMU for Windows and set $QemuImgPath.'
        }
        Write-Info 'Installing QEMU (for qemu-img) via winget...'
        & winget.exe install --id SoftwareFreedomConservancy.QEMU -e --silent --accept-package-agreements --accept-source-agreements
        $QemuImgPath = "$env:ProgramFiles\qemu\qemu-img.exe"
        if (-not (Test-Path $QemuImgPath)) { throw 'QEMU install did not produce qemu-img.exe; set $QemuImgPath manually.' }
    }

    $tmpVhdx = "$baseVhdx.tmp"
    Remove-Item $tmpVhdx -ErrorAction SilentlyContinue
    & $QemuImgPath convert -p -f qcow2 -O vhdx -o subformat=dynamic $qcow $tmpVhdx
    if ($LASTEXITCODE -ne 0) { throw 'qemu-img conversion failed' }
    & fsutil.exe sparse setflag $tmpVhdx 0 | Out-Null   # Hyper-V refuses sparse VHDX files
    Move-Item $tmpVhdx $baseVhdx
    Write-Ok "Base disk ready: $baseVhdx"
} else { Write-Ok "Cached base disk: $baseVhdx" }

# =============================================================================
# 5. Helpers: NoCloud seed ISO (IMAPI2, no external tools)
# =============================================================================
if (-not ('CidataIsoWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices.ComTypes;
public static class CidataIsoWriter {
    public static void Write(string path, object comStream, int blockSize, int totalBlocks) {
        IStream stream = (IStream)comStream;
        byte[] buffer = new byte[blockSize];
        using (FileStream fs = File.Create(path)) {
            for (int i = 0; i < totalBlocks; i++) {
                stream.Read(buffer, blockSize, IntPtr.Zero);
                fs.Write(buffer, 0, blockSize);
            }
        }
    }
}
'@
}

function New-CidataIso([string]$SourceDir, [string]$IsoPath) {
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3          # ISO9660 + Joliet (keeps lowercase/hyphenated names)
    $fsi.VolumeName          = 'cidata'   # label required by the NoCloud datasource
    $fsi.Root.AddTree($SourceDir, $false)
    $img = $fsi.CreateResultImage()
    [CidataIsoWriter]::Write($IsoPath, $img.ImageStream, $img.BlockSize, $img.TotalBlocks)
}

function Write-LfFile([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path, ($Content -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
}

function Format-Mac([string]$Mac) { (($Mac.ToLower() -split '(..)' | Where-Object { $_ }) -join ':') }

# =============================================================================
# 6. Create VMs
# =============================================================================
$hostsBlock = ($Nodes | ForEach-Object { "      $($_.IP) $($_.Name).$SearchDomain $($_.Name)" }) -join "`n"
$dnsYaml    = ($DnsServers | ForEach-Object { "'$_'" }) -join ', '

foreach ($n in $Nodes) {
    Write-Step "VM $($n.Name)"
    $vmDir = Join-Path $VmRoot $n.Name
    $vm    = Get-VM -Name $n.Name -ErrorAction SilentlyContinue

    if ($vm -and $Recreate) {
        Write-Info 'Recreate requested: removing existing VM and disks'
        if ($vm.State -ne 'Off') { Stop-VM -Name $n.Name -TurnOff -Force }
        Remove-VM -Name $n.Name -Force
        Remove-Item -Recurse -Force $vmDir -ErrorAction SilentlyContinue
        Remove-KnownHost $n.IP
        $vm = $null
    }
    if ($vm) {
        if ($vm.ConfigurationLocation.TrimEnd('\') -ne $vmDir.TrimEnd('\')) {
            Write-Warning "$($n.Name) exists at $($vm.ConfigurationLocation), not $vmDir. Re-run with -Recreate to rebuild it on the new drive."
        }
        Write-Ok "Already exists (state: $($vm.State)) - skipping creation"; continue
    }

    if (Test-IpInUse $n.IP) { throw "IP $($n.IP) already answers ping on the LAN - choose a free address." }
    Remove-KnownHost $n.IP

    New-Item -ItemType Directory -Force -Path $vmDir, (Join-Path $vmDir 'seed') | Out-Null
    $seedDir = Join-Path $vmDir 'seed'

    # ---- cloud-init: meta-data
    Write-LfFile (Join-Path $seedDir 'meta-data') @"
instance-id: iid-$($n.Name)-$(Get-Date -Format yyyyMMddHHmmss)
local-hostname: $($n.Name)
"@

    # ---- cloud-init: network-config (v2, matched on static MAC)
    Write-LfFile (Join-Path $seedDir 'network-config') @"
version: 2
ethernets:
  lan0:
    match:
      macaddress: '$(Format-Mac $n.Mac)'
    set-name: eth0
    dhcp4: false
    dhcp6: false
    accept-ra: false
    addresses: ['$($n.IP)/$PrefixLength']
    routes:
      - to: default
        via: '$Gateway'
    nameservers:
      addresses: [$dnsYaml]
      search: ['$SearchDomain']
"@

    # ---- cloud-init: user-data
    Write-LfFile (Join-Path $seedDir 'user-data') @"
#cloud-config
hostname: $($n.Name)
fqdn: $($n.Name).$SearchDomain
prefer_fqdn_over_hostname: false
manage_etc_hosts: false
timezone: $Timezone
disable_root: true
ssh_pwauth: false
users:
  - name: $AdminUser
    gecos: Kubernetes automation user
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: true
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
    ssh_authorized_keys:
      - '$SshPublicKey'
growpart:
  mode: auto
  devices: ['/']
swap:
  size: 0
write_files:
  - path: /etc/hosts
    append: true
    content: |
      # k8s cluster nodes (cloud-init)
$hostsBlock
  - path: /etc/ssh/sshd_config.d/10-k8s-hardening.conf
    permissions: '0644'
    content: |
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PermitRootLogin no
      X11Forwarding no
      MaxAuthTries 3
      LoginGraceTime 30
runcmd:
  - [ swapoff, -a ]
  - [ sed, -ri, '/\sswap\s/ s/^([^#])/#\1/', /etc/fstab ]
  - [ systemctl, mask, --now, swap.target ]
  - [ sh, -c, 'systemctl try-reload-or-restart ssh.service || true' ]
final_message: 'cloud-init finished for $($n.Name) after `$UPTIME s'
"@

    $iso = Join-Path $vmDir "$($n.Name)-cidata.iso"
    New-CidataIso -SourceDir $seedDir -IsoPath $iso

    # ---- disk
    $vhdx = Join-Path $vmDir "$($n.Name).vhdx"
    Copy-Item $baseVhdx $vhdx
    & fsutil.exe sparse setflag $vhdx 0 | Out-Null
    Resize-VHD -Path $vhdx -SizeBytes $n.DiskBytes   # cloud-init growpart expands the root FS

    # ---- VM
    New-VM -Name $n.Name -Generation 2 -MemoryStartupBytes $n.MemoryBytes -VHDPath $vhdx `
           -SwitchName $SwitchName -Path $VmRoot | Out-Null
    # New-VM -Path puts the config in <VmRoot>\<vm>\Virtual Machines. Pin checkpoints and
    # smart paging to the same folder so nothing lands in the host's default Hyper-V paths.
    Set-VM -Name $n.Name -ProcessorCount $n.Cpu -StaticMemory `
           -SnapshotFileLocation $vmDir -SmartPagingFilePath $vmDir `
           -AutomaticStartAction StartIfRunning -AutomaticStartDelay $VmAutoStartDelaySec -AutomaticStopAction ShutDown `
           -CheckpointType Production -Notes "Kubernetes $($n.Role) - managed by 01-Provision-HyperV.ps1"
    if ((Get-Command Set-VM).Parameters.ContainsKey('AutomaticCheckpointsEnabled')) {
        Set-VM -Name $n.Name -AutomaticCheckpointsEnabled $false
    }
    Set-VMNetworkAdapter -VMName $n.Name -StaticMacAddress $n.Mac
    Add-VMDvdDrive -VMName $n.Name -Path $iso
    Set-VMFirmware -VMName $n.Name -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority `
                   -FirstBootDevice (Get-VMHardDiskDrive -VMName $n.Name)
    Enable-VMIntegrationService -VMName $n.Name -Name 'Guest Service Interface'
    Write-Ok "Created: $($n.Cpu) vCPU, $([int]($n.MemoryBytes/1GB)) GB RAM, $([int]($n.DiskBytes/1GB)) GB VHDX, MAC $($n.Mac), IP $($n.IP)"
}

# =============================================================================
# 7. Start and wait for SSH + cloud-init
# =============================================================================
Write-Step 'Starting VMs'
foreach ($n in $Nodes) {
    if ((Get-VM -Name $n.Name).State -ne 'Running') { Start-VM -Name $n.Name; Write-Ok "Started $($n.Name)" }
    else { Write-Ok "$($n.Name) already running" }
}

Write-Step 'Waiting for SSH and cloud-init on all nodes'
foreach ($n in $Nodes) {
    Wait-Ssh -Ip $n.IP -TimeoutSec $SshWaitTimeoutSec
    Write-Ok "$($n.Name) SSH reachable"
    # exit 2 = cloud-init finished with recoverable warnings
    $null = Invoke-Remote -Ip $n.IP -Command "timeout $CloudInitWaitTimeoutSec cloud-init status --wait --long" -Capture -AllowedExitCodes 0,2
    if ($LASTEXITCODE -eq 2) { Write-Warning "$($n.Name): cloud-init completed with warnings. Check /var/log/cloud-init.log." }
    $info = Invoke-Remote -Ip $n.IP -Command '. /etc/os-release; echo $PRETTY_NAME, kernel $(uname -r), active swap devices: $(swapon --noheadings | wc -l)' -Capture
    Write-Ok "$($n.Name): $info"
}

Write-Step 'VM storage locations'
$Nodes | ForEach-Object {
    $vm = Get-VM -Name $_.Name
    [pscustomobject]@{
        VM          = $vm.Name
        Config      = $vm.ConfigurationLocation
        Checkpoints = $vm.SnapshotFileLocation
        SmartPaging = $vm.SmartPagingFilePath
        Disk        = (Get-VMHardDiskDrive -VMName $vm.Name | Select-Object -First 1).Path
    }
} | Format-List | Out-Host

Write-Host "`nInfrastructure ready. Next: .\02-Bootstrap-Cluster.ps1" -ForegroundColor Green
Write-Host "SSH: ssh -i `"$SshPrivateKey`" -o UserKnownHostsFile=`"$SshKnownHosts`" $AdminUser@$(($Nodes | Where-Object { $_.Role -eq 'control-plane' }).IP)"
