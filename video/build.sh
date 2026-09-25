#!/usr/bin/env bash
# Builds omajot's social-media video: 1920×1080, 30 fps, H.264 + AAC, ~−14 LUFS.
#
#   AUDIO="video/cache/neon-drive.mp3" CUT=video/tracks/neon-drive.json video/build.sh
#   video/build.sh                       (no AUDIO: the generated synthwave track)
#
# Music and cuts: every scene cut and caption lands on a downbeat listed in the
# cut map (CUT, JSON). tracks/neon-drive.json is tuned to the Suno track "Neon
# Drive" (123 BPM; beat times from librosa; its first downbeat is 4.249 s after
# a pad intro). tracks/synth.json matches video/synth.mjs (120 BPM, downbeats
# every 2 s from 0). For another track, write a cut map like those two:
# `node video/beats.mjs <track>` prints its tempo and bar times. AUDIO_OFFSET
# (seconds) skips a track intro, so the map's times start after it. The music
# is not committed; put it in video/cache/.
#
# Steps (cached in video/cache/, gitignored; RERECORD=1 records again):
#   1. zig build: omajot for the demo hubs and the `omajot qr` output
#   2. the web app: a local demo hub with the sample notes, record-web.mjs
#   3. the iPhone: record-ios.sh on a Mac (MAC=<ssh host>), frames IOS_START..IOS_END s
#   4. the QR text (omajot qr for the docs URL) and the release sizes (gh)
#   5. render.mjs: timeline.html frame by frame
#   6. ffmpeg: video + music, trimmed to the cut map's duration, two-pass
#      loudnorm to −14 LUFS, AAC 192 kb/s; a poster frame
#
# Needs: Zig 0.16.0, node (web/node_modules: `cd web && npm ci`), Chromium,
# ffmpeg with libx264, ImageMagick, python3, gh, and for the iPhone a Mac with
# Xcode reached over ssh. Output: OUT (default video/out/omajot.mp4).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
cache=$here/cache
OUT=${OUT:-$here/out/omajot.mp4}
FPS=${FPS:-30}
WEB_PORT=${WEB_PORT:-8792}
IOS_START=${IOS_START:-5.0}
IOS_END=${IOS_END:-17.4}
AUDIO_OFFSET=${AUDIO_OFFSET:-0}
mkdir -p "$cache" "$(dirname "$OUT")"

echo "== 1. omajot"
(cd "$repo" && zig build -Doptimize=ReleaseSafe)
omajot=$repo/zig-out/bin/omajot

if [ -n "${RERECORD:-}" ] || [ ! -d "$cache/web" ]; then
  echo "== 2. web app recording"
  demo=$(mktemp -d)
  "$omajot" hub --port "$WEB_PORT" --data "$demo/hub" --no-auth --web "$repo/web/dist" >"$demo/hub.log" 2>&1 &
  hub=$!
  trap 'kill $hub 2>/dev/null || true; rm -rf "$demo"' EXIT
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$WEB_PORT/api/whoami" && break; sleep 0.2; done
  python3 "$repo/tools/seed_sample.py" --data "$demo/replica" --hub "http://127.0.0.1:$WEB_PORT" >/dev/null
  HUB=http://127.0.0.1:$WEB_PORT OUT="$cache/web" node "$here/record-web.mjs"
  kill $hub; wait $hub 2>/dev/null || true; rm -rf "$demo"; trap - EXIT
fi

if [ -n "${RERECORD:-}" ] || [ ! -f "$cache/ios.mov" ]; then
  echo "== 3. iPhone recording"
  "$here/record-ios.sh"
  rm -rf "$cache/ios"
fi
if [ ! -d "$cache/ios" ]; then
  echo "== 3. iPhone frames ($IOS_START..$IOS_END s), Safari's address bar painted over"
  mkdir -p "$cache/ios" "$cache/iosraw"
  ffmpeg -v error -ss "$IOS_START" -to "$IOS_END" -i "$cache/ios.mov" -vf "fps=$FPS" "$cache/iosraw/%05d.png"
  # Safari's bottom bar starts at y=2160 on the 1206×2622 screen (as in tools/iphone_shots.sh).
  ls "$cache"/iosraw/*.png | xargs -P 8 -I{} sh -c 'f={}; bg=$(magick "$f" -format "%[pixel:p{1100,2152}]" info:);
    magick "$f" -fill "$bg" -draw "rectangle 0,2160 9999,9999" -resize 603x -quality 88 "'"$cache"'/ios/$(basename "$f" .png).jpg"'
  rm -rf "$cache/iosraw"
fi

echo "== 4. QR text and release sizes"
"$omajot" qr https://your-mac.your-tailnet.ts.net:8443 >"$cache/qr.txt"
gh release view --repo renerocksai/omajot --json assets,tagName >"$cache/release.json"

if [ -z "${AUDIO:-}" ]; then
  echo "== music: the generated synthwave track"
  node "$here/synth.mjs" "$cache/soundtrack.wav"
  AUDIO=$cache/soundtrack.wav
  CUT=${CUT:-$here/tracks/synth.json}
fi
CUT=${CUT:?set CUT to the cut map for this track (see the header)}
duration=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['duration'])" "$CUT")

echo "== 5. render ($CUT, $duration s at $FPS fps)"
CUT=$CUT FPS=$FPS node "$here/render.mjs"

echo "== 6. encode"
alen=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AUDIO")
fade=""
# Fade out only when the music runs past the video; a track that ends with the video keeps its own ending.
if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) - float(sys.argv[2]) > float(sys.argv[3]) + 0.3 else 1)" "$alen" "$AUDIO_OFFSET" "$duration"; then
  fade=",afade=t=out:st=$(python3 -c "print(max(0, $duration - 1.5))"):d=1.5"
fi
pre="atrim=0:$duration,asetpts=PTS-STARTPTS$fade"
# Two-pass loudness normalization to -14 LUFS integrated, -1.5 dBTP.
m=$(ffmpeg -hide_banner -nostats -ss "$AUDIO_OFFSET" -i "$AUDIO" -af "$pre,loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json" -f null - 2>&1 | sed -n '/^{/,/^}/p')
get() { python3 -c "import json,sys; print(json.loads(sys.stdin.read())[sys.argv[1]])" "$1" <<<"$m"; }
norm="loudnorm=I=-14:TP=-1.5:LRA=11:measured_I=$(get input_i):measured_TP=$(get input_tp):measured_LRA=$(get input_lra):measured_thresh=$(get input_thresh):offset=$(get target_offset):linear=true"
ffmpeg -v error -y -framerate "$FPS" -i "$cache/frames/%05d.jpg" -ss "$AUDIO_OFFSET" -i "$AUDIO" \
  -filter_complex "[0:v]scale=in_range=pc:out_range=tv,format=yuv420p[v];[1:a]$pre,$norm,aresample=48000[a]" -map "[v]" -map "[a]" -t "$duration" \
  -c:v libx264 -preset slow -crf 20 -maxrate 3M -bufsize 6M -pix_fmt yuv420p -profile:v high -r "$FPS" \
  -c:a aac -b:a 192k -movflags +faststart "$OUT"
poster_t=$(python3 -c "import json,sys; s=json.load(open(sys.argv[1]))['scenes']['hook']; print(s['sub'] + 0.6)" "$CUT")
ffmpeg -v error -y -ss "$poster_t" -i "$OUT" -frames:v 1 "${OUT%.mp4}-poster.png"
echo "== done: $OUT ($(du -h "$OUT" | cut -f1)), poster ${OUT%.mp4}-poster.png"
