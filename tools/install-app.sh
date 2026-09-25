#!/bin/sh
# Add omajot to the Omarchy app launcher (SUPER + SPACE). Optional: the plugin
# works without it. The entry opens the plugin's main window through the
# running Omarchy shell; nothing else is installed. The launcher lists desktop
# entries from ~/.local/share/applications and searches their name,
# GenericName (shown under the name), Comment and Keywords.
#
#   tools/install-app.sh            add the launcher entry and the icon
#   tools/install-app.sh --remove   remove them again
#
# For a keyboard shortcut that opens and closes the window, add this line to
# ~/.config/hypr/bindings.lua:
#   o.bind("SUPER + SHIFT + N", "omajot", "omarchy-shell shell toggle io.github.renerocksai.omajot")
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
desktop="$apps/omajot.desktop"
# Where Omarchy's own installers (omarchy-tui-install) put launcher icons.
icon="$icons/256x256/apps/omajot.png"

refresh() {
  gtk-update-icon-cache "$icons" >/dev/null 2>&1 || true
  update-desktop-database "$apps" >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--remove" ]; then
  rm -f "$desktop" "$icon" "$icons/512x512/apps/omajot.png"
  refresh
  echo "omajot: removed from the app launcher"
  exit 0
fi

mkdir -p "$apps" "$(dirname "$icon")"
cp "$repo/web/src/icons/icon-512.png" "$icon"
cat >"$desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=omajot
GenericName=Notes
Comment=Markdown notes, synced by your own hub
Exec=omarchy shell io.github.renerocksai.omajot window
Icon=omajot
Terminal=false
Keywords=notes;markdown;todo;checklist;
StartupNotify=false
EOF
chmod +x "$desktop"
refresh
echo "omajot: added to the app launcher (SUPER + SPACE, type omajot)"
