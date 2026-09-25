#!/usr/bin/env bash
# Records the web app on an iPhone for the video: Safari in the iOS simulator
# on a Mac, dark mode, sample notes, a scripted session (video/ios-demo.js).
# Writes video/cache/ios.mov. Same safety rules as tools/iphone_shots.sh: its
# own folder, tmux session and port on the Mac; never the real hub.
#
#   video/record-ios.sh        (env: MAC, UDID, PORT like tools/iphone_shots.sh)
set -euo pipefail
MAC=${MAC:?set MAC to the ssh host name of your Mac, e.g. MAC=my-mac}
UDID=${UDID:-2EDB2DC5-12EF-4826-B117-F19F26EA31DD}
PORT=${PORT:-8793}
REMOTE=omajot-video
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
[ "$PORT" != 8787 ] || { echo "record-ios: 8787 is the real hub's port" >&2; exit 1; }
remote() { ssh "$MAC" "zsh -lic $(printf %q "$1")"; }
cleanup() {
  remote "xcrun simctl status_bar $UDID clear >/dev/null 2>&1; xcrun simctl ui $UDID appearance light >/dev/null 2>&1;
          xcrun simctl shutdown $UDID >/dev/null 2>&1; tmux kill-session -t $REMOTE >/dev/null 2>&1; rm -rf ~/$REMOTE" || true
}
trap cleanup EXIT

remote "lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null" && { echo "record-ios: port $PORT is busy on $MAC" >&2; exit 1; }
rsync -a --delete --exclude zig-out --exclude .zig-cache --exclude zig-pkg --exclude node_modules \
  --exclude _site --exclude .git --exclude bin --exclude video/cache "$repo/" "$MAC:$REMOTE/"
remote "cd ~/$REMOTE && zig build -Doptimize=ReleaseSafe && rm -rf demo-dist && cp -R web/dist demo-dist &&
        cp video/ios-demo.js demo-dist/ && sed -i '' 's|</body>|<script src=\"/ios-demo.js\"></script></body>|' demo-dist/index.html"
remote "cd ~/$REMOTE && tmux new-session -d -s $REMOTE \"./zig-out/bin/omajot hub --port $PORT --data ~/$REMOTE/hub-data --no-auth --web ~/$REMOTE/demo-dist\" &&
        sleep 2 && python3 tools/seed_sample.py --data ~/$REMOTE/replica --hub http://127.0.0.1:$PORT --binary ~/$REMOTE/zig-out/bin/omajot"

cat > "$here/cache/take.sh" <<TAKE
set -e
U=$UDID
xcrun simctl boot \$U 2>/dev/null || true
xcrun simctl bootstatus \$U -b >/dev/null 2>&1 || true
xcrun simctl status_bar \$U override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
xcrun simctl ui \$U appearance dark
xcrun simctl terminate \$U com.apple.mobilesafari >/dev/null 2>&1 || true
sleep 1
xcrun simctl io \$U recordVideo --codec=h264 --force ~/$REMOTE/ios.mov >/dev/null 2>&1 &
rec=\$!
sleep 2
xcrun simctl openurl \$U "http://127.0.0.1:$PORT/?v=\$(date +%s)"
sleep 26
kill -INT \$rec
wait \$rec || true
TAKE
scp -q "$here/cache/take.sh" "$MAC:$REMOTE/take.sh"
remote "bash ~/$REMOTE/take.sh" 2>&1 | grep -v -E "^Install (Started|Failed)" || true
scp -q "$MAC:$REMOTE/ios.mov" "$here/cache/ios.mov"
echo "record-ios: $here/cache/ios.mov"
