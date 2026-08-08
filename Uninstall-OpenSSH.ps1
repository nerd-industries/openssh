#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Nerdy Neighbor - clean, complete OpenSSH removal.

.DESCRIPTION
    Reverses Install-OpenSSH.ps1:
      - Stops and deletes the sshd and ssh-agent services.
      - Removes our LAN firewall rule and any OpenSSH inbound rules.
      - Removes our authorized key (deletes administrators_authorized_keys if it
        only held our key).
      - Removes the Win32-OpenSSH install dir (C:\Program Files\OpenSSH) and the
        C:\ProgramData\ssh config/host-key dir.
      - Removes the OpenSSH Windows capability if it was installed that way.
      - Clears the OpenSSH DefaultShell registry value.

.NOTES
    Run with:  irm openssh-uninstall.nerdyneighbor.net | iex   (elevated PowerShell)
#>

$ErrorActionPreference = 'Continue'   # best-effort: keep going through every step
$ProgressPreference    = 'SilentlyContinue'

$InstallDir       = "C:\Program Files\OpenSSH"
$SshDataDir       = "C:\ProgramData\ssh"
$FirewallRuleName = "OpenSSH-Server-In-TCP-LAN"
$OurKeyBody       = "AAAAC3NzaC1lZDI1NTE5AAAAIAQwebAP+RXnuDkk5VFYlQlvWpf6BZFZU6kX/HrQsOhE"   # claude-debug

function Show-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }

try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }

    # --- 1) Stop + delete services ------------------------------------------
    foreach ($svc in 'sshd','ssh-agent') {
        $s = Get-Service $svc -ErrorAction SilentlyContinue
        if ($s) {
            Show-Step "Stopping and deleting service: $svc"
            Stop-Service $svc -Force -ErrorAction SilentlyContinue
            & sc.exe delete $svc | Out-Null
        }
    }

    # --- 2) Firewall rules ---------------------------------------------------
    Show-Step "Removing firewall rules..."
    Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    foreach ($dn in @("OpenSSH SSH Server (LAN only)","OpenSSH-Server-In-TCP","OpenSSH SSH Server","OpenSSH SSH Server (sshd)","sshd")) {
        Get-NetFirewallRule -DisplayName $dn -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }

    # --- 3) Authorized key ---------------------------------------------------
    $authKeys = Join-Path $SshDataDir "administrators_authorized_keys"
    if (Test-Path $authKeys) {
        Show-Step "Removing our authorized key..."
        $kept = Get-Content $authKeys -ErrorAction SilentlyContinue | Where-Object { $_ -and ($_ -notmatch [regex]::Escape($OurKeyBody)) }
        if ($kept) {
            Set-Content -Path $authKeys -Value $kept -Encoding ascii
            Write-Host "    Left $($kept.Count) other key line(s) in place."
        } else {
            Remove-Item $authKeys -Force -ErrorAction SilentlyContinue
            Write-Host "    Removed administrators_authorized_keys (held only our key)."
        }
    }

    # --- 4) Install + data dirs ---------------------------------------------
    foreach ($dir in @($InstallDir, $SshDataDir)) {
        if (Test-Path $dir) {
            Show-Step "Removing $dir"
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $dir) { Write-Host "    Could not fully remove $dir (locked - may need a reboot)." -ForegroundColor Yellow }
        }
    }

    # --- 5) Windows capability (if OpenSSH was installed via FoD) ------------
    $cap = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'OpenSSH.Server*' -and $_.State -eq 'Installed' }
    if ($cap) {
        Show-Step "Removing OpenSSH Server Windows capability..."
        $cap | ForEach-Object { Remove-WindowsCapability -Online -Name $_.Name -ErrorAction SilentlyContinue | Out-Null }
    }

    # --- 6) DefaultShell registry value -------------------------------------
    if (Test-Path "HKLM:\SOFTWARE\OpenSSH") {
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -ErrorAction SilentlyContinue
    }

    # --- Verify --------------------------------------------------------------
    Show-Step "Verifying..."
    $svcLeft  = Get-Service sshd -ErrorAction SilentlyContinue
    $ruleLeft = Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue
    $dirLeft  = Test-Path $InstallDir
    if ($svcLeft -or $ruleLeft -or $dirLeft) {
        Write-Host ""
        Write-Host "Partly removed - some traces remain (service=$([bool]$svcLeft) rule=$([bool]$ruleLeft) dir=$dirLeft)." -ForegroundColor Yellow
        Write-Host "Reboot and re-run to finish." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    Write-Host ""
    Write-Host "OpenSSH fully removed." -ForegroundColor Green
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo.ScriptLineNumber) {
        Write-Host "  at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray
    }
    exit 1
}
