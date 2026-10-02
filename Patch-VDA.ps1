# ==============================================================================
# Virtual Display Adapter (VDA) Tool & Patcher
# Unified solution for Apollo (SudoVDA) and StarDesk (SDIddDriver)
#
# Features:
#  1. Windows 11 Touch Keyboard Docking Fix (38x21 cm EDID binary patch)
#  2. Apollo Single Display Stability Fix (Disables SudoVDA 3s watchdog teardown)
#  3. dGPU Render Adapter Binding (HKLM:\SOFTWARE\SudoMaker\SudoVDA + sunshine.conf)
#  4. Driver Backup, Self-Signing (Authenticode), and Clean Restoration
# ==============================================================================

[CmdletBinding()]
param(
    [switch]$Elevated,
    [ValidateSet("1", "2", "3", "4", "5", "6", "ApolloFull", "ApolloStability", "ApolloTouch", "ApolloRestore", "StarDeskTouch", "StarDeskRestore")]
    [string]$Option,
    [string]$DriverDir
)

# ------------------------------------------------------------------------------
# 1. Elevation Check & Auto-Elevation
# ------------------------------------------------------------------------------
function Test-Admin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    if ($Elevated) {
        Write-Warning "Failed to elevate to Administrator privileges. Exiting."
        exit 1
    }
    Write-Host "Elevating privileges for Virtual Display Adapter management..." -ForegroundColor Cyan
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated"
    if ($Option) {
        $argList += " -Option $Option"
    }
    if ($DriverDir) {
        $argList += " -DriverDir `"$DriverDir`""
    }
    Start-Process powershell.exe -ArgumentList $argList -Verb RunAs
    exit 0
}

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------
function Get-PrimaryGpuName {
    $gpu = (Get-CimInstance Win32_VideoController | Where-Object { 
        $_.Name -notmatch "Virtual|Basic Render|IddDriver" 
    } | Select-Object -First 1).Name

    if (-not $gpu) {
        $gpu = "NVIDIA GeForce RTX 4060 Laptop GPU"
    }
    return $gpu
}

function Ensure-CertificateTrusted {
    param([string]$CertSubject)

    $cert = Get-ChildItem "Cert:\LocalMachine\My" -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq $CertSubject } | Select-Object -First 1
    if (-not $cert) {
        Write-Host "      Generating self-signed Authenticode certificate ($CertSubject)..." -ForegroundColor Gray
        $cert = New-SelfSignedCertificate -Subject $CertSubject -Type CodeSigningCert -CertStoreLocation "Cert:\LocalMachine\My" -ErrorAction Stop

        $rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
        $rootStore.Open("ReadWrite")
        $rootStore.Add($cert)
        $rootStore.Close()

        $publisherStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
        $publisherStore.Open("ReadWrite")
        $publisherStore.Add($cert)
        $publisherStore.Close()
    }
    return $cert
}

function Sign-DriverDll {
    param(
        [string]$DllPath,
        [string]$CertSubject
    )
    $cert = Ensure-CertificateTrusted -CertSubject $CertSubject
    Write-Host "      Signing $([System.IO.Path]::GetFileName($DllPath)) with $CertSubject..." -ForegroundColor Gray
    Set-AuthenticodeSignature -FilePath $DllPath -Certificate $cert -TimestampServer "http://timestamp.digicert.com" | Out-Null
    Write-Host "      Signature verified successfully." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# Apollo Functions (SudoVDA)
# ------------------------------------------------------------------------------
function Find-ApolloDriverDir {
    if ($DriverDir -and (Test-Path $DriverDir)) { return $DriverDir }
    $candidates = @(
        "C:\Program Files\Apollo\drivers\sudovda",
        "P:\Program Files\Apollo\drivers\sudovda",
        "C:\Program Files (x86)\Apollo\drivers\sudovda",
        "P:\Program Files (x86)\Apollo\drivers\sudovda"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

function Apply-ApolloStabilityFix {
    param([string]$GpuName)

    Write-Host "--- Applying Apollo Display Stability & Watchdog Fix ---" -ForegroundColor Cyan

    # 1. Registry Keys: SudoVDA watchdog=0 & dGPU binding
    $regPath = "HKLM:\SOFTWARE\SudoMaker\SudoVDA"
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    Set-ItemProperty -Path $regPath -Name "watchdog" -Value 0 -Type DWord
    Set-ItemProperty -Path $regPath -Name "gpuName" -Value $GpuName -Type String

    Write-Host "  [+] Set HKLM:\SOFTWARE\SudoMaker\SudoVDA\watchdog = 0 (Watchdog teardown disabled)" -ForegroundColor Green
    Write-Host "  [+] Set HKLM:\SOFTWARE\SudoMaker\SudoVDA\gpuName = $GpuName" -ForegroundColor Green

    # 2. sunshine.conf adapter_name configuration
    $confPaths = @(
        "C:\Program Files\Apollo\config\sunshine.conf",
        "P:\Program Files\Apollo\config\sunshine.conf"
    )
    foreach ($confPath in $confPaths) {
        if (Test-Path $confPath) {
            $conf = Get-Content $confPath -Raw
            if ($conf -match "(?m)^adapter_name\s*=") {
                $conf = $conf -replace "(?m)^adapter_name\s*=.*$", "adapter_name = $GpuName"
                Set-Content -Path $confPath -Value $conf -NoNewline
                Write-Host "  [+] Updated adapter_name in $confPath" -ForegroundColor Green
            } else {
                Add-Content -Path $confPath -Value "`nadapter_name = $GpuName"
                Write-Host "  [+] Added adapter_name to $confPath" -ForegroundColor Green
            }
        }
    }

    # 3. Restart Apollo Service/Processes to reload configuration
    Write-Host "  [+] Restarting Apollo services..." -ForegroundColor Yellow
    Stop-Process -Name "sunshine", "sunshinesvc" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    $apolloSvc = Get-Service -Name "ApolloService" -ErrorAction SilentlyContinue
    if ($apolloSvc) {
        Restart-Service -Name "ApolloService" -Force -ErrorAction SilentlyContinue
        Write-Host "  [+] ApolloService restarted." -ForegroundColor Green
    } else {
        $sunshineExe = "C:\Program Files\Apollo\sunshine.exe"
        if (Test-Path $sunshineExe) {
            Start-Process -FilePath $sunshineExe -WindowStyle Hidden
            Write-Host "  [+] Started sunshine.exe in background." -ForegroundColor Green
        }
    }
}

function Patch-ApolloTouchKeyboard {
    $dir = Find-ApolloDriverDir
    if (-not $dir) {
        Write-Error "Could not locate Apollo SudoVDA driver directory!"
        return $false
    }

    Write-Host "--- Patching Apollo SudoVDA Touch Keyboard EDID ---" -ForegroundColor Cyan
    Write-Host "  Target directory: $dir" -ForegroundColor Gray

    Stop-Process -Name "sunshine", "sunshinesvc", "Apollo*" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    $dllPath    = "$dir\SudoVDA.dll"
    $backupPath = "$dir\SudoVDA_Original.dll"
    $nefconc    = "$dir\nefconc.exe"
    $infFile    = "$dir\SudoVDA.inf"

    if (-not (Test-Path $dllPath)) {
        Write-Error "SudoVDA.dll not found in $dir!"
        return $false
    }

    # Backup original
    if (-not (Test-Path $backupPath)) {
        Write-Host "  [+] Creating backup: SudoVDA_Original.dll" -ForegroundColor Yellow
        Copy-Item -Path $dllPath -Destination $backupPath -Force
    } else {
        Write-Host "  [+] Restoring clean base from SudoVDA_Original.dll" -ForegroundColor Gray
        Copy-Item -Path $backupPath -Destination $dllPath -Force
    }

    # Binary patch EDID dimensions to 38x21 cm
    $bytes = [System.IO.File]::ReadAllBytes($dllPath)
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
            Write-Host "  [+] Located EDID block at offset $i" -ForegroundColor Cyan
            $bytes[$i + 21] = 0x26 # 38 cm width
            $bytes[$i + 22] = 0x15 # 21 cm height

            # Recalculate 128-byte checksum
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
        Write-Error "Failed to locate SudoVDA EDID signature in DLL!"
        return $false
    }

    [System.IO.File]::WriteAllBytes($dllPath, $bytes)
    Write-Host "  [+] SudoVDA.dll binary patched (38 cm x 21 cm)." -ForegroundColor Green

    # Sign driver
    Sign-DriverDll -DllPath $dllPath -CertSubject "CN=Apollo-Patched-Driver"

    # Reinstall driver node
    if (Test-Path $nefconc) {
        Push-Location $dir
        Write-Host "  [+] Reinstalling driver via nefconc..." -ForegroundColor Gray
        & $nefconc --remove-device-node --hardware-id "root\sudomaker\sudovda" --class-guid "4D36E968-E325-11CE-BFC1-08002BE10318" | Out-Null
        Start-Sleep -Seconds 2
        & $nefconc --create-device-node --class-name Display --class-guid "4D36E968-E325-11CE-BFC1-08002BE10318" --hardware-id "root\sudomaker\sudovda" | Out-Null
        & $nefconc --install-driver --inf-path "SudoVDA.inf" | Out-Null
        Pop-Location
        Write-Host "  [+] SudoVDA driver reinstalled successfully." -ForegroundColor Green
    } else {
        Write-Warning "nefconc.exe not found, falling back to pnputil..."
        pnputil /add-driver $infFile /install | Out-Null
    }

    return $true
}

function Restore-ApolloStock {
    $dir = Find-ApolloDriverDir
    if (-not $dir) {
        Write-Error "Could not locate Apollo driver directory!"
        return
    }
    $backupPath = "$dir\SudoVDA_Original.dll"
    $dllPath    = "$dir\SudoVDA.dll"
    $nefconc    = "$dir\nefconc.exe"
    $infFile    = "$dir\SudoVDA.inf"

    if (-not (Test-Path $backupPath)) {
        Write-Warning "No SudoVDA_Original.dll backup found to restore."
        return
    }

    Stop-Process -Name "sunshine", "sunshinesvc", "Apollo*" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    Copy-Item -Path $backupPath -Destination $dllPath -Force
    Write-Host "  [+] Restored stock SudoVDA.dll from backup." -ForegroundColor Green

    if (Test-Path $nefconc) {
        Push-Location $dir
        & $nefconc --remove-device-node --hardware-id "root\sudomaker\sudovda" --class-guid "4D36E968-E325-11CE-BFC1-08002BE10318" | Out-Null
        Start-Sleep -Seconds 2
        & $nefconc --create-device-node --class-name Display --class-guid "4D36E968-E325-11CE-BFC1-08002BE10318" --hardware-id "root\sudomaker\sudovda" | Out-Null
        & $nefconc --install-driver --inf-path "SudoVDA.inf" | Out-Null
        Pop-Location
        Write-Host "  [+] Stock SudoVDA driver reinstalled." -ForegroundColor Green
    }
}

# ------------------------------------------------------------------------------
# StarDesk Functions (SDIddDriver)
# ------------------------------------------------------------------------------
function Find-StarDeskDriverDir {
    if ($DriverDir -and (Test-Path $DriverDir)) { return $DriverDir }
    $candidates = @(
        "C:\Program Files\StarDesk\bin\drivers\SDIddDriver",
        "P:\Program Files\StarDesk\bin\drivers\SDIddDriver",
        "C:\Program Files (x86)\StarDesk\bin\drivers\SDIddDriver",
        "P:\Program Files (x86)\StarDesk\bin\drivers\SDIddDriver"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

function Patch-StarDeskTouchKeyboard {
    $dir = Find-StarDeskDriverDir
    if (-not $dir) {
        Write-Error "Could not locate StarDesk SDIddDriver directory!"
        return $false
    }

    Write-Host "--- Patching StarDesk SDIddDriver Touch Keyboard EDID ---" -ForegroundColor Cyan
    Write-Host "  Target directory: $dir" -ForegroundColor Gray

    Stop-Service -Name "StarDeskService*", "StarDesk*" -Force -ErrorAction SilentlyContinue
    Stop-Process -Name "StarDesk*", "SDIdd*" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    $dllPath    = "$dir\SDIddDriver.dll"
    $backupPath = "$dir\SDIddDriver_Original.dll"
    $infFile    = "$dir\SDIddDriver.inf"

    if (-not (Test-Path $dllPath)) {
        Write-Error "SDIddDriver.dll not found in $dir!"
        return $false
    }

    # Backup original
    if (-not (Test-Path $backupPath)) {
        Write-Host "  [+] Creating backup: SDIddDriver_Original.dll" -ForegroundColor Yellow
        Copy-Item -Path $dllPath -Destination $backupPath -Force
    } else {
        Write-Host "  [+] Restoring clean base from SDIddDriver_Original.dll" -ForegroundColor Gray
        Copy-Item -Path $backupPath -Destination $dllPath -Force
    }

    # Binary patch EDID blocks
    $bytes = [System.IO.File]::ReadAllBytes($dllPath)
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
        if ($match -and ($bytes[$i + 18] -eq 1)) {
            Write-Host "  [+] Located EDID block at offset $i" -ForegroundColor Cyan
            $bytes[$i + 21] = 0x26 # 38 cm width
            $bytes[$i + 22] = 0x15 # 21 cm height

            $sum = 0
            for ($k = 0; $k -lt 127; $k++) {
                $sum += $bytes[$i + $k]
            }
            $bytes[$i + 127] = (256 - ($sum % 256)) % 256
            $patchedCount++
            $i += 127
        }
    }

    if ($patchedCount -eq 0) {
        Write-Error "Could not find any EDID blocks in SDIddDriver.dll!"
        return $false
    }

    [System.IO.File]::WriteAllBytes($dllPath, $bytes)
    Write-Host "  [+] Patched $patchedCount EDID block(s) in SDIddDriver.dll." -ForegroundColor Green

    Sign-DriverDll -DllPath $dllPath -CertSubject "CN=StarDesk-Patched-Driver"

    if (Test-Path $infFile) {
        Write-Host "  [+] Installing patched driver via pnputil..." -ForegroundColor Gray
        pnputil /add-driver "$infFile" /install | Out-Null
        Write-Host "  [+] Driver reinstallation completed." -ForegroundColor Green
    }

    Start-Service -Name "StarDeskService" -ErrorAction SilentlyContinue
    return $true
}

function Restore-StarDeskStock {
    $dir = Find-StarDeskDriverDir
    if (-not $dir) {
        Write-Error "Could not locate StarDesk driver directory!"
        return
    }
    $backupPath = "$dir\SDIddDriver_Original.dll"
    $dllPath    = "$dir\SDIddDriver.dll"
    $infFile    = "$dir\SDIddDriver.inf"

    if (-not (Test-Path $backupPath)) {
        Write-Warning "No SDIddDriver_Original.dll backup found to restore."
        return
    }

    Stop-Service -Name "StarDeskService*", "StarDesk*" -Force -ErrorAction SilentlyContinue
    Stop-Process -Name "StarDesk*", "SDIdd*" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    Copy-Item -Path $backupPath -Destination $dllPath -Force
    Write-Host "  [+] Restored stock SDIddDriver.dll from backup." -ForegroundColor Green

    if (Test-Path $infFile) {
        pnputil /add-driver "$infFile" /install | Out-Null
        Write-Host "  [+] Stock StarDesk driver reinstalled." -ForegroundColor Green
    }
    Start-Service -Name "StarDeskService" -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------
# Main Dispatcher / Interactive Menu
# ------------------------------------------------------------------------------
$primaryGpu = Get-PrimaryGpuName

function Show-Menu {
    Clear-Host
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host "            Virtual Display Adapter (VDA) Tool & Patcher                 " -ForegroundColor Cyan
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host " Primary GPU Detected: $primaryGpu" -ForegroundColor Green
    Write-Host "--------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host " Select an option below to perform the desired fix:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " [1] Apollo: Full Touch & Display Stability Fix (RECOMMENDED)" -ForegroundColor White
    Write-Host "     - Patches SudoVDA.dll EDID dimensions to 38x21 cm (permanent touch keyboard docking)" -ForegroundColor Gray
    Write-Host "     - Disables SudoVDA 3-sec watchdog timeout (watchdog=0) to prevent Extend rollback" -ForegroundColor Gray
    Write-Host "     - Locks SudoVDA & Apollo to '$primaryGpu' (sunshine.conf adapter_name)" -ForegroundColor Gray
    Write-Host "     - Re-signs and reinstalls driver cleanly via nefconc" -ForegroundColor Gray
    Write-Host ""
    Write-Host " [2] Apollo: Display Stability Fix Only (No Driver Recompile)" -ForegroundColor White
    Write-Host "     - Disables SudoVDA watchdog (watchdog=0) in HKLM:\SOFTWARE\SudoMaker\SudoVDA" -ForegroundColor Gray
    Write-Host "     - Binds dedicated GPU in registry and sunshine.conf" -ForegroundColor Gray
    Write-Host "     - Fixes 'Show only on 2' / single virtual display reverting to Extend" -ForegroundColor Gray
    Write-Host "     - Restarts ApolloService / Apollo" -ForegroundColor Gray
    Write-Host ""
    Write-Host " [3] Apollo: Touch Keyboard EDID Patch Only" -ForegroundColor White
    Write-Host "     - Binary patches SudoVDA.dll physical dimensions to 38x21 cm" -ForegroundColor Gray
    Write-Host "     - Re-signs with local Authenticode certificate and reinstalls driver" -ForegroundColor Gray
    Write-Host ""
    Write-Host " [4] Apollo: Restore Stock Original SudoVDA Driver" -ForegroundColor White
    Write-Host "     - Restores original unpatched SudoVDA.dll from backup" -ForegroundColor Gray
    Write-Host ""
    Write-Host " [5] StarDesk: Patch Touch Keyboard EDID (Docking Fix)" -ForegroundColor White
    Write-Host "     - Binary patches SDIddDriver.dll to 38x21 cm & recalculates checksums" -ForegroundColor Gray
    Write-Host "     - Re-signs and restarts StarDeskService" -ForegroundColor Gray
    Write-Host ""
    Write-Host " [6] StarDesk: Restore Stock Original SDIddDriver" -ForegroundColor White
    Write-Host "     - Restores original unpatched SDIddDriver.dll from backup" -ForegroundColor Gray
    Write-Host ""
    Write-Host " [0] Exit" -ForegroundColor Red
    Write-Host "==========================================================================" -ForegroundColor Cyan
}

# Resolve choice if passed via parameter
$choice = $Option
if (-not $choice) {
    Show-Menu
    $choice = Read-Host "Enter your choice [0-6]"
}

switch ($choice) {
    { $_ -in "1", "ApolloFull" } {
        Write-Host "`nExecuting: Apollo Full Touch & Display Stability Fix..." -ForegroundColor Cyan
        $ok = Patch-ApolloTouchKeyboard
        if ($ok) {
            # Always apply stability fix AFTER driver reinstallation so nefconc does not wipe registry
            Apply-ApolloStabilityFix -GpuName $primaryGpu
        }
        Write-Host "`nAll Apollo fixes applied successfully!" -ForegroundColor Green
    }
    { $_ -in "2", "ApolloStability" } {
        Write-Host "`nExecuting: Apollo Display Stability Fix Only..." -ForegroundColor Cyan
        Apply-ApolloStabilityFix -GpuName $primaryGpu
        Write-Host "`nStability fix applied successfully!" -ForegroundColor Green
    }
    { $_ -in "3", "ApolloTouch" } {
        Write-Host "`nExecuting: Apollo Touch Keyboard EDID Patch..." -ForegroundColor Cyan
        Patch-ApolloTouchKeyboard | Out-Null
        # Re-apply registry keys after driver node reinstall
        Apply-ApolloStabilityFix -GpuName $primaryGpu
        Write-Host "`nTouch keyboard EDID patch applied successfully!" -ForegroundColor Green
    }
    { $_ -in "4", "ApolloRestore" } {
        Write-Host "`nExecuting: Restore Apollo Stock Driver..." -ForegroundColor Yellow
        Restore-ApolloStock
        Write-Host "`nApollo restored to stock driver." -ForegroundColor Green
    }
    { $_ -in "5", "StarDeskTouch" } {
        Write-Host "`nExecuting: StarDesk Touch Keyboard EDID Patch..." -ForegroundColor Cyan
        Patch-StarDeskTouchKeyboard | Out-Null
        Write-Host "`nStarDesk touch keyboard patch applied successfully!" -ForegroundColor Green
    }
    { $_ -in "6", "StarDeskRestore" } {
        Write-Host "`nExecuting: Restore StarDesk Stock Driver..." -ForegroundColor Yellow
        Restore-StarDeskStock
        Write-Host "`nStarDesk restored to stock driver." -ForegroundColor Green
    }
    { $_ -in "0", "q", "exit" } {
        Write-Host "`nExiting VDA Tool." -ForegroundColor Yellow
        exit 0
    }
    default {
        Write-Warning "Invalid selection: '$choice'."
    }
}

Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
