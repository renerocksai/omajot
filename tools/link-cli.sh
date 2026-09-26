#!/bin/sh
# Put the `omajot` command on your PATH: a symlink ~/.local/bin/omajot to the
# given binary. The Omarchy plugin runs this each time it starts the daemon, and
# tools/install-release.sh runs it after an install, so the link always points to
# the binary in use.
#
#   tools/link-cli.sh <path/to/omajot> [--quiet]
#
# It creates the link, or updates a link that already points to an omajot binary.
# It never replaces another file or a link to something else. Set OMAJOT_NO_LINK=1
# to skip it.
set -eu

target=${1:-}
quiet=${2:-}
# Messages go to stderr: callers read a binary path from stdout.
say() { [ "$quiet" = "--quiet" ] || echo "omajot: $*" >&2; }

[ "${OMAJOT_NO_LINK:-}" = "1" ] && exit 0
[ -n "$target" ] && [ -x "$target" ] || { echo "usage: tools/link-cli.sh <path/to/omajot>" >&2; exit 64; }
case "$target" in /*) ;; *) target="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")" ;; esac

bindir="${XDG_BIN_HOME:-$HOME/.local/bin}"
link="$bindir/omajot"
mkdir -p "$bindir"

if [ -L "$link" ]; then
  current=$(readlink "$link")
  [ "$current" = "$target" ] && exit 0
  case "$(basename "$current")" in
    omajot | omajot-*) ln -sfn "$target" "$link"; say "updated $link -> $target" ;;
    *) say "not changing $link: it points to $current"; exit 0 ;;
  esac
elif [ -e "$link" ]; then
  say "not changing $link: it is a file, not a link"
  exit 0
else
  ln -s "$target" "$link"
  say "linked $link -> $target"
fi

# Not on PATH yet: say exactly how to add it for the user's shell. Shell
# configuration files are never edited automatically.
case ":$PATH:" in
  *":$bindir:"*) ;;
  *)
    case "$(basename "${SHELL:-sh}")" in
      zsh) hint="echo 'export PATH=\"$bindir:\$PATH\"' >> ~/.zprofile" ;;
      bash) if [ "$(uname -s)" = Darwin ]; then rc="~/.bash_profile"; else rc="~/.bashrc"; fi
            hint="echo 'export PATH=\"$bindir:\$PATH\"' >> $rc" ;;
      fish) hint="fish_add_path $bindir" ;;
      *) hint="export PATH=\"$bindir:\$PATH\"   (in your shell's startup file)" ;;
    esac
    say "$bindir is not on your PATH yet. Add it once, then open a new terminal:"
    say "  $hint"
    ;;
esac
