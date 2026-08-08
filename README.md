# openssh (Nerdy Neighbor)

Fast, clean Win32-OpenSSH deploy for Windows, delivered the same way as
`audit.nerdyneighbor.net`: a Cloudflare Pages Function fetches the script from
this repo via the GitHub Contents API, so edits here go live immediately.

## Use

Elevated Windows PowerShell:

```powershell
# Install: latest Win32-OpenSSH, LAN-locked (TCP 22 from LocalSubnet only), our admin key
irm openssh.nerdyneighbor.net | iex

# Uninstall: remove service, firewall rule, key, install + config dirs
irm openssh-uninstall.nerdyneighbor.net | iex
```

Connect from the LAN (uses this box's default key, `id_ed25519` / `claude-debug`):

```
ssh Administrator@<pc-name-or-ip>
```

## What the installer does

- Downloads the newest `OpenSSH-Win64.zip` from the `PowerShell/Win32-OpenSSH`
  GitHub release (fallback: `bd.nerdindustries.net` R2 mirror).
- Cleanly removes any prior `sshd`/`ssh-agent` service first.
- Extracts to `C:\Program Files\OpenSSH`, runs `install-sshd.ps1`, sets the
  service Automatic + starts it, PowerShell as default remote shell.
- Authorizes the admin key in `administrators_authorized_keys` with the correct
  locked-down ACL (SYSTEM + Administrators, no inheritance).
- Firewall: inbound TCP 22 restricted to `LocalSubnet` (LAN only), Profile Any.

## Delivery

- Pages project `nerdyneighbor-openssh` -> `openssh.nerdyneighbor.net`
- Pages project `nerdyneighbor-openssh-uninstall` -> `openssh-uninstall.nerdyneighbor.net`

Each Pages Function fetches its `.ps1` from this repo via the GitHub Contents API.
