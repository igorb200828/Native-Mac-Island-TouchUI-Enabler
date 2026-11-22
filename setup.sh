#!/bin/bash
# MacIsland — enables Dynamic Island (CenterHUD) and/or system-wide Touch UI on macOS 27.3+
set -e

DIR="$HOME/Library/MacIsland"
ISLAND_AGENT="$HOME/Library/LaunchAgents/com.macisland.loader.plist"
TOUCH_AGENT="$HOME/Library/LaunchAgents/com.macisland.touchui.plist"
TOUCH_DYLIB="/usr/local/lib/touchui.dylib"
LIBVAL_PLIST="/Library/Preferences/com.apple.security.libraryvalidation.plist"
UI_PROCS="ControlCenter Finder Dock NotificationCenter SystemUIServer Spotlight"
SRC="$(cd "$(dirname "$0")" && pwd)"
UID_NUM="$(id -u)"
NEEDS_REBOOT=0

[[ "$(uname -m)" == "arm64" ]] || { echo "Apple Silicon only"; exit 1; }
csrutil status | grep -q disabled || { echo "SIP must be disabled (or Debugging Restrictions disabled)"; exit 1; }

echo "Select what to install:"
echo "  1) Both Dynamic Island and Touch UI"
echo "  2) Dynamic Island only"
echo "  3) Touch UI only"
echo "  4) Uninstall both"
read -r -p "Choice [1-4]: " CHOICE

INSTALL_ISLAND=0
INSTALL_TOUCH=0

case "$CHOICE" in
  1) INSTALL_ISLAND=1; INSTALL_TOUCH=1 ;;
  2) INSTALL_ISLAND=1 ;;
  3) INSTALL_TOUCH=1 ;;
  4) ;;
  *) echo "Invalid choice."; exit 1 ;;
esac

if [[ "$CHOICE" == "4" ]]; then
  echo "Uninstalling Dynamic Island..."
  launchctl bootout "gui/$UID_NUM" "$ISLAND_AGENT" 2>/dev/null || true
  rm -f "$ISLAND_AGENT"
  rm -rf "$DIR"
  
  C="$HOME/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar"
  defaults delete "$C" ShowSoftwareNotch 2>/dev/null || true
  defaults delete "$C" EmulateCenterHUD 2>/dev/null || true
  defaults delete com.apple.campo SupportsIslandMitosis 2>/dev/null || true
  killall MenuBarAgent 2>/dev/null || true

  echo "Uninstalling Touch UI..."
  launchctl bootout "gui/$UID_NUM" "$TOUCH_AGENT" 2>/dev/null || true
  rm -f "$TOUCH_AGENT"
  
  if [[ "$(launchctl getenv DYLD_INSERT_LIBRARIES)" == "$TOUCH_DYLIB" ]]; then
    launchctl unsetenv DYLD_INSERT_LIBRARIES
    killall $UI_PROCS 2>/dev/null || true
  fi
  
  CUR_LIBVAL="$(defaults read "$LIBVAL_PLIST" DisableLibraryValidation 2>/dev/null || echo 0)"
  if [[ "$CUR_LIBVAL" == "1" ]]; then
    echo "[Touch UI] Re-enabling Library Validation"
    sudo defaults write "$LIBVAL_PLIST" DisableLibraryValidation -bool false
    NEEDS_REBOOT=1
  fi
  
  if [[ -f "$TOUCH_DYLIB" ]]; then
    sudo rm -f "$TOUCH_DYLIB"
  fi

  echo "Done. Dynamic Island and Touch UI uninstalled. Reboot to fully reset feature flags."
  if [[ "$NEEDS_REBOOT" -eq 1 ]]; then
    echo "Note: Library Validation was updated — reboot once for the change to take full effect."
  fi
  exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents"

if [[ "$INSTALL_ISLAND" -eq 1 ]]; then
  echo "[Dynamic Island] Writing MenuBarAgent preferences"
  C="$HOME/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar"
  defaults write "$C" ShowSoftwareNotch -bool true
  defaults write "$C" EmulateCenterHUD -bool true
  defaults write com.apple.campo SupportsIslandMitosis -bool true

  echo "[Dynamic Island] Building island.dylib"
  mkdir -p "$DIR"
  clang -arch arm64e -dynamiclib -fobjc-arc -o "$DIR/island.dylib" "$SRC/src/island.m" \
    -framework Foundation -framework AppKit \
    -F/System/Library/PrivateFrameworks -framework CoreUtils -undefined dynamic_lookup
  codesign -f -s - "$DIR/island.dylib"
  cp "$SRC/src/loader.py" "$DIR/loader.py"

  echo "[Dynamic Island] Installing LaunchAgent"
  cat > "$ISLAND_AGENT" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.macisland.loader</string>
  <key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>$DIR/loader.py</string></array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$DIR/loader.log</string>
  <key>StandardErrorPath</key><string>$DIR/loader-error.log</string>
</dict></plist>
PL
  launchctl bootout "gui/$UID_NUM" "$ISLAND_AGENT" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$ISLAND_AGENT"
  echo "[Dynamic Island] Enabled."
else
  launchctl bootout "gui/$UID_NUM" "$ISLAND_AGENT" 2>/dev/null || true
  rm -f "$ISLAND_AGENT"
fi

if [[ "$INSTALL_TOUCH" -eq 1 ]]; then
  echo "[Touch UI] Building universal touchui.dylib (requires sudo for /usr/local/lib)"
  sudo mkdir -p /usr/local/lib
  sudo clang -shared -arch arm64 -arch arm64e -lobjc -o "$TOUCH_DYLIB" "$SRC/src/touchui.m"
  sudo codesign -f -s - "$TOUCH_DYLIB"
  sudo chmod 755 "$TOUCH_DYLIB"

  CUR_LIBVAL="$(defaults read "$LIBVAL_PLIST" DisableLibraryValidation 2>/dev/null || echo 0)"
  if [[ "$CUR_LIBVAL" != "1" ]]; then
    echo "[Touch UI] Disabling Library Validation for Finder/Safari compatibility"
    sudo defaults write "$LIBVAL_PLIST" DisableLibraryValidation -bool true
    NEEDS_REBOOT=1
  fi

  echo "[Touch UI] Installing LaunchAgent"
  cat > "$TOUCH_AGENT" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.macisland.touchui</string>
  <key>ProgramArguments</key><array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>/bin/launchctl setenv DYLD_INSERT_LIBRARIES $TOUCH_DYLIB &amp;&amp; /bin/sleep 1 &amp;&amp; /usr/bin/killall $UI_PROCS 2&gt;/dev/null || true</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL
  launchctl bootout "gui/$UID_NUM" "$TOUCH_AGENT" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$TOUCH_AGENT"
  launchctl setenv DYLD_INSERT_LIBRARIES "$TOUCH_DYLIB"
  killall $UI_PROCS 2>/dev/null || true
  echo "[Touch UI] Enabled."
else
  launchctl bootout "gui/$UID_NUM" "$TOUCH_AGENT" 2>/dev/null || true
  rm -f "$TOUCH_AGENT"
  if [[ "$(launchctl getenv DYLD_INSERT_LIBRARIES)" == "$TOUCH_DYLIB" ]]; then
    launchctl unsetenv DYLD_INSERT_LIBRARIES
    killall $UI_PROCS 2>/dev/null || true
  fi
  CUR_LIBVAL="$(defaults read "$LIBVAL_PLIST" DisableLibraryValidation 2>/dev/null || echo 0)"
  if [[ "$CUR_LIBVAL" == "1" ]] && [[ -f "$TOUCH_DYLIB" ]]; then
    echo "[Touch UI] Re-enabling Library Validation"
    sudo defaults write "$LIBVAL_PLIST" DisableLibraryValidation -bool false
    NEEDS_REBOOT=1
  fi
fi

echo "Done."

if [[ "$NEEDS_REBOOT" -eq 1 ]]; then
  echo "Note: Library Validation was updated — reboot once for the change to take full effect."
fi