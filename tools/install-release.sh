#!/bin/sh
# Install the released omajot binary for this computer into <repo>/bin/omajot.
#
# The binary comes from the GitHub release named in release.json, and its
# SHA-256 must match release.json, which is committed to the repository: a
# changed release asset is rejected. If bin/omajot already matches, nothing
# is downloaded. The plugin runs this script by itself when it has no binary.
#
#   tools/install-release.sh [--dest <file>]      (default: <repo>/bin/omajot)
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
dest="$repo/bin/omajot"
if [ "${1:-}" = "--dest" ] && [ -n "${2:-}" ]; then dest=$2; fi
manifest="$repo/release.json"

fail() { echo "omajot install: $*" >&2; exit 1; }
[ -f "$manifest" ] || fail "no release.json in $repo (build from source: zig build -Doptimize=ReleaseSafe)"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) platform=x86_64-linux ;;
  Linux-aarch64 | Linux-arm64) platform=aarch64-linux ;;
  Darwin-arm64) platform=aarch64-macos ;;
  Darwin-x86_64) platform=x86_64-macos ;;
  *) fail "no release binary for $(uname -s) $(uname -m); build from source" ;;
esac

# release.json: {"tag": "v0.1.0", "assets": {"x86_64-linux": {"name": …, "sha256": …}, …}}
read_manifest() {
  python3 - "$manifest" "$platform" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))
a = m["assets"].get(sys.argv[2])
if not a:
    sys.exit(1)
print(m["repo"], m["tag"], a["name"], a["sha256"])
EOF
}
set -- $(read_manifest) || fail "release.json has no binary for $platform"
gh_repo=$1 tag=$2 name=$3 want=$4

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Put `omajot` on the PATH (~/.local/bin/omajot -> the installed binary).
link() { sh "$repo/tools/link-cli.sh" "$dest" "${1:-}" || true; }

if [ -x "$dest" ] && [ "$(sha256 "$dest")" = "$want" ]; then
  link --quiet
  echo "$dest"
  exit 0
fi

mkdir -p "$(dirname "$dest")"
tmp="$dest.download.$$"
trap 'rm -f "$tmp"' EXIT
# OMAJOT_RELEASE_BASE: tests only (a local server instead of GitHub).
url="${OMAJOT_RELEASE_BASE:-https://github.com/$gh_repo/releases/download}/$tag/$name"
echo "omajot install: downloading $url" >&2
curl -fsSL --retry 3 --connect-timeout 10 -o "$tmp" "$url" || fail "download failed: $url"
got=$(sha256 "$tmp")
[ "$got" = "$want" ] || fail "checksum mismatch for $name: expected $want, got $got"
chmod +x "$tmp"
mv -f "$tmp" "$dest"
trap - EXIT
link
echo "$dest"
