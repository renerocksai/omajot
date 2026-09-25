#!/bin/sh
# Set omajot's version everywhere it is written down, before tagging a release:
#   build.zig.zon     the source for the engine and daemon (build_options.version)
#   manifest.json     the Omarchy plugin
#   web/package.json  the web app (and the root entry of its lockfile)
# The release workflow refuses a v* tag that does not match all three.
#
#   tools/bump-version.sh 0.1.1 && git commit -am "Release 0.1.1" && git tag -a v0.1.1 -m "omajot v0.1.1"
set -eu
new=${1:-}
echo "$new" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "usage: tools/bump-version.sh X.Y.Z" >&2; exit 2; }
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
python3 - "$new" <<'PY'
import json, re, sys
new = sys.argv[1]
s = open("build.zig.zon").read()
s, n = re.subn(r'(\n    \.version = ")[^"]+(",)', rf'\g<1>{new}\2', s, count=1)
assert n == 1, "build.zig.zon: no .version"
open("build.zig.zon", "w").write(s)
for path in ("manifest.json", "web/package.json"):
    s = open(path).read()
    s, n = re.subn(r'("version": ")[^"]+(")', rf'\g<1>{new}\2', s, count=1)
    assert n == 1, f"{path}: no version"
    open(path, "w").write(s)
lock = json.load(open("web/package-lock.json"))
lock["version"] = new
lock["packages"][""]["version"] = new
open("web/package-lock.json", "w").write(json.dumps(lock, indent=2) + "\n")
PY
echo "omajot version is now $new (build.zig.zon, manifest.json, web/package.json)"
