# =============================================================================
#  lib/common.ps1 - shared helpers (logging, IP math, SSH/SCP wrappers)
# =============================================================================
Set-StrictMode -Version Latest

function Write-Step([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    [ok] $Message" -ForegroundColor Green }
function Write-Info([string]$Message) { Write-Host "    $Message" }

function ConvertTo-UInt32Ip([string]$Ip) {
    $b = ([System.Net.IPAddress]::Parse($Ip)).GetAddressBytes()
    [Array]::Reverse($b)
    return [BitConverter]::ToUInt32($b, 0)
}

function Test-SameSubnet([string]$IpA, [string]$IpB, [int]$Prefix) {
    $all  = [uint64]4294967295
    $mask = if ($Prefix -eq 0) { [uint32]0 } else { [uint32](($all -shl (32 - $Prefix)) -band $all) }
    return ((ConvertTo-UInt32Ip $IpA) -band $mask) -eq ((ConvertTo-UInt32Ip $IpB) -band $mask)
}

function Test-CidrOverlap([string]$CidrA, [string]$CidrB) {
    $a, $pa = $CidrA.Split('/'); $b, $pb = $CidrB.Split('/')
    $p = [Math]::Min([int]$pa, [int]$pb)
    return Test-SameSubnet $a $b $p
}

function Test-IpInUse([string]$Ip) {
    try { return ((New-Object System.Net.NetworkInformation.Ping).Send($Ip, 1000).Status -eq 'Success') }
    catch { return $false }
}

function Test-TcpPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 3000) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        return ($task.Wait($TimeoutMs) -and $client.Connected)
    } catch { return $false } finally { $client.Dispose() }
}

function Get-SshBaseArgs {
    return @(
        '-i', $SshPrivateKey,
        '-o', 'BatchMode=yes',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', "UserKnownHostsFile=$SshKnownHosts",
        '-o', 'ConnectTimeout=10',
        '-o', 'ServerAliveInterval=15',
        '-o', 'ServerAliveCountMax=8',
        '-o', 'LogLevel=ERROR'
    )
}

# NOTE: native-command helpers set $ErrorActionPreference = 'Continue' locally because
# Windows PowerShell 5.1 turns *redirected* native stderr into terminating errors under
# 'Stop'. Success is decided strictly by exit code instead.

# Runs a remote command, streaming output live unless -Capture is used.
# -InputText is piped to the remote command's stdin (used for secrets such as the
# join command so they never appear on any command line or in `ps` output).
function Invoke-Remote {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Command,
        [string]$InputText,
        [switch]$Capture,
        [int[]]$AllowedExitCodes = @(0)
    )
    $ErrorActionPreference = 'Continue'
    $sshArgs  = (Get-SshBaseArgs) + @("$AdminUser@$Ip", $Command)
    $hasInput = $PSBoundParameters.ContainsKey('InputText')
    $out = $null
    if ($Capture) {
        if ($hasInput) { $out = $InputText | & ssh.exe @sshArgs } else { $out = & ssh.exe @sshArgs }
    } else {
        if ($hasInput) { $InputText | & ssh.exe @sshArgs | Out-Host } else { & ssh.exe @sshArgs | Out-Host }
    }
    $code = $LASTEXITCODE
    if ($AllowedExitCodes -notcontains $code) {
        throw "Remote command failed on $Ip (exit $code): $($Command.Substring(0, [Math]::Min(120, $Command.Length)))"
    }
    if ($Capture) { return $out }
}

function Copy-ToRemote {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][string[]]$Paths, [Parameter(Mandatory)][string]$RemoteDir)
    $ErrorActionPreference = 'Continue'
    $scpArgs = @('-q') + (Get-SshBaseArgs) + $Paths + @("$AdminUser@${Ip}:$RemoteDir/")
    & scp.exe @scpArgs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "scp to $Ip failed (exit $LASTEXITCODE)" }
}

function Copy-FromRemote {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][string]$RemotePath, [Parameter(Mandatory)][string]$LocalPath)
    $ErrorActionPreference = 'Continue'
    $scpArgs = @('-q') + (Get-SshBaseArgs) + @("$AdminUser@${Ip}:$RemotePath", $LocalPath)
    & scp.exe @scpArgs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "scp from $Ip failed (exit $LASTEXITCODE)" }
}

function Remove-KnownHost([string]$Ip) {
    $ErrorActionPreference = 'Continue'
    if (Test-Path $SshKnownHosts) { & ssh-keygen.exe -R $Ip -f $SshKnownHosts 2>&1 | Out-Null }
}

# Waits until TCP/22 is open AND key-based login succeeds.
function Wait-Ssh {
    param([Parameter(Mandatory)][string]$Ip, [int]$TimeoutSec = 900)
    $ErrorActionPreference = 'Continue'
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort -HostName $Ip -Port 22) {
            $sshArgs = (Get-SshBaseArgs) + @("$AdminUser@$Ip", 'true')
            & ssh.exe @sshArgs 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { return }
        }
        Start-Sleep -Seconds 5
    }
    throw "SSH on $Ip did not become available within $TimeoutSec s"
}

function Assert-Tool([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "'$Name' not found. Install the Windows OpenSSH Client: Settings > System > Optional features > OpenSSH Client."
    }
}

function Assert-Config {
    if (@($Nodes | Where-Object { $_.Role -eq 'control-plane' }).Count -ne 1) { throw 'Exactly one control-plane node must be defined in $Nodes.' }
    $names = $Nodes.Name; $ips = $Nodes.IP; $macs = $Nodes.Mac
    if (($names | Select-Object -Unique).Count -ne $names.Count) { throw 'Duplicate node names in $Nodes.' }
    if (($ips   | Select-Object -Unique).Count -ne $ips.Count)   { throw 'Duplicate IPs in $Nodes.' }
    if (($macs  | Select-Object -Unique).Count -ne $macs.Count)  { throw 'Duplicate MACs in $Nodes.' }
    foreach ($n in $Nodes) {
        if ($n.Mac -notmatch '^[0-9A-Fa-f]{12}$') { throw "Invalid MAC '$($n.Mac)' for $($n.Name) (use 12 hex digits, no separators)." }
        [void][System.Net.IPAddress]::Parse($n.IP)
        if (Test-CidrOverlap "$($n.IP)/32" $PodCidr)     { throw "Node IP $($n.IP) overlaps PodCidr $PodCidr." }
        if (Test-CidrOverlap "$($n.IP)/32" $ServiceCidr) { throw "Node IP $($n.IP) overlaps ServiceCidr $ServiceCidr." }
    }
    if (Test-CidrOverlap $PodCidr $ServiceCidr) { throw 'PodCidr and ServiceCidr overlap.' }

    # MetalLB pool sanity
    $poolStart, $poolEnd = $MetalLbPool.Split('-').Trim()
    $ps = ConvertTo-UInt32Ip $poolStart; $pe = ConvertTo-UInt32Ip $poolEnd
    if ($ps -gt $pe) { throw "MetalLbPool '$MetalLbPool' start is after end." }
    foreach ($n in $Nodes) {
        $ip = ConvertTo-UInt32Ip $n.IP
        if ($ip -ge $ps -and $ip -le $pe) { throw "Node IP $($n.IP) is inside MetalLbPool $MetalLbPool." }
    }
    foreach ($gw in @($CiliumGatewayIP, $IstioGatewayIP)) {
        $ip = ConvertTo-UInt32Ip $gw
        if ($ip -lt $ps -or $ip -gt $pe) { throw "Gateway IP $gw is outside MetalLbPool $MetalLbPool." }
    }
    if ($CiliumGatewayIP -eq $IstioGatewayIP) { throw 'CiliumGatewayIP and IstioGatewayIP must differ.' }
}
