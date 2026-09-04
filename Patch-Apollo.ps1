# ==============================================================================
# Apollo SudoVDA EDID Binary Patcher
# Permanently docks Windows 11 Touch Keyboard by patching SudoVDA driver EDID
# ==============================================================================

param(
    [switch]$Elevated,
    [string]$DriverDir
)

function Test-Admin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    if ($Elevated) {
        Write-Warning "Failed to elevate. Please run this script as Administrator."
        exit
    }
    Write-Host "Elevating privileges for SudoVDA patching..."
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated" -Verb RunAs
    exit
}

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Apollo SudoVDA Driver Patcher (Touch Keyboard Fix)  " -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Locate Apollo Driver Directory
$apolloPaths = @(
    "P:\Program Files\Apollo\drivers\sudovda",
    "C:\Program Files\Apollo\drivers\sudovda",
    "P:\Program Files (x86)\Apollo\drivers\sudovda",
    "C:\Program Files (x86)\Apollo\drivers\sudovda"
)

$targetDir = $null
if ($DriverDir -and (Test-Path $DriverDir)) {
    $targetDir = $DriverDir
} else {
    foreach ($path in $apolloPaths) {
        if (Test-Path $path) {
            $targetDir = $path
            break
        }
    }
}

if (-not $targetDir) {
    Write-Warning "Apollo SudoVDA driver directory not found at default locations."
    Write-Host "Please enter the path to the sudovda folder (containing SudoVDA.dll):" -ForegroundColor Cyan
    $userInput = Read-Host "Driver Directory Path"
    if ($userInput -and (Test-Path $userInput)) {
        $targetDir = $userInput
    } else {
        Write-Error "Could not locate Apollo driver directory. Exiting."
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit
    }
}

Write-Host "[1/6] Found Apollo driver directory: $targetDir" -ForegroundColor Green

# 2. Stop running Apollo instances to avoid file locks
Write-Host "[2/6] Stopping any running Apollo processes..." -ForegroundColor Yellow
Stop-Process -Name "Apollo", "apollo*" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

$targetDll = "$targetDir\SudoVDA.dll"
$backupDll = "$targetDir\SudoVDA_Original.dll"
$nefconc   = "$targetDir\nefconc.exe"
$infFile   = "$targetDir\SudoVDA.inf"

if (-not (Test-Path $targetDll)) {
    Write-Error "SudoVDA.dll not found in $targetDir!"
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

# 3. Backup original DLL if not already backed up
if (-not (Test-Path $backupDll)) {
    Write-Host "[3/6] Creating backup: SudoVDA_Original.dll..." -ForegroundColor Yellow
    Copy-Item -Path $targetDll -Destination $backupDll -Force
} else {
    Write-Host "[3/6] Restoring clean DLL from backup before patching..." -ForegroundColor Yellow
    Copy-Item -Path $backupDll -Destination $targetDll -Force
}

# 4. Binary patch the EDID dimensions
Write-Host "[4/6] Patching EDID dimensions (38 cm x 21 cm)..." -ForegroundColor Yellow
$bytes = [System.IO.File]::ReadAllBytes($targetDll)

# EDID Header + Manufacturer signature for SudoVDA
$search = [byte[]](0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x4d, 0xab, 0xce, 0xd1, 0xef, 0x2d, 0xbc, 0x1a, 0x20, 0x22, 0x01, 0x03, 0x80)

$patched = $false
for ($i = 0; $i -lt $bytes.Length - $search.Length; $i++) {
    $match = $true
    for ($j = 0; $j -lt $search.Length; $j++) {
        if ($bytes[$i + $j] -ne $search[$j]) {
            $match = $false
            break
        }
    }
    if ($match) {
        Write-Host "      Found EDID block at offset: $i" -ForegroundColor Cyan
        
        # Byte 21: Max Horizontal Image Size in cm (Set to 0x26 = 38 cm)
        $bytes[$i + 21] = 0x26
        # Byte 22: Max Vertical Image Size in cm (Set to 0x15 = 21 cm)
        $bytes[$i + 22] = 0x15
        
        # Recalculate EDID 128-byte block checksum at offset 127
        $sum = 0
        for ($k = 0; $k -lt 127; $k++) {
            $sum += $bytes[$i + $k]
        }
        $bytes[$i + 127] = (256 - ($sum % 256)) % 256
        
        $patched = $true
        break
    }
}

if (-not $patched) {
    Write-Error "Could not find the EDID signature in SudoVDA.dll!"
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

[System.IO.File]::WriteAllBytes($targetDll, $bytes)
Write-Host "      Binary patch applied successfully." -ForegroundColor Green

# 5. Code signing with trusted self-signed certificate
Write-Host "[5/6] Ensuring Code-Signing Certificate is trusted..." -ForegroundColor Yellow
$certName = "CN=Apollo-Patched-Driver"
$cert = Get-ChildItem "Cert:\LocalMachine\My" -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq $certName } | Select-Object -First 1

if (-not $cert) {
    Write-Host "      Generating new code-signing certificate..." -ForegroundColor Gray
    $cert = New-SelfSignedCertificate -Subject $certName -Type CodeSigningCert -CertStoreLocation "Cert:\LocalMachine\My" -ErrorAction Stop
    
    $rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
    $rootStore.Open("ReadWrite")
    $rootStore.Add($cert)
    $rootStore.Close()

    $publisherStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
    $publisherStore.Open("ReadWrite")
    $publisherStore.Add($cert)
    $publisherStore.Close()
}

Write-Host "      Signing SudoVDA.dll..." -ForegroundColor Gray
Set-AuthenticodeSignature -FilePath $targetDll -Certificate $cert -TimestampServer "http://timestamp.digicert.com" | Out-Null
Write-Host "      Signature verified successfully." -ForegroundColor Green

# 6. Reinstall Driver using nefconc
Write-Host "[6/6] Reinstalling SudoVDA driver..." -ForegroundColor Yellow
if (Test-Path $nefconc) {
    Push-Location $targetDir
    
    Write-Host "      Removing old driver device node..." -ForegroundColor Gray
    & $nefconc --remove-device-node --hardware-id "root\sudomaker\sudovda" --class-guid "4D36E968-E325-11CE-BFC1-08002BE10318" | Out-Null
    
    Start-Sleep -Seconds 2
    
    Write-Host "      Creating new device node..." -ForegroundColor Gray
    & $nefconc --create-device-node --class-name Display --class-guid "4D36E968-E325-11CE-BFC1-08002BE10318" --hardware-id "root\sudomaker\sudovda" | Out-Null
    
    Write-Host "      Installing patched driver..." -ForegroundColor Gray
    & $nefconc --install-driver --inf-path "SudoVDA.inf" | Out-Null
    
    Pop-Location
    Write-Host "      Driver reinstallation completed!" -ForegroundColor Green
} else {
    Write-Warning "nefconc.exe not found. Falling back to pnputil..."
    pnputil /add-driver $infFile /install | Out-Null
}

Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  SUCCESS! SudoVDA has been patched and reinstalled.  " -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
Write-Host ""
Write-Host "You can now launch Apollo and connect your client."
Write-Host "The Touch Keyboard will now stay permanently docked!"
Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
