#Commands
#.\vpn-killswitch.ps1 -Action Enable
#.\vpn-killswitch.ps1 -Action Disable
param (
    [Parameter(Mandatory=$true)]
    [ValidateSet("Enable", "Disable")]
    [string]$Action
)

# CONFIGURATION
$VpnServerIP    = "111.222.333.444" # VPN IP Address to whitelist for outbound
$VpnServerPort  = 1234 # VPN Port for whitelisting outbound - OpenVPN Default is 443/1194
$VpnProtocol    = "TCP" # Default Protocol - TCP
$LanSubnet      = "0.0.0.0/24" # Internal Subnet (192.168.1.1) to permit LAN/Network Share Access - Leave default for no local network access including RDP!.
$TapAdapterName = "Local Area Connection"   # Run from Powershell -  Get-NetAdapter output (The name of your Network Adapter)


# Must be run as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

function Enable-KillSwitch {
    Write-Host "`n[*] Enabling VPN Kill Switch..." -ForegroundColor Cyan

    # Removes any existing rules first to avoid duplicate rule issues.
    $existing = Get-NetFirewallRule | Where-Object { $_.DisplayName -like "KS -*" }
    if ($existing) {
        Write-Host "[*] Removing existing KS rules..." -ForegroundColor Yellow
        $existing | Remove-NetFirewallRule
    }

    # Allows lan access, creating rules and then prints them to the console.
    New-NetFirewallRule -DisplayName "KS - Allow LAN" `
        -Direction Outbound -Action Allow `
        -RemoteAddress $LanSubnet -Profile Any -Enabled True | Out-Null
    Write-Host "[+] LAN access allowed ($LanSubnet)" -ForegroundColor Green

    # Allow RDP inbound from LAN - YOU MUST SUPPLY VALUE FOR LAN SUBNET TO FUNCTION
    New-NetFirewallRule -DisplayName "KS - Allow RDP Inbound" `
        -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort 3389 `
        -RemoteAddress $LanSubnet -Profile Any -Enabled True | Out-Null
    Write-Host "[+] RDP inbound allowed from LAN" -ForegroundColor Green

    # Allow vpn client to reach server
    New-NetFirewallRule -DisplayName "KS - Allow vpn client Out" `
        -Direction Outbound -Action Allow `
        -Protocol $VpnProtocol -RemoteAddress $VpnServerIP `
        -RemotePort $VpnServerPort -Profile Any -Enabled True | Out-Null
    Write-Host "[+] VPN server allowed ($VpnServerIP`:$VpnServerPort $VpnProtocol)" -ForegroundColor Green

    # Allow VPN tunnel interface
    New-NetFirewallRule -DisplayName "KS - Allow VPN Tunnel" `
        -Direction Outbound -Action Allow `
        -InterfaceAlias $TapAdapterName -Profile Any -Enabled True | Out-Null
    Write-Host "[+] VPN tunnel interface allowed ($TapAdapterName)" -ForegroundColor Green

    # Allow loopback address functionality
    New-NetFirewallRule -DisplayName "KS - Allow Loopback" `
        -Direction Outbound -Action Allow `
        -RemoteAddress 127.0.0.1 -Profile Any -Enabled True | Out-Null
    Write-Host "[+] Loopback allowed" -ForegroundColor Green

    # Allow DNS
    New-NetFirewallRule -DisplayName "KS - Allow DNS" `
        -Direction Outbound -Action Allow `
        -Protocol UDP -RemotePort 53 -Profile Any -Enabled True | Out-Null
    Write-Host "[+] DNS allowed" -ForegroundColor Green

    # Block all other outbound unless specified.
    Set-NetFirewallProfile -Profile Domain,Public,Private -DefaultOutboundAction Block
    Write-Host "[+] Default outbound policy set to BLOCK" -ForegroundColor Green

    Write-Host "`n[OK] Kill switch ENABLED. Internet will be blocked if VPN drops.`n" -ForegroundColor Cyan
    Show-Status
}

function Disable-KillSwitch {
    Write-Host "`n[*] Disabling VPN Kill Switch..." -ForegroundColor Cyan

    # Restore the default outbound policy first
    Set-NetFirewallProfile -Profile Domain,Public,Private -DefaultOutboundAction Allow
    Write-Host "[+] Default outbound policy restored to ALLOW" -ForegroundColor Green

    # Remove all existing killswitch rules
    $rules = Get-NetFirewallRule | Where-Object { $_.DisplayName -like "KS -*" }
    if ($rules) {
        $rules | Remove-NetFirewallRule
        Write-Host "[+] All killswitch firewall rules removed" -ForegroundColor Green
    } else {
        Write-Host "[!] No killswitch rules found to remove" -ForegroundColor Yellow
    }

    Write-Host "`n[OK] Kill switch DISABLED. Normal network access restored.`n" -ForegroundColor Cyan
    Show-Status
}

function Show-Status {
    Write-Host "--- Current Status ---" -ForegroundColor White
    $profile = Get-NetFirewallProfile | Select-Object Name, DefaultOutboundAction
    $profile | Format-Table -AutoSize

    $ksRules = Get-NetFirewallRule | Where-Object { $_.DisplayName -like "KS -*" } | 
               Select-Object DisplayName, Enabled, Action
    if ($ksRules) {
        Write-Host "Active killswitch Rules:" -ForegroundColor White
        $ksRules | Format-Table -AutoSize
    } else {
        Write-Host "No killswitch rules active." -ForegroundColor Yellow
    }
}

# Run
switch ($Action) {
    "Enable"  { Enable-KillSwitch }
    "Disable" { Disable-KillSwitch }
}
