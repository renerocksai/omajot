# Screenshots

All shots show the sample notes (`examples/sample-notes/`), never real notes. No
image may show a loopback address, an IP address, a tailnet or a host name.

**Web app, desktop** (`desktop-split-*`, `desktop-qr-*`): `tools/site_shots.mjs`
(headless Chromium) against a local demo hub. It opens the web app under the
docs host name `https://your-mac.your-tailnet.ts.net:8443/` through a small HTTPS
proxy, so the QR overlay shows the placeholder URL (the web app refuses to show
a QR code for a loopback address).

**Web app, iPhone** (`iphone-{list,note,checklist,folders}-*`): Safari on iOS 26,
iPhone 17 Pro simulator, light and dark appearance, status bar set to 9:41. The
demo hub served a copy of `web/dist` with a small navigation script (the note and
view came from the URL hash); the script was never part of the web app. Safari's
bottom bar (with the address) was painted over with the app background. 640 px wide.

**Plugin** (`plugin-{dropdown,window,qr}-*`): an Omarchy desktop with the sample
notes on a local demo hub. The main window was floated at 1280×800 by a Hyprland
window rule and captured with grim at 1.25×. For the QR shot the plugin used the
placeholder hub URL. Only a dark variant exists; the `-light` files are copies.

**Terminal UI** (`tui-*`): `omajot tui` in Ghostty (font size 15, opaque, no
window rule other than float at 1280×800) against a local demo hub with the
sample notes, the Lisbon note selected; captured with grim at 1.25×. The TUI
read the colours of an Omarchy theme from a scratch HOME: Tokyo Night for dark,
Catppuccin Latte for light, with the Ghostty background set to match. The
picture is drawn with the Kitty graphics protocol.
