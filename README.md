# Native Mac Island TouchUI Enabler

Enables macOS 27.3's hidden **Dynamic Island** (internally `CenterHUD` / System Aperture) and **system-wide Touch UI (Direct Touch)** on Apple Silicon Macs.

Built on top of [MakrSas/MacIsland](https://github.com/MakrSas/MacIsland).

## Features

* **Dynamic Island (`island.dylib`)** — Enables the native Live Activities / CenterHUD pill in `MenuBarAgent` with customizable dimensions (`250px` default width), flattened top corners, stabilized spawn/expansion animations, and Siri AI / Spotlight Island Mitosis support.
* **System-Wide Touch UI (`touchui.dylib`)** — Forces macOS's native Direct Touch interface across apps and system UI (`ControlCenter`, `Calendar`, `Safari`, `Finder`, `Dock`, `NotificationCenter`, and standard AppKit/SwiftUI apps), enabling touch-adaptive controls, Liquid Glass touch feedback, and `DirectGestureSpacing` menus.
* **Interactive Installer** — Choose to install **Both**, **Dynamic Island only**, **Touch UI only**, or **Uninstall both** from a single script.
* **No `amfi_get_out_of_my_way=1` Needed** — Works without disabling AMFI globally, avoiding crashes in JIT-dependent apps.

---

## How It Works

### 1. Dynamic Island (`MenuBarAgent`)
* Uses the native Live Activities support already present in macOS 27.3; no global feature-flag domains are overwritten.
* `MenuBarAgent` reads `ShowSoftwareNotch` and `EmulateCenterHUD` from its `com.apple.MenuBar` group-suite preferences, but only when `IsAppleInternalBuild()` returns `true`.
* `island.dylib` (`arm64e`) interposes `IsAppleInternalBuild` (CoreUtils) to return `true` **only** inside `MenuBarAgent`, while also patching `NSScreen` HUD geometry, top-corner masking, and `CALayer` / `CAPresentationModifier` / `FBSSceneSettings` layout hooks so expanded Live Activities animate cleanly.
* A LaunchAgent (`~/Library/LaunchAgents/com.macisland.loader.plist`) injects `island.dylib` at login via `loader.py`, waits for the new `MenuBarAgent` PID, and immediately restores the launch environment.
  * Logs: `~/Library/MacIsland/loader.log` and `~/Library/MacIsland/loader-error.log`.
  * `state = not running` with `last exit code = 0` is normal—the loader exits once injection completes.
* Siri AI / Spotlight uses a separate native preference (`defaults write com.apple.campo SupportsIslandMitosis -bool true`), which the installer sets automatically. If Siri AI is already running, reload it with:
  ```bash
  launchctl kickstart -k gui/$(id -u)/com.apple.campo
  ```

### 2. System-Wide Touch UI (`touchui.dylib`)
* Compiled as a lightweight universal (`arm64` + `arm64e`), `-lobjc`-only dylib installed at `/usr/local/lib/touchui.dylib` so sandboxed apps and system daemons can load it safely. Non-GUI background daemons exit the constructor immediately.
* Hooks `NSScreen` (`_isTouchScreen`, `touchCapabilities`), `NSEvent` (`_lastInteractionWasDirectTouch`), and AppKit menu classes (`NSMenu`, `NSCocoaMenuImpl`, `NSContextMenuImpl`, `NSMenuTrackingSession`, `NSMenuBarTrackingSession`) to report direct-touch capabilities and `DirectGestureSpacing`.
* A LaunchAgent (`~/Library/LaunchAgents/com.macisland.touchui.plist`) sets `DYLD_INSERT_LIBRARIES` for your GUI session at login and refreshes `ControlCenter`, `Finder`, `Dock`, `NotificationCenter`, `SystemUIServer`, and `Spotlight`.
* Because platform binaries like `Safari` and `Finder` enforce Library Validation (`0x2000`), the installer automatically sets `DisableLibraryValidation = true` in `/Library/Preferences/com.apple.security.libraryvalidation.plist` when Touch UI is enabled (and reverts it to `false` on uninstall).

---

## Requirements

* **Hardware & OS:** Apple Silicon Mac running macOS 27.3+ (tested on `26C5035r`)
* **SIP:** Disabled (`csrutil disable`), or partial SIP with Debugging Restrictions disabled (`csrutil enable --without debug` Not tested, a speculation)
  * `amfi_get_out_of_my_way=1` is **not** required.
* **Tools:** Xcode Command Line Tools (`xcode-select --install`)

---

## Known Issues

* Not all Live Activites are affected by expanded top offset making some appear behind the notch. Music Live Activity is not affected by this.
* Touch UI may not effect all of the Applications installed.

---

## Install

```bash
git clone https://github.com/igorb200828/Native-Mac-Island-TouchUI-Enabler && cd Native-Mac-Island-TouchUI-Enabler
chmod +x setup.sh
./setup.sh
```

Select one of the four options when prompted:
1. **Both Dynamic Island and Touch UI**
2. **Dynamic Island only**
3. **Touch UI only**
4. **Uninstall both**

> **Note:** When enabling or disabling **Touch UI** for the first time, the installer toggles Library Validation—**reboot once** so `Finder`, `Safari`, and other library-validated apps pick up the change.

---

## Customization (Dynamic Island)

You can override the compiled defaults in `com.apple.MenuBar` and re-run `./setup.sh` (or restart `MenuBarAgent`):

```bash
C="$HOME/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar"

defaults write "$C" MacIslandWidth -float 250               # Default: 250
defaults write "$C" MacIslandHeight -float 40               # Default: 40
defaults write "$C" MacIslandTopMargin -float -1            # Default: -1
defaults write "$C" MacIslandExpandedObsWidth -float 60     # Default: 60
defaults write "$C" MacIslandExpandedTopOffset -float 32    # Default: 32
defaults write "$C" MacIslandFlattenTopLayers -bool true    # Default: true
defaults write "$C" MacIslandSpoofTouchScreen -bool true    # Default: true
```

---

## Uninstall

Run `./setup.sh` and choose **option `4` (Uninstall both)**. This unloads both LaunchAgents, removes `/usr/local/lib/touchui.dylib`, unsets `DYLD_INSERT_LIBRARIES`, refreshes system UI processes, and re-enables Library Validation.

---

## Disclaimer

Disabling SIP (or Debugging Restrictions) and Library Validation lowers your Mac's security. Use at your own risk. Not affiliated with Apple.

## Credits

* Feature discovery: **@itspdfu**
* Original Dynamic Island project: **[MakrSas/MacIsland](https://github.com/MakrSas/MacIsland)**
