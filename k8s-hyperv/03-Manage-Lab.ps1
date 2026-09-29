#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Day-to-day lab operations: status, ordered start/stop, and cluster-consistent checkpoints.

.DESCRIPTION
    Status      VM state, uptime, checkpoints, storage location, node readiness.
    Start       Control plane first, then workers; waits for SSH and prints `kubectl get nodes`.
    Stop        Workers first, then control plane (graceful guest shutdown). Do this before
                unplugging the USB SSD, rebooting or sleeping the host.
    Checkpoint  Stops the whole cluster, checkpoints every VM under one name, restarts it.
                Stopping first keeps etcd and all nodes consistent with each other.
    Restore     Stops the cluster, applies the named checkpoint on every VM, restarts it.
    Remove      Deletes the named checkpoint from every VM (merges .avhdx files).
    List        Lists checkpoints per VM.

.EXAMPLE
    .\03-Manage-Lab.ps1 -Action Status
    .\03-Manage-Lab.ps1 -Action Checkpoint -Name 'baseline'
    .\03-Manage-Lab.ps1 -Action Restore -Name 'baseline'
    .\03-Manage-Lab.ps1 -Action Stop
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Status', 'Start', 'Stop', 'Checkpoint', 'Restore', 'Remove', 'List')]
    [string]$Action,
    [string]$Name,
    [switch]$NoStart,          # Checkpoint/Restore: leave the cluster stopped afterwards
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'cluster.config.ps1')
)

$ErrorActionPreference = 'Stop'
. $ConfigPath
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$Nodes   = @($Nodes | ForEach-Object { [pscustomobject]$_ })
$cp      = $Nodes | Where-Object { $_.Role -eq 'control-plane' } | Select-Object -First 1
$workers = @($Nodes | Where-Object { $_.Role -ne 'control-plane' })

if ($Action -in 'Checkpoint', 'Restore', 'Remove' -and -not $Name) { throw "-Name is required for -Action $Action" }
foreach ($n in $Nodes) { if (-not (Get-VM -Name $n.Name -ErrorAction SilentlyContinue)) { throw "VM $($n.Name) not found - run 01-Provision-HyperV.ps1" } }

function Test-StorageOnline {
    $letter = (Split-Path -Path $VmRoot -Qualifier).TrimEnd(':')
    if (-not (Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue)) {
        throw "Lab drive ${letter}: is not connected. Reconnect the SSD before starting VMs."
    }
}

function Stop-Lab {
    Write-Step 'Stopping cluster (workers first, then control plane)'
    foreach ($n in @($workers) + @($cp)) {
        $vm = Get-VM -Name $n.Name
        if ($vm.State -eq 'Off') { Write-Ok "$($n.Name) already off"; continue }
        if ($vm.State -eq 'Saved') { Write-Ok "$($n.Name) is saved (state kept on disk)"; continue }
        Stop-VM -Name $n.Name -Force          # -Force: skip the confirmation prompt; still a guest shutdown
        Write-Ok "$($n.Name) shut down"
    }
}

function Start-Lab {
    Test-StorageOnline
    Write-Step 'Starting cluster (control plane first)'
    foreach ($n in @($cp) + @($workers)) {
        if ((Get-VM -Name $n.Name).State -ne 'Running') { Start-VM -Name $n.Name; Write-Ok "$($n.Name) starting" }
        else { Write-Ok "$($n.Name) already running" }
        if ($n.Name -eq $cp.Name) { Wait-Ssh -Ip $cp.IP -TimeoutSec $SshWaitTimeoutSec; Write-Ok 'control plane reachable' }
    }
    foreach ($w in $workers) { Wait-Ssh -Ip $w.IP -TimeoutSec $SshWaitTimeoutSec }
    Write-Step 'Waiting for nodes to become Ready'
    Invoke-Remote -Ip $cp.IP -Command 'kubectl wait --for=condition=Ready nodes --all --timeout=300s >/dev/null 2>&1; kubectl get nodes -o wide' -AllowedExitCodes 0, 1
}

switch ($Action) {
    'Status' {
        Write-Step "Lab status ($VmRoot)"
        $Nodes | ForEach-Object {
            $vm = Get-VM -Name $_.Name
            [pscustomobject]@{
                VM          = $vm.Name
                State       = $vm.State
                Uptime      = if ($vm.State -eq 'Running') { '{0:dd\.hh\:mm}' -f $vm.Uptime } else { '-' }
                IP          = $_.IP
                Checkpoints = @(Get-VMCheckpoint -VMName $vm.Name -ErrorAction SilentlyContinue).Count
                Location    = $vm.ConfigurationLocation
            }
        } | Format-Table -AutoSize | Out-Host
        if ((Get-VM -Name $cp.Name).State -eq 'Running' -and (Test-TcpPort -HostName $cp.IP -Port 22)) {
            Invoke-Remote -Ip $cp.IP -Command 'kubectl get nodes -o wide; echo; kubectl get gateway -A 2>/dev/null' -AllowedExitCodes 0, 1
        }
    }
    'Start' { Start-Lab }
    'Stop'  { Stop-Lab }
    'List' {
        foreach ($n in $Nodes) {
            $cps = @(Get-VMCheckpoint -VMName $n.Name -ErrorAction SilentlyContinue)
            Write-Host "$($n.Name):" -ForegroundColor Cyan
            if ($cps.Count -eq 0) { Write-Host '    (none)' }
            $cps | ForEach-Object { Write-Host ("    {0,-30} {1}" -f $_.Name, $_.CreationTime) }
        }
    }
    'Checkpoint' {
        Test-StorageOnline
        $wasRunning = (Get-VM -Name $cp.Name).State -eq 'Running'
        Stop-Lab
        Write-Step "Creating checkpoint '$Name' on all nodes"
        foreach ($n in $Nodes) {
            if (Get-VMCheckpoint -VMName $n.Name -Name $Name -ErrorAction SilentlyContinue) { throw "$($n.Name) already has a checkpoint named '$Name'" }
            Checkpoint-VM -Name $n.Name -SnapshotName $Name
            Write-Ok "$($n.Name) -> '$Name'"
        }
        if ($wasRunning -and -not $NoStart) { Start-Lab }
    }
    'Restore' {
        Test-StorageOnline
        foreach ($n in $Nodes) {
            if (-not (Get-VMCheckpoint -VMName $n.Name -Name $Name -ErrorAction SilentlyContinue)) { throw "$($n.Name) has no checkpoint named '$Name'" }
        }
        Stop-Lab
        Write-Step "Restoring checkpoint '$Name' on all nodes"
        foreach ($n in $Nodes) {
            Get-VMCheckpoint -VMName $n.Name -Name $Name | Restore-VMCheckpoint -Confirm:$false
            Write-Ok "$($n.Name) restored"
        }
        if (-not $NoStart) { Start-Lab }
    }
    'Remove' {
        foreach ($n in $Nodes) {
            $c = Get-VMCheckpoint -VMName $n.Name -Name $Name -ErrorAction SilentlyContinue
            if ($c) { $c | Remove-VMCheckpoint -Confirm:$false; Write-Ok "$($n.Name): removed '$Name' (disk merge runs in the background)" }
            else { Write-Info "$($n.Name): no checkpoint '$Name'" }
        }
    }
}
