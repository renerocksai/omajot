#!/usr/bin/env bash
# Real iPhone screenshots of the web app for README.md and the site:
# site/assets/shots/iphone-{list,note,checklist,folders}-{light,dark}.webp
#
# Runs on a Linux or macOS computer and drives a Mac with Xcode over ssh:
#
#   1. rsync this checkout to <mac>:~/omajot-iphone-shots (never ~/omajot)
#      and build omajot there (Zig 0.16.0 on the Mac's login PATH).
#   2. Copy web/dist and add a small navigation script (shot-nav.js). The
#      script opens a note or a view from the URL hash. It exists only in this
#      copy, never in the web app.
#   3. Start a demo hub (--no-auth, loopback) on PORT in its own tmux session,
#      and seed the sample notes (examples/sample-notes) into it.
#   4. Boot the iOS simulator, set the status bar to 9:41, and for light and
#      dark: open each view in Safari and take a screenshot.
#   5. Copy the PNGs back, paint Safari's bottom bar (it shows the address)
#      over with the app background, and write 640 px WebP files.
#   6. Clean up: stop the demo hub, delete the remote folder, reset and shut
#      down the simulator. This also runs when a step fails.
#
#   tools/iphone_shots.sh
#
# Env: MAC (ssh host, default maxross), UDID (simulator, default an iPhone 17
# Pro on iOS 26.5), PORT (demo hub, default 8791; never the real hub's port),
# OUT (default site/assets/shots). Needs ssh, rsync, scp and ImageMagick here;
# Xcode, tmux, python3 and Zig 0.16.0 on the Mac.
set -euo pipefail

MAC=${MAC:-maxross}
UDID=${UDID:-2EDB2DC5-12EF-4826-B117-F19F26EA31DD}
PORT=${PORT:-8791}
repo=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$repo/site/assets/shots}
REMOTE=omajot-iphone-shots      # folder in the Mac's home and tmux session name
VIEWS="list| note|#open=Lisbon%20in%20October&mode=preview checklist|#open=Groceries&mode=preview folders|#view=folders"

[ "$PORT" != 8787 ] || { echo "iphone_shots: port 8787 is the real hub's port" >&2; exit 1; }
work=$(mktemp -d)

remote() { ssh "$MAC" "zsh -lic $(printf %q "$1")"; }

cleanup() {
  remote "xcrun simctl status_bar $UDID clear >/dev/null 2>&1; xcrun simctl ui $UDID appearance light >/dev/null 2>&1;
          xcrun simctl shutdown $UDID >/dev/null 2>&1; tmux kill-session -t $REMOTE >/dev/null 2>&1; rm -rf ~/$REMOTE" || true
  rm -rf "$work"
}
trap cleanup EXIT

echo "== copy and build on $MAC"
remote "lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null" && { echo "iphone_shots: port $PORT is busy on $MAC" >&2; exit 1; }
rsync -a --delete --exclude zig-out --exclude .zig-cache --exclude zig-pkg --exclude node_modules \
  --exclude _site --exclude .git --exclude bin "$repo/" "$MAC:$REMOTE/"
remote "cd ~/$REMOTE && zig build -Doptimize=ReleaseSafe"

echo "== web app copy with the navigation script"
cat > "$work/shot-nav.js" <<'EOF'
// Screenshot harness only, never shipped: #open=<note title>&mode=<split|source|preview>, #view=folders
(function () {
  const p = new URLSearchParams(location.hash.slice(1))
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
  async function until(fn, ms = 15000) { const t = Date.now(); while (!fn() && Date.now() - t < ms) await sleep(100) }
  const button = (text) => [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === text)
  async function run() {
    // A tab from the previous shot may still hold the replica lock: take over.
    await until(() => document.querySelectorAll('.nrow').length > 5 || button('Use here'), 8000)
    if (button('Use here')) { button('Use here').click(); await sleep(500) }
    await until(() => document.querySelectorAll('.nrow').length > 5)
    await sleep(400)
    if (p.get('view') === 'folders') { document.querySelector('.p-list .back')?.click(); return }
    const title = p.get('open')
    if (!title) return
    ;[...document.querySelectorAll('.nrow')].find((r) => r.textContent.includes(title))?.click()
    await until(() => document.querySelector('.cm-content')?.textContent.includes(title))
    const want = p.get('mode')
    for (let i = 0; want && i < 4 && document.querySelector('.app')?.dataset.mode !== want; i++) {
      document.querySelector('.toolbar [data-act="mode"]')?.click()
      await sleep(250)
    }
    document.activeElement?.blur()
  }
  addEventListener('load', run)
})()
EOF
scp -q "$work/shot-nav.js" "$MAC:$REMOTE/shot-nav.js"
remote "cd ~/$REMOTE && rm -rf shots-dist && cp -R web/dist shots-dist && cp shot-nav.js shots-dist/ &&
        sed -i '' 's|</body>|<script src=\"/shot-nav.js\"></script></body>|' shots-dist/index.html"

echo "== demo hub on port $PORT, sample notes"
remote "cd ~/$REMOTE && tmux new-session -d -s $REMOTE \"./zig-out/bin/omajot hub --port $PORT --data ~/$REMOTE/hub-data --no-auth --web ~/$REMOTE/shots-dist\" &&
        sleep 2 && python3 tools/seed_sample.py --data ~/$REMOTE/replica --hub http://127.0.0.1:$PORT --binary ~/$REMOTE/zig-out/bin/omajot"

echo "== simulator"
views_quoted=$(for v in $VIEWS; do printf "'%s' " "$v"; done)
cat > "$work/take.sh" <<EOF
set -e
U=$UDID
xcrun simctl boot \$U 2>/dev/null || true
xcrun simctl bootstatus \$U -b >/dev/null 2>&1 || true
xcrun simctl status_bar \$U override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
mkdir -p ~/$REMOTE/png
n=0
for theme in light dark; do
  xcrun simctl ui \$U appearance \$theme
  for spec in $views_quoted; do
    name=\${spec%%|*}; frag=\${spec#*|}; n=\$((n+1))
    xcrun simctl terminate \$U com.apple.mobilesafari >/dev/null 2>&1 || true
    sleep 1
    xcrun simctl openurl \$U "http://127.0.0.1:$PORT/?s=\$n\$frag"
    sleep 8
    xcrun simctl io \$U screenshot ~/$REMOTE/png/\$name-\$theme.png >/dev/null 2>&1
    echo "  \$name-\$theme"
  done
done
EOF
scp -q "$work/take.sh" "$MAC:$REMOTE/take.sh"
remote "bash ~/$REMOTE/take.sh" 2>&1 | grep -v -E "^Install (Started|Failed)" || true

echo "== WebP files"
mkdir -p "$work/png" "$OUT"
scp -q "$MAC:$REMOTE/png/*.png" "$work/png/"
for f in "$work"/png/*.png; do
  name=$(basename "$f" .png)
  # Safari's bottom bar starts at y=2160 on the 1206×2622 iPhone 17 Pro screen:
  # paint it over with the app's background just above it.
  bg=$(magick "$f" -format "%[pixel:p{1100,2152}]" info:)
  magick "$f" -fill "$bg" -draw "rectangle 0,2160 9999,9999" -resize 640x -quality 84 "$OUT/iphone-$name.webp"
  echo "  $OUT/iphone-$name.webp"
done
echo "== done (cleaning up on $MAC)"
