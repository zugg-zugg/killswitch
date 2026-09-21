#Commands
#   .\vpn-killswitch.ps1 -Action Enable
#   .\vpn-killswitch.ps1 -Action Disable
#   .\vpn-killswitch.ps1 -Action Status
#   .\vpn-killswitch.ps1 -Action Enable -LockDNS
#   .\vpn-killswitch.ps1 -Action Enable -AllowIPv6
#   .\vpn-killswitch.ps1 -Action Enable -DisableStartupTask

param (
    [Parameter(Mandatory=$true)]
    [ValidateSet("Enable", "Disable", "Status")]
    [string]$Action,

    # Optional: Lock DNS to VPN's DNS server only (default: open)
    [switch]$LockDNS,

    # Optional: Allow IPv6 traffic (default: IPv6 is blocked)
    [switch]$AllowIPv6,

    # Optional: Skip registering the startup scheduled task
    [switch]$DisableStartupTask
)


# CONFIGURATION — edit these to match your setup
$VpnServerIP     = "111.222.333.444" # VPN IP Address to whitelist for outbound
$VpnServerPort   = 1234 # VPN Port for whitelisting outbound - OpenVPN Default is 443/1194
$VpnProtocol     = "TCP" # Default Protocol - TCP
$LanSubnet       = "192.168.1.0/24" # Internal Subnet (192.168.1.0) to permit LAN/Network Share Access - Leave default for no local network access including RDP!.
$TapAdapterName  = "Local Area Connection" # Run from Powershell -  Get-NetAdapter output (The name of your Network Adapter)
$WifiAdapterName = "Wi-Fi" # Run from Powershell -  Get-NetAdapter output (The name of your Network Adapter)
$VpnDnsIP        = "123.456.789" # VPN provider's DNS IP - Necessary to reduce DNS leaking
$OpenVpnExePath  = "C:\Program Files\OpenVPN Connect\OpenVPNConnect.exe"
$LogFile         = "C:\vpn-killswitch.log"
$ScriptPath      = $MyInvocation.MyCommand.Path
# ============================================================

# Must be run as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

function Write-Log {
    param([string]$Message)
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message (User: $env:USERNAME)"
    Add-Content -Path $LogFile -Value $entry
}

function Enable-KillSwitch {
    Write-Host "`n[*] Enabling VPN Kill Switch..." -ForegroundColor Cyan
    Write-Log "Kill switch ENABLE initiated"

    # Remove any existing killswitch rules first to avoid duplicates
    $existing = Get-NetFirewallRule | Where-Object { $_.DisplayName -like "killswitch -*" }
    if ($existing) {
        Write-Host "[*] Removing existing killswitch rules..." -ForegroundColor Yellow
        $existing | Remove-NetFirewallRule
        Write-Log "Existing killswitch rules removed"
    }

    # -- IPv6 Block (default on, skip if -AllowIPv6 passed) --
    if (-not $AllowIPv6) {
        try {
            Disable-NetAdapterBinding -Name $WifiAdapterName -ComponentID ms_tcpip6 -ErrorAction Stop
            Write-Host "[+] IPv6 disabled on $WifiAdapterName" -ForegroundColor Green
            Write-Log "IPv6 disabled on $WifiAdapterName"
        } catch {
            Write-Host "[!] Could not disable IPv6 on ${WifiAdapterName}: $_" -ForegroundColor Yellow
            Write-Log "WARNING: Could not disable IPv6 on ${WifiAdapterName}: $_"
        }
    } else {
        Write-Host "[!] IPv6 block skipped (-AllowIPv6 flag set)" -ForegroundColor Yellow
        Write-Log "IPv6 block skipped - AllowIPv6 flag set"
    }

    # -- Allow LAN --
    New-NetFirewallRule -DisplayName "killswitch - Allow LAN" `
        -Direction Outbound -Action Allow `
        -RemoteAddress $LanSubnet -Profile Any -Enabled True | Out-Null
    Write-Host "[+] LAN access allowed ($LanSubnet)" -ForegroundColor Green

    # -- Allow RDP inbound from LAN --
    New-NetFirewallRule -DisplayName "killswitch - Allow RDP Inbound" `
        -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort 3389 `
        -RemoteAddress $LanSubnet -Profile Any -Enabled True | Out-Null
    Write-Host "[+] RDP inbound allowed from LAN" -ForegroundColor Green

    # -- Allow OpenVPN to reach server (process-bound if executable found) --
    if (Test-Path $OpenVpnExePath) {
        New-NetFirewallRule -DisplayName "killswitch - Allow OpenVPN Out" `
            -Direction Outbound -Action Allow `
            -Protocol $VpnProtocol -RemoteAddress $VpnServerIP `
            -RemotePort $VpnServerPort `
            -Program $OpenVpnExePath `
            -Profile Any -Enabled True | Out-Null
        Write-Host "[+] OpenVPN server allowed - process-bound to OpenVPNConnect.exe" -ForegroundColor Green
        Write-Log "OpenVPN rule applied - process-bound"
    } else {
        Write-Host "[!] OpenVPN executable not found at: $OpenVpnExePath" -ForegroundColor Yellow
        Write-Host "[!] Falling back to IP/port-only rule (less restrictive)" -ForegroundColor Yellow
        New-NetFirewallRule -DisplayName "killswitch - Allow OpenVPN Out" `
            -Direction Outbound -Action Allow `
            -Protocol $VpnProtocol -RemoteAddress $VpnServerIP `
            -RemotePort $VpnServerPort `
            -Profile Any -Enabled True | Out-Null
        Write-Log "WARNING: OpenVPN exe not found - fallback IP/port rule applied"
    }

    # -- Allow VPN tunnel interface --
    New-NetFirewallRule -DisplayName "killswitch - Allow VPN Tunnel" `
        -Direction Outbound -Action Allow `
        -InterfaceAlias $TapAdapterName -Profile Any -Enabled True | Out-Null
    Write-Host "[+] VPN tunnel interface allowed ($TapAdapterName)" -ForegroundColor Green

    # -- Allow loopback --
    New-NetFirewallRule -DisplayName "killswitch - Allow Loopback" `
        -Direction Outbound -Action Allow `
        -RemoteAddress 127.0.0.1 -Profile Any -Enabled True | Out-Null
    Write-Host "[+] Loopback allowed" -ForegroundColor Green

    # -- DNS (locked to VPN DNS or open) --
    if ($LockDNS) {
        New-NetFirewallRule -DisplayName "killswitch - Allow DNS" `
            -Direction Outbound -Action Allow `
            -Protocol UDP -RemotePort 53 `
            -RemoteAddress $VpnDnsIP `
            -Profile Any -Enabled True | Out-Null
        Write-Host "[+] DNS locked to VPN DNS server ($VpnDnsIP)" -ForegroundColor Green
        Write-Log "DNS locked to $VpnDnsIP"
    } else {
        New-NetFirewallRule -DisplayName "killswitch - Allow DNS" `
            -Direction Outbound -Action Allow `
            -Protocol UDP -RemotePort 53 `
            -Profile Any -Enabled True | Out-Null
        Write-Host "[+] DNS allowed (open) - use -LockDNS to restrict to VPN DNS only" -ForegroundColor Green
        Write-Log "DNS allowed open"
    }

    # -- Block all other outbound - the kill switch --
    Set-NetFirewallProfile -Profile Domain,Public,Private -DefaultOutboundAction Block
    Write-Host "[+] Default outbound policy set to BLOCK" -ForegroundColor Green

    # -- Startup task (default: enabled, skip if -DisableStartupTask passed) --
    if (-not $DisableStartupTask) {
        Register-StartupTask
    } else {
        Write-Host "[!] Startup task skipped (-DisableStartupTask flag set)" -ForegroundColor Yellow
        Write-Log "Startup task skipped - DisableStartupTask flag set"
    }

    Write-Log "Kill switch ENABLED successfully"
    Write-Host "`n[OK] Kill switch ENABLED. Internet will be blocked if VPN drops.`n" -ForegroundColor Cyan
    Show-Status
}

function Disable-KillSwitch {
    Write-Host "`n[*] Disabling VPN Kill Switch..." -ForegroundColor Cyan
    Write-Log "Kill switch DISABLE initiated"

    # Restore default outbound policy
    Set-NetFirewallProfile -Profile Domain,Public,Private -DefaultOutboundAction Allow
    Write-Host "[+] Default outbound policy restored to ALLOW" -ForegroundColor Green

    # Remove all killswitch rules
    $rules = Get-NetFirewallRule | Where-Object { $_.DisplayName -like "killswitch -*" }
    if ($rules) {
        $rules | Remove-NetFirewallRule
        Write-Host "[+] All killswitch firewall rules removed" -ForegroundColor Green
    } else {
        Write-Host "[!] No killswitch rules found to remove" -ForegroundColor Yellow
    }

    # Re-enable IPv6
    try {
        Enable-NetAdapterBinding -Name $WifiAdapterName -ComponentID ms_tcpip6 -ErrorAction Stop
        Write-Host "[+] IPv6 re-enabled on $WifiAdapterName" -ForegroundColor Green
        Write-Log "IPv6 re-enabled on $WifiAdapterName"
    } catch {
        Write-Host "[!] Could not re-enable IPv6 on ${WifiAdapterName}: $_" -ForegroundColor Yellow
        Write-Log "WARNING: Could not re-enable IPv6 on ${WifiAdapterName}: $_"
    }

    # Remove startup task if it exists
    if (Get-ScheduledTask -TaskName "VPN Kill Switch" -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName "VPN Kill Switch" -Confirm:$false
        Write-Host "[+] Startup task removed" -ForegroundColor Green
        Write-Log "Startup task removed"
    }

    Write-Log "Kill switch DISABLED successfully"
    Write-Host "`n[OK] Kill switch DISABLED. Normal network access restored.`n" -ForegroundColor Cyan
    Show-Status
}

function Register-StartupTask {
    try {
        if (-not $ScriptPath) {
            Write-Host "[!] Could not determine script path - startup task skipped" -ForegroundColor Yellow
            Write-Log "WARNING: Script path unknown - startup task not registered"
            return
        }

        # Build args preserving current optional flags
        $taskArgs = "-ExecutionPolicy Bypass -File `"$ScriptPath`" -Action Enable"
        if ($LockDNS)   { $taskArgs += " -LockDNS" }
        if ($AllowIPv6) { $taskArgs += " -AllowIPv6" }
        $taskArgs += " -DisableStartupTask"  # Prevent recursive task registration on boot

        $action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArgs
        $trigger  = New-ScheduledTaskTrigger -AtStartup
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

        # Remove existing task before re-registering
        if (Get-ScheduledTask -TaskName "VPN Kill Switch" -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName "VPN Kill Switch" -Confirm:$false
        }

        Register-ScheduledTask -TaskName "VPN Kill Switch" `
            -Action $action -Trigger $trigger `
            -RunLevel Highest -Settings $settings `
            -Description "Automatically enables the VPN kill switch on startup" | Out-Null

        Write-Host "[+] Startup task registered - kill switch will auto-enable on reboot" -ForegroundColor Green
        Write-Log "Startup task registered"
    } catch {
        Write-Host "[!] Could not register startup task: $_" -ForegroundColor Yellow
        Write-Log "WARNING: Could not register startup task: $_"
    }
}

function Show-Status {
    Write-Host "`n--- Current Status ---" -ForegroundColor White

    # Firewall profiles
    $profiles = Get-NetFirewallProfile | Select-Object Name, DefaultOutboundAction
    $profiles | Format-Table -AutoSize

    # killswitch rules
    $ksRules = Get-NetFirewallRule | Where-Object { $_.DisplayName -like "KS -*" } |
               Select-Object DisplayName, Enabled, Action, Direction
    if ($ksRules) {
        Write-Host "Active killswitch Rules:" -ForegroundColor White
        $ksRules | Format-Table -AutoSize
    } else {
        Write-Host "No killswitch rules active." -ForegroundColor Yellow
    }

    # IPv6 status
    $ipv6 = Get-NetAdapterBinding -Name $WifiAdapterName -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
    if ($ipv6) {
        $ipv6State = if ($ipv6.Enabled) { "Enabled" } else { "Disabled (blocked)" }
        Write-Host "IPv6 on ${WifiAdapterName}: $ipv6State`n" -ForegroundColor White
    }

    # Startup task
    $task = Get-ScheduledTask -TaskName "VPN Kill Switch" -ErrorAction SilentlyContinue
    $taskState = if ($task) { "Registered" } else { "Not registered" }
    Write-Host "Startup Task: $taskState" -ForegroundColor White

    # Log file location
    Write-Host "Log file: $LogFile" -ForegroundColor White

    # Recent log entries
    if (Test-Path $LogFile) {
        Write-Host "`nRecent log entries:" -ForegroundColor White
        Get-Content $LogFile | Select-Object -Last 5 | ForEach-Object {
            Write-Host "  $_" -ForegroundColor Gray
        }
    }
}

# -- Run --
switch ($Action) {
    "Enable"  { Enable-KillSwitch }
    "Disable" { Disable-KillSwitch }
    "Status"  { Show-Status }
}