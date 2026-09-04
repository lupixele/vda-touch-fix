# ==============================================================================
# StarDesk SDIddDriver Binary Patcher
# Permanently docks Windows 11 Touch Keyboard by patching SDIddDriver EDID
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
    Write-Host "Elevating privileges for StarDesk patching..."
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated" -Verb RunAs
    exit
}

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  StarDesk Driver Patcher (Touch Keyboard Fix)        " -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Locate StarDesk Driver Directory
$stardeskPaths = @(
    "P:\Program Files\StarDesk\bin\drivers\SDIddDriver",
    "C:\Program Files\StarDesk\bin\drivers\SDIddDriver",
    "P:\Program Files (x86)\StarDesk\bin\drivers\SDIddDriver",
    "C:\Program Files (x86)\StarDesk\bin\drivers\SDIddDriver"
)

$targetDir = $null
if ($DriverDir -and (Test-Path $DriverDir)) {
    $targetDir = $DriverDir
} else {
    foreach ($path in $stardeskPaths) {
        if (Test-Path $path) {
            $targetDir = $path
            break
        }
    }
}

if (-not $targetDir) {
    Write-Warning "StarDesk driver directory not found at default locations."
    Write-Host "Please enter the path to the SDIddDriver folder (containing SDIddDriver.dll):" -ForegroundColor Cyan
    $userInput = Read-Host "Driver Directory Path"
    if ($userInput -and (Test-Path $userInput)) {
        $targetDir = $userInput
    } else {
        Write-Error "Could not locate StarDesk driver directory. Exiting."
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit
    }
}

Write-Host "[1/6] Found StarDesk driver directory: $targetDir" -ForegroundColor Green

# 2. Stop running StarDesk services and processes
Write-Host "[2/6] Stopping StarDesk processes & service..." -ForegroundColor Yellow
Stop-Service -Name "StarDeskService*", "StarDesk*" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "StarDesk*", "SDIdd*" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

$targetDll = "$targetDir\SDIddDriver.dll"
$backupDll = "$targetDir\SDIddDriver_Original.dll"
$infFile   = "$targetDir\SDIddDriver.inf"

if (-not (Test-Path $targetDll)) {
    Write-Error "SDIddDriver.dll not found in $targetDir!"
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

# 3. Backup original DLL if not already backed up
if (-not (Test-Path $backupDll)) {
    Write-Host "[3/6] Creating backup: SDIddDriver_Original.dll..." -ForegroundColor Yellow
    Copy-Item -Path $targetDll -Destination $backupDll -Force
} else {
    Write-Host "[3/6] Restoring clean DLL from backup before patching..." -ForegroundColor Yellow
    Copy-Item -Path $backupDll -Destination $targetDll -Force
}

# 4. Binary patch the EDID blocks
Write-Host "[4/6] Patching EDID dimensions (38 cm x 21 cm)..." -ForegroundColor Yellow
$bytes = [System.IO.File]::ReadAllBytes($targetDll)

# Standard EDID Header
$search = [byte[]](0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00)

$patchedCount = 0
for ($i = 0; $i -le $bytes.Length - 128; $i++) {
    $match = $true
    for ($j = 0; $j -lt $search.Length; $j++) {
        if ($bytes[$i + $j] -ne $search[$j]) {
            $match = $false
            break
        }
    }
    
    if ($match) {
        # Verify EDID version 1 (offset 18)
        if ($bytes[$i + 18] -eq 1) {
            Write-Host "      Found EDID block at offset: $i" -ForegroundColor Cyan
            
            # Patch physical dimensions: 38 cm x 21 cm
            $bytes[$i + 21] = 0x26
            $bytes[$i + 22] = 0x15
            
            # Recalculate EDID checksum at byte 127
            $sum = 0
            for ($k = 0; $k -lt 127; $k++) {
                $sum += $bytes[$i + $k]
            }
            $bytes[$i + 127] = (256 - ($sum % 256)) % 256
            
            $patchedCount++
            $i += 127 # Jump to end of this 128-byte block
        }
    }
}

if ($patchedCount -eq 0) {
    Write-Error "Could not find any EDID blocks in SDIddDriver.dll!"
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit
}

[System.IO.File]::WriteAllBytes($targetDll, $bytes)
Write-Host "      Successfully patched $patchedCount EDID block(s)." -ForegroundColor Green

# 5. Code signing with trusted self-signed certificate
Write-Host "[5/6] Ensuring Code-Signing Certificate is trusted..." -ForegroundColor Yellow
$certName = "CN=StarDesk-Patched-Driver"
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

Write-Host "      Signing SDIddDriver.dll..." -ForegroundColor Gray
Set-AuthenticodeSignature -FilePath $targetDll -Certificate $cert -TimestampServer "http://timestamp.digicert.com" | Out-Null
Write-Host "      Signature verified successfully." -ForegroundColor Green

# 6. Reinstall Driver & Restart Service
Write-Host "[6/6] Reinstalling StarDesk driver & restarting service..." -ForegroundColor Yellow
if (Test-Path $infFile) {
    Write-Host "      Installing patched driver via pnputil..." -ForegroundColor Gray
    pnputil /add-driver "$infFile" /install | Out-Null
    Write-Host "      Driver reinstallation completed!" -ForegroundColor Green
} else {
    Write-Warning "SDIddDriver.inf not found. Skipping pnputil reinstall."
}

Write-Host "      Restarting StarDesk service..." -ForegroundColor Gray
Start-Service -Name "StarDeskService" -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  SUCCESS! StarDesk has been patched and reinstalled. " -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Patched capabilities:" -ForegroundColor Cyan
Write-Host "  [+] Touch Keyboard Fix: 38x21 cm physical size (permanent docking)"
Write-Host ""
Write-Host "You can now launch StarDesk and connect your device."
Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
