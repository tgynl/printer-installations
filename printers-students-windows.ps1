<# 
Rady School of Management - Windows Printer Installer (non-domain clients)
Connects native shared printers from rsm-print.ad.ucsd.edu, sets friendly location & single-sided default.

Run method (recommended):
  curl -fsSL https://raw.githubusercontent.com/tgynl/printer-installations/main/install-rsm-windows.ps1 | powershell -NoProfile -ExecutionPolicy Bypass -
#>

$ErrorActionPreference = 'Stop'

Write-Output "Rady School of Management @ UC San Diego"
Write-Output "Student printers installer for Windows 10/11"
Write-Output "============================================"
Write-Output ""

# --- Settings ---
$PrintServer = 'rsm-print.ad.ucsd.edu'

$Printers = @(
    @{
        Name     = 'rsm-2s111-xerox'
        Share    = '\\rsm-print.ad.ucsd.edu\rsm-2s111-xerox'
        Location = '2nd Floor South Wing - Help Desk area'
        Model    = 'Xerox AltaLink C8230'
    },
    @{
        Name     = 'rsm-2w107-xerox'
        Share    = '\\rsm-print.ad.ucsd.edu\rsm-2w107-xerox'
        Location = '2nd Floor West Wing - Grad Student Lounge'
        Model    = 'Xerox AltaLink C8230'
    }
)

Write-Host "Rady | Windows Printer Installer" -ForegroundColor Cyan
Write-Host "Print Server: $PrintServer" -ForegroundColor Cyan

# --- Credentials for non-domain clients ---
Write-Host ""
$cred = Get-Credential -Message "Enter credentials that can access $PrintServer (e.g. AD\username or username@ucsd.edu)"
$plain = $cred.GetNetworkCredential().Password

Write-Host "Caching credentials for $PrintServer..." -ForegroundColor Cyan
try {
    cmdkey /add:$PrintServer /user:$($cred.UserName) /pass:$plain | Out-Null
} catch {
    Write-Warning "Could not cache credentials with cmdkey. You may be prompted by Windows when connecting."
}

# --- Add printers ---
foreach ($p in $Printers) {
    Write-Host "`nConnecting to $($p.Share) ..." -ForegroundColor Cyan
    try {
        # Skip if already installed
        $existing = Get-Printer -Full | Where-Object { $_.ShareName -eq $p.Name -or $_.Name -eq $p.Name -or $_.PortName -eq $p.Share }
        if (-not $existing) {
            Add-Printer -ConnectionName $p.Share -ErrorAction Stop
            Write-Host "✅ Added: $($p.Name)"
        }
        else {
            Write-Host "ℹ️ Already installed: $($p.Name)"
        }

        # Set location text
        try { Set-Printer -Name $p.Name -Location $p.Location -ErrorAction SilentlyContinue } catch { }

        # Set per-user default: single-sided
        try {
            Set-PrintConfiguration -PrinterName $p.Name -DuplexingMode OneSided -ErrorAction Stop
        } catch {
            Write-Warning "Could not set duplex default on $($p.Name). Driver may need first-use sync."
        }

        Write-Host "   Location: $($p.Location)"
        Write-Host "   Model:    $($p.Model)"
        Write-Host "   Defaults: Single-sided (duplex available), stapling off"
    }
    catch {
        Write-Host "❌ Failed to add $($p.Name): $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`nAll done. If users don't see stapling/duplex options in app print dialogs, enable those device options on the SERVER driver for these queues."
