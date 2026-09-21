# VPN Kill Switch — Windows
A PowerShell-based kill switch for OpenVPN on Windows 11. Blocks all internet traffic if the VPN drops. All while maintaining LAN access and RDP connectivity at all times if necessary.
The cleanest way to do this is with Windows Firewall rules — block all traffic by default, then whitelist only what's needed (LAN, RDP, and the VPN tunnel itself).

# How it works
- Set the default outbound policy to Block
- Whitelist your LAN subnet and RDP
- Whitelist the OpenVPN process and its tunnel interface
- When the VPN drops, no traffic flows

## Requirements
- Windows 11
- OpenVPN Connect installed with a working profile
- PowerShell run as Administrator

## First Time Setup
1. Connect to the VPN at least once so the TAP adapter is created
2. If scripts are blocked, run this once in elevated PowerShell:
```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```
3. Edit the configuration block at the top of `vpn-killswitch.ps1` to match your setup

## Configuration
```powershell
$VpnServerIP     = "YOUR.VPN.SERVER.IP"
$VpnServerPort   = 1194
$VpnProtocol     = "TCP"          # or UDP
$LanSubnet       = "192.168.1.0/24"
$TapAdapterName  = "Local Area Connection"   # From Get-NetAdapter output
$WifiAdapterName = "Wi-Fi"                   # Physical adapter name
$VpnDnsIP        = "YOUR.VPN.DNS.IP"         # Used only with -LockDNS
$OpenVpnExePath  = "C:\Program Files\OpenVPN Connect\OpenVPNConnect.exe"
$LogFile         = "C:\vpn-killswitch.log"
```
> To find your TAP adapter name, connect to the VPN then run:
> ```powershell
> Get-NetAdapter | Format-Table Name, InterfaceDescription, Status
> ```

---  
## Usage
```powershell
# Enable kill switch (standard)
.\vpn-killswitch.ps1 -Action Enable

# Enable with DNS locked to VPN DNS server
.\vpn-killswitch.ps1 -Action Enable -LockDNS

# Enable but leave IPv6 alone
.\vpn-killswitch.ps1 -Action Enable -AllowIPv6

# Enable without registering a startup task
.\vpn-killswitch.ps1 -Action Enable -DisableStartupTask

# Check current state
.\vpn-killswitch.ps1 -Action Status

# Disable and restore normal networking
.\vpn-killswitch.ps1 -Action Disable
```

## Optional Flags
| Flag | Default | Description |
|---|---|---|
| `-LockDNS` | Off | Restricts DNS to VPN's DNS server only, preventing DNS leaks |
| `-AllowIPv6` | Off | Skips IPv6 block (IPv6 is disabled by default) |
| `-DisableStartupTask` | Off | Skips registering the auto-start task on boot |

---

## Behavior
| State | Internet | LAN | RDP |
|---|---|---|---|
| Kill switch ON + VPN connected | ✅ | ✅ | ✅ |
| Kill switch ON + VPN dropped | ❌ | ✅ | ✅ |
| Kill switch OFF | ✅ | ✅ | ✅ |

---

## What It Does
- Blocks all outbound traffic by default via Windows Firewall
- Whitelists your LAN subnet, RDP, OpenVPN server, VPN tunnel interface, loopback, and DNS
- Optionally locks DNS to prevent leaks outside the VPN tunnel
- Disables IPv6 by default to prevent bypass via IPv6 traffic
- Binds the OpenVPN firewall rule to the OpenVPN executable (falls back to IP/port if not found)
- Registers a startup scheduled task so the kill switch auto-enables on reboot
- Logs all actions with timestamps to `C:\vpn-killswitch.log`

## Emergency Rollback
If you lose access or something breaks, from an elevated PowerShell:
```powershell
Set-NetFirewallProfile -Profile Domain,Public,Private -DefaultOutboundAction Allow
Get-NetFirewallRule | Where-Object { $_.DisplayName -like "KS -*" } | Remove-NetFirewallRule
```

## Changelog

### v2.0.0
- Added `-LockDNS` flag to optionally restrict DNS to VPN provider's DNS server
- Added `-AllowIPv6` flag — IPv6 is now blocked by default, opt-out with this flag
- Added `-DisableStartupTask` flag — startup task now registers by default, opt-out with this flag
- Added `-Action Status` to display current firewall state, rules, IPv6 status, and recent logs
- Added logging — all enable/disable/warning events written to `C:\vpn-killswitch.log`
- OpenVPN firewall rule is now process-bound to the OpenVPN executable for tighter security
  - Gracefully falls back to IP/port-only rule with a warning if executable is not found
- Startup task now preserves optional flags used at enable time
- Disable action now also re-enables IPv6 and removes the startup task automatically
- Added duplicate rule cleanup on enable to prevent rule conflicts

### v1.0.0
- Initial release
- Windows Firewall outbound block with LAN, RDP, OpenVPN server, TAP tunnel, loopback, and DNS allow rules
- Enable and Disable actions
- Configuration block for easy setup
