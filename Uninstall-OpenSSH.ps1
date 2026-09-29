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

$HasNetSecurity = [bool](Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue)

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
    $ruleNames = @("OpenSSH SSH Server (LAN only)","OpenSSH-Server-In-TCP","OpenSSH SSH Server","OpenSSH SSH Server (sshd)","sshd")
    if ($HasNetSecurity) {
        Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        foreach ($dn in $ruleNames) {
            Get-NetFirewallRule -DisplayName $dn -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        }
    } else {
        # Windows 7: no NetSecurity module; netsh addresses rules by display name
        foreach ($dn in $ruleNames + @($FirewallRuleName)) { & netsh.exe advfirewall firewall delete rule name="$dn" | Out-Null }
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
    # install-sshd.ps1 registered an event-log provider from this folder; unregister
    # it before the manifest is deleted, like the bundled uninstall-sshd.ps1 does.
    $etwman = Join-Path $InstallDir "openssh-events.man"
    if (Test-Path $etwman) {
        Show-Step "Unregistering OpenSSH event log provider..."
        & wevtutil.exe um "$etwman" 2>&1 | Out-Null
    }
    # Newer install-sshd.ps1 adds the install dir to the machine PATH.
    $envKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    # Read the raw value so %SystemRoot%-style entries aren't expanded on write-back.
    $mPath   = (Get-Item $envKey).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    $newPath = ($mPath -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ne $InstallDir) }) -join ';'
    if ($newPath -ne $mPath) {
        Show-Step "Removing $InstallDir from the system PATH..."
        Set-ItemProperty $envKey -Name Path -Value $newPath -Type ExpandString
    }
    foreach ($dir in @($InstallDir, $SshDataDir)) {
        if (Test-Path $dir) {
            Show-Step "Removing $dir"
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $dir) { Write-Host "    Could not fully remove $dir (locked - may need a reboot)." -ForegroundColor Yellow }
        }
    }

    # --- 5) Windows capability (if OpenSSH was installed via FoD) ------------
    # Get-WindowsCapability doesn't exist on Windows 7; calling it there would throw
    # into the catch block and skip the remaining steps.
    $cap = $null
    if (Get-Command Get-WindowsCapability -ErrorAction SilentlyContinue) {
        $cap = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'OpenSSH.Server*' -and $_.State -eq 'Installed' }
    }
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
    if ($HasNetSecurity) {
        $ruleLeft = Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue
    } else {
        & netsh.exe advfirewall firewall show rule name="OpenSSH SSH Server (LAN only)" | Out-Null
        $ruleLeft = ($LASTEXITCODE -eq 0)
    }
    $dirLeft  = Test-Path $InstallDir
    if ($svcLeft -or $ruleLeft -or $dirLeft) {
        Write-Host ""
        Write-Host "Partly removed - some traces remain (service=$([bool]$svcLeft) rule=$([bool]$ruleLeft) dir=$dirLeft)." -ForegroundColor Yellow
        Write-Host "Reboot and re-run to finish." -ForegroundColor Yellow
        Write-Host ""
        return
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
    return   # not exit: under irm | iex, exit closes the tech's PowerShell window
}
