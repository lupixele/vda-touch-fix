# Virtual Display Adapter Touch Keyboard Fix (`vda-touch-fix`)

This repository contains automated binary patchers for Windows Virtual Display Drivers (**Apollo / SudoVDA** and **StarDesk / SDIddDriver**).

---

## What This Fixes

### Windows 11 Touch Keyboard Undocking / Floating Bug
On Windows 11, the virtual touch keyboard will refuse to stay docked and forcibly switch into floating / mini / split mode if the display's physical dimensions in EDID are too large (e.g. `70 cm x 39 cm` or `0 cm x 0 cm`).
- Standard registry `EDID_OVERRIDE` hacks fail because virtual display drivers dynamically inject their own hardcoded EDID firmware blocks on connection.
- These patchers directly modify the driver's binary EDID to report **38 cm x 21 cm** (`0x26` x `0x15`), permanently docking the Windows 11 Touch Keyboard.

### Native Driver Signing (No Test-Signing Watermark Required)
Because these are User-Mode Driver Framework (UMDF) drivers, they do not require Microsoft Hardware Dev Center EV certification. The patchers automatically:
- Generate a local Authenticode Code-Signing certificate.
- Install the certificate into `LocalMachine\Root` and `LocalMachine\TrustedPublisher`.
- Sign the patched `.dll`.
- **Result:** Windows loads the driver without enabling Test-Signing mode (no desktop watermark, no anti-cheat issues).

---

## Repository Structure

```text
vda-touch-fix/
├── Patch-Apollo.ps1      # Patcher for Apollo (SudoVDA)
├── Patch-StarDesk.ps1    # Patcher for StarDesk (SDIddDriver)
├── README.md             # Documentation & Guide
└── .gitignore            # Git ignore rules for backups & temporary files
```

---

## How to Run

### Apollo (SudoVDA)
1. Close the Apollo application.
2. Right-click [`Patch-Apollo.ps1`](file:///p:/Projects/Debugging/vda-touch-fix/Patch-Apollo.ps1) and select **"Run with PowerShell"**.
3. Accept the **UAC Administrator prompt**.
4. The script will:
   - Back up `SudoVDA.dll` to `SudoVDA_Original.dll`.
   - Patch the physical dimensions to `38x21 cm`.
   - Re-sign `SudoVDA.dll`.
   - Reinstall the driver node via `nefconc.exe`.
5. Launch Apollo and reconnect your client.

---

### StarDesk (SDIddDriver)
1. Close StarDesk and ensure the StarDesk service is stopped.
2. Right-click [`Patch-StarDesk.ps1`](file:///p:/Projects/Debugging/vda-touch-fix/Patch-StarDesk.ps1) and select **"Run with PowerShell"**.
3. Accept the **UAC Administrator prompt**.
4. The script will:
   - Back up `SDIddDriver.dll` to `SDIddDriver_Original.dll`.
   - Patch physical dimensions to `38x21 cm`.
   - Recompute the EDID 128-byte block checksums.
   - Sign `SDIddDriver.dll` with a trusted local certificate.
   - Reinstall the driver via `pnputil` and restart `StarDeskService`.
5. Launch StarDesk and connect your device.

---

## Reverting to Stock Drivers
Both scripts automatically create `_Original.dll` backups prior to patching. To restore stock behavior:
- Restore the original DLL:
  ```powershell
  # Apollo
  Copy-Item "$DriverDir\SudoVDA_Original.dll" "$DriverDir\SudoVDA.dll" -Force

  # StarDesk
  Copy-Item "$DriverDir\SDIddDriver_Original.dll" "$DriverDir\SDIddDriver.dll" -Force
  ```
- Or re-run the driver installer provided with your Apollo / StarDesk installation.
