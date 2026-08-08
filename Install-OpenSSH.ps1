#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Nerdy Neighbor - fast, clean Win32-OpenSSH install, LAN-locked, with our key.

.DESCRIPTION
    Installs OpenSSH Server on Windows:
      - Downloads the latest OpenSSH-Win64.zip straight from the
        PowerShell/Win32-OpenSSH GitHub release (always the newest version),
        falling back to the nerdindustries R2 mirror only if GitHub is
        unreachable.
      - Cleanly removes any prior sshd/ssh-agent service first.
      - Extracts to C:\Program Files\OpenSSH, runs install-sshd.ps1, sets the
        service to Automatic and starts it, and makes PowerShell the default
        remote shell.
      - Authorizes our admin key in administrators_authorized_keys with the
        correct locked-down ACL (SYSTEM + Administrators only, no inheritance).
      - Firewall: inbound TCP 22 restricted to LocalSubnet (LAN only) on any
        network profile; strips broad OpenSSH rules so nothing else exposes it.

.NOTES
    Run with:  irm openssh.nerdyneighbor.net | iex   (elevated PowerShell)
    Remove with: irm openssh-uninstall.nerdyneighbor.net | iex

    Connect from the LAN:  ssh <your-admin-user>@<pc-name-or-ip>
    (any Administrators-group user; the admin key works for all of them.
     uses this box's default key, id_ed25519 / claude-debug)
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Config ------------------------------------------------------------------
# Our admin key (goes in administrators_authorized_keys -> works for any account
# in the Administrators group).
$PubKey           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAQwebAP+RXnuDkk5VFYlQlvWpf6BZFZU6kX/HrQsOhE claude-debug"
$InstallDir       = "C:\Program Files\OpenSSH"
$MirrorUrl        = "https://bd.nerdindustries.net/OpenSSH-Win64.zip"   # fast primary source
$FirewallRuleName = "OpenSSH-Server-In-TCP-LAN"

function Show-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }

# Fast download: WebClient straight to disk (no IWR buffering/progress), BITS fallback.
function Get-File {
    param([string]$Url, [string]$Out)
    try { (New-Object System.Net.WebClient).DownloadFile($Url, $Out) }
    catch {
        Import-Module BitsTransfer -ErrorAction SilentlyContinue
        Start-BitsTransfer -Source $Url -Destination $Out -ErrorAction Stop
    }
}

# Get OpenSSH-Win64.zip: latest GitHub release first (always newest), R2 mirror fallback.
function Get-OpenSSHZip {
    param([string]$Dest)
    try {
        Show-Step "Fetching latest Win32-OpenSSH release from GitHub..."
        $rel   = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest" -UseBasicParsing
        $asset = $rel.assets | Where-Object { $_.name -eq "OpenSSH-Win64.zip" } | Select-Object -First 1
        if (-not $asset) { throw "OpenSSH-Win64.zip not found in latest release ($($rel.tag_name))" }
        Write-Host "    Version: $($rel.tag_name)"
        Get-File $asset.browser_download_url $Dest
        if ((Get-Item $Dest).Length -gt 1MB) { return $rel.tag_name }
        throw "downloaded zip looks incomplete"
    } catch {
        Show-Step "GitHub unavailable ($($_.Exception.Message)) - falling back to nerdindustries mirror..."
        $cb = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Get-File "$MirrorUrl`?t=$cb" $Dest
        return "mirror"
    }
}

try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }

    # --- 1) Remove any prior OpenSSH services so the install is clean --------
    foreach ($svc in 'sshd','ssh-agent') {
        $s = Get-Service $svc -ErrorAction SilentlyContinue
        if ($s) {
            Show-Step "Removing existing service: $svc"
            Stop-Service $svc -Force -ErrorAction SilentlyContinue
            & sc.exe delete $svc | Out-Null
        }
    }
    Start-Sleep -Seconds 1

    # --- 2) Download + extract ----------------------------------------------
    $zip = Join-Path $env:TEMP "OpenSSH-Win64.zip"
    $src = Get-OpenSSHZip $zip
    Write-Host "    Source: $src"

    Show-Step "Extracting to $InstallDir..."
    $stage = Join-Path $env:TEMP "OpenSSH-stage-$([System.Guid]::NewGuid())"
    try { Expand-Archive -Path $zip -DestinationPath $stage -Force }
    catch {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $stage)
    }
    $extracted = Get-ChildItem -Path $stage -Directory | Select-Object -First 1
    if (-not $extracted) { throw "Unexpected archive layout - no directory inside zip." }

    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
    Move-Item -Path $extracted.FullName -Destination $InstallDir -Force
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zip   -Force        -ErrorAction SilentlyContinue

    # --- 3) Install + start the service -------------------------------------
    Show-Step "Running install-sshd.ps1..."
    $installScript = Join-Path $InstallDir "install-sshd.ps1"
    if (-not (Test-Path $installScript)) { throw "install-sshd.ps1 not found in extracted archive." }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript | Out-Null

    Show-Step "Setting sshd to Automatic and starting it..."
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd

    # Default remote shell = PowerShell
    if (-not (Test-Path "HKLM:\SOFTWARE\OpenSSH")) { New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null }
    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
        -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force | Out-Null

    # --- 4) Authorize our admin key -----------------------------------------
    Show-Step "Installing authorized admin key..."
    $sshDir = "C:\ProgramData\ssh"
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
    $authKeys = Join-Path $sshDir "administrators_authorized_keys"

    # Match by the key body (col 2), so a changed comment doesn't duplicate it.
    $keyBody  = ($PubKey -split '\s+')[1]
    $existing = if (Test-Path $authKeys) { Get-Content $authKeys -ErrorAction SilentlyContinue } else { @() }
    if (-not ($existing | Where-Object { $_ -match [regex]::Escape($keyBody) })) {
        Add-Content -Path $authKeys -Value $PubKey -Encoding ascii
        Write-Host "    Key added"
    } else {
        Write-Host "    Key already present, skipping"
    }
    # Required ACL: only SYSTEM + Administrators, no inheritance.
    & icacls.exe $authKeys /inheritance:r /grant "SYSTEM:F" /grant "BUILTIN\Administrators:F" | Out-Null

    # --- 5) Firewall: TCP 22 inbound, LAN (LocalSubnet) only ----------------
    Show-Step "Configuring firewall: TCP 22 inbound, LocalSubnet only..."
    foreach ($dn in @("OpenSSH-Server-In-TCP","OpenSSH SSH Server","OpenSSH SSH Server (sshd)","sshd")) {
        Get-NetFirewallRule -DisplayName $dn -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
    Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue

    New-NetFirewallRule `
        -Name $FirewallRuleName `
        -DisplayName "OpenSSH SSH Server (LAN only)" `
        -Description "Inbound TCP 22 restricted to LocalSubnet for sshd.exe" `
        -Enabled True -Direction Inbound -Action Allow -Protocol TCP `
        -LocalPort 22 -RemoteAddress LocalSubnet -Profile Any `
        -Program (Join-Path $InstallDir "sshd.exe") | Out-Null

    # --- 6) Verify + report -------------------------------------------------
    Show-Step "Verifying..."
    $sshd = Get-Service sshd
    Write-Host "    sshd: $($sshd.Status) (startup: $($sshd.StartType))"
    $rule = Get-NetFirewallRule -Name $FirewallRuleName
    $port = $rule | Get-NetFirewallPortFilter
    $addr = $rule | Get-NetFirewallAddressFilter
    Write-Host "    Firewall: enabled=$($rule.Enabled) profile=$($rule.Profile) port=$($port.LocalPort) from=$($addr.RemoteAddress -join ',')"

    $ip = (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1 -ExpandProperty IPAddress)

    # Show the connect command for the actual logged-in user. Prefer the
    # interactive console user (correct even when the script is elevated as a
    # different admin), falling back to whoever is running it. The admin key
    # authorizes any Administrators-group account, so this is just the label.
    $loginUser = $env:USERNAME
    try {
        $csUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
        if ($csUser) { $loginUser = ($csUser -split '\\')[-1] }
    } catch { }

    Write-Host ""
    Write-Host "OpenSSH installed and locked to LAN." -ForegroundColor Green
    Write-Host ""
    Write-Host "  Connect from the LAN (any Administrators-group user):"
    Write-Host "    ssh $loginUser@$($env:COMPUTERNAME)"
    if ($ip) { Write-Host "    ssh $loginUser@$ip" }
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
