# Virtual Display Adapter (VDA) Tool & Patcher

Automated binary patcher and configuration utility for Windows Virtual Display Drivers (**Apollo / SudoVDA** and **StarDesk / SDIddDriver**).

---

## What This Fixes

### 1. Windows 11 Touch Keyboard Undocking / Floating Bug
On Windows 11, the virtual touch keyboard will refuse to stay docked and forcibly switch into floating / mini / split mode if the display's physical dimensions in EDID are too large (e.g. `70 cm x 39 cm` or `0 cm x 0 cm`).
- Standard registry `EDID_OVERRIDE` hacks fail because virtual display drivers dynamically inject their own hardcoded EDID firmware blocks on connection.
- This patcher directly modifies the driver's binary EDID to report **38 cm x 21 cm** (`0x26` x `0x15`), permanently docking the Windows 11 Touch Keyboard.

### 2. Apollo Single Display Rollback to Extend
When switching Windows display settings to "Show only on 2" (disabling the host physical monitor and streaming exclusively to the virtual display), the stream would glitch and revert back to "Extend" mode.
- **Root Cause:** SudoVDA has a default 3-second watchdog timer. During display re-enumeration, brief DXGI frame submission stalls cause SudoVDA to tear down the virtual display. With 0 active displays left, Windows emergency-recovers the physical panel and defaults the topology to Extend.
- **Fix:** Sets `watchdog = 0` in `HKLM:\SOFTWARE\SudoMaker\SudoVDA` (disables driver teardown timeout), binds SudoVDA to the detected primary dGPU (`gpuName`), and pins `adapter_name` in `sunshine.conf`.

### 3. Native Driver Signing (No Test-Signing Watermark Required)
Because these are User-Mode Driver Framework (UMDF) drivers, they do not require Microsoft Hardware Dev Center EV certification. The patcher automatically:
- Generates a local Authenticode Code-Signing certificate.
- Installs the certificate into `LocalMachine\Root` and `LocalMachine\TrustedPublisher`.
- Signs the patched `.dll`.
- **Result:** Windows loads the driver without enabling Test-Signing mode (no desktop watermark, no anti-cheat conflicts).

---

## Repository Structure

```text
vda-touch-fix/
├── Patch-VDA.ps1         # Unified interactive patcher & stability tool
├── README.md             # Documentation & Guide
└── .gitignore            # Git ignore rules for backups & temporary files
```

---

## How to Run

1. Right-click [`Patch-VDA.ps1`](Patch-VDA.ps1) and select **"Run with PowerShell"**.
2. Accept the **UAC Administrator prompt**.
3. Select an option from the interactive menu:

```text
==========================================================================
            Virtual Display Adapter (VDA) Tool & Patcher                 
==========================================================================
 Primary GPU Detected: NVIDIA GeForce RTX 4060 Laptop GPU
--------------------------------------------------------------------------
 Select an option below to perform the desired fix:

 [1] Apollo: Full Touch & Display Stability Fix (RECOMMENDED)
     - Patches SudoVDA.dll EDID dimensions to 38x21 cm (permanent touch keyboard docking)
     - Disables SudoVDA 3-sec watchdog timeout (watchdog=0) to prevent Extend rollback
     - Locks SudoVDA & Apollo to primary dGPU (sunshine.conf adapter_name)
     - Re-signs and reinstalls driver cleanly via nefconc

 [2] Apollo: Display Stability Fix Only (No Driver Recompile)
     - Disables SudoVDA watchdog (watchdog=0) in HKLM:\SOFTWARE\SudoMaker\SudoVDA
     - Binds dedicated GPU in registry and sunshine.conf
     - Fixes 'Show only on 2' / single virtual display reverting to Extend
     - Restarts ApolloService / Apollo

 [3] Apollo: Touch Keyboard EDID Patch Only
     - Binary patches SudoVDA.dll physical dimensions to 38x21 cm
     - Re-signs with local Authenticode certificate and reinstalls driver

 [4] Apollo: Restore Stock Original SudoVDA Driver
     - Restores original unpatched SudoVDA.dll from backup

 [5] StarDesk: Patch Touch Keyboard EDID (Docking Fix)
     - Binary patches SDIddDriver.dll to 38x21 cm & recalculates checksums
     - Re-signs and restarts StarDeskService

 [6] StarDesk: Restore Stock Original SDIddDriver
     - Restores original unpatched SDIddDriver.dll from backup

 [0] Exit
==========================================================================
```

### Non-Interactive / CLI Usage

You can also run the script directly with options:
```powershell
# Run Apollo full fix
.\Patch-VDA.ps1 -Option 1

# Run Apollo display stability fix only
.\Patch-VDA.ps1 -Option 2

# Restore Apollo stock driver
.\Patch-VDA.ps1 -Option 4

# Run StarDesk touch patch
.\Patch-VDA.ps1 -Option 5
```

---

## Reverting to Stock Drivers

The script automatically creates `_Original.dll` backups prior to patching:
- Select **Option 4** to restore the Apollo stock driver.
- Select **Option 6** to restore the StarDesk stock driver.
