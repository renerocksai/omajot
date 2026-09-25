# omajot

**Your notes. Your hub. Everywhere.**

omajot is a markdown notes app in the spirit of Apple Notes. Open it from the
[Omarchy](https://omarchy.org/) bar, in a main window, or as a web app on your
phone. Your own small Zig hub syncs all devices over
[Tailscale](https://tailscale.com). No cloud account. No Dropbox. No conflicts.

**[Documentation and screenshots →](https://renerocksai.github.io/omajot/)**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="site/assets/shots/desktop-note-dark.webp">
  <img alt="The omajot web app: folders and tags, the note list, and a note with a picture, a table and a checklist in split view" src="site/assets/shots/desktop-note-light.webp">
</picture>

## No Omarchy? No Linux? No problem.

The web app is a complete omajot client. You do not need Omarchy or Linux. You
need only the hub:

1. Run the hub on a computer that is always on: a Mac, a Linux computer, or a
   Windows computer (experimental).
2. Publish the hub on your tailnet with Tailscale. Tailscale is free for
   personal use.
3. Open the hub URL in a desktop browser or on your phone. Install it as an
   app: on an iPhone or iPad, tap *Share* → *Add to Home Screen*. On Android,
   and in Chrome or Edge on the desktop, use *Install app*.

Your notes work offline. They sync when the hub is reachable. The Omarchy
plugin is an extra for Omarchy users. It is not a requirement.

We test the web app in Chrome and Chromium on the desktop and in Safari on
iOS 26. Other modern browsers should work.

**Get your phone onto the hub without typing the URL.** Use a QR code:

1. `omajot hub` prints its phone URL and a QR code in the terminal when it
   starts. It finds the URL in `tailscale serve status`. `--url` sets the URL.
   After you run `tailscale serve`, restart the hub, or look at its start
   output in tmux.
2. `omajot qr` prints the QR code on any computer where
   `~/.config/omajot/config.json` has your hub.
3. Open the hub URL once in a desktop browser. Click the phone button in the
   web app. It shows the address of the page as a QR code.

Scan the code with the phone camera and open the link. Then tap *Share* → *Add
to Home Screen*. The phone needs Tailscale.

<p>
  <picture><source media="(prefers-color-scheme: dark)" srcset="site/assets/shots/iphone-list-dark.webp"><img alt="The note list on an iPhone" src="site/assets/shots/iphone-list-light.webp" width="210"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="site/assets/shots/iphone-note-dark.webp"><img alt="A note with a picture and a table on an iPhone" src="site/assets/shots/iphone-note-light.webp" width="210"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="site/assets/shots/iphone-checklist-dark.webp"><img alt="A checklist on an iPhone" src="site/assets/shots/iphone-checklist-light.webp" width="210"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="site/assets/shots/iphone-folders-dark.webp"><img alt="Folders and tags on an iPhone" src="site/assets/shots/iphone-folders-light.webp" width="210"></picture>
</p>

*Real screenshots from iOS 26 Safari (iPhone 17 Pro simulator), sample notes.*

## Features

- **Markdown first.** Write plain markdown. The preview shows headings, tables,
  code, quotes, links and images. The first line of a note is its title.
- **Checklists.** Write `- [ ]`. Click the box in the preview to tick it.
- **Inline tags.** Write `#garden` anywhere. omajot lists your tags next to your folders.
- **Folders, pins and a Trash.** Nested folders. Pinned notes show first.
- **Paste anything.** Screenshots, files, web pages and LibreOffice text. Images
  become attachments. HTML becomes markdown.
- **In your bar.** A dropdown and a main window, both with three columns and full
  keyboard control.
- **On every device.** The hub serves an installable web app for phones, tablets
  and desktop browsers. It starts offline.
- **Offline first, conflict free.** Every device keeps all notes. A CRDT, written
  in Zig, merges concurrent edits.
- **One QR code away.** `omajot qr` prints your hub URL as a QR code in the terminal.
- **Coming from Joplin?** One command imports notebooks, notes, tags and images, with their dates.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="site/assets/shots/plugin-window-dark.webp">
  <img alt="The omajot main window on Omarchy: folders and tags, the note list, and a note with a picture, a table and a checklist" src="site/assets/shots/plugin-window-light.webp">
</picture>

## How it works

```
   Omarchy desktop                    always-on computer                   phone, tablet
  ┌──────────────────┐   HTTPS over   ┌───────────────────────┐   HTTPS   ┌──────────────────┐
  │ QML plugin       │   Tailscale    │ omajot hub            │           │ web app          │
  │ omajot daemon    │◀──────────────▶│ baz on bounded/http   │◀─────────▶│ core.wasm        │
  │ Zig core, native │                │ append-only log, blobs│           │ Zig core, WASM   │
  └──────────────────┘                └───────────────────────┘           └──────────────────┘
```

The hub stores and forwards changes. Every device keeps a full copy of all
notes. The same pure Zig core runs natively in the desktop daemon and, as
`core.wasm`, in the browser. Read
[Under the hood](https://renerocksai.github.io/omajot/under-the-hood.html) for the
CRDT, the edit transforms, and why every limit in the hub is fixed.

## Quick start

You need a Tailscale account (free for personal use) and a computer that is
always on for the hub. omajot releases have static binaries, so you do not need
a compiler. The
[Get started guide](https://renerocksai.github.io/omajot/get-started.html) has
all details.

Web app only (no Omarchy): do steps 1, 2 and 5. With the Omarchy plugin: do
steps 1 to 5.

**1. Run the hub** on the computer that is always on (macOS or Linux):

```sh
git clone https://github.com/renerocksai/omajot && cd omajot
tools/install-release.sh
tmux new -s omajot-hub
bin/omajot hub --port 8787 --data ~/omajot-data --login you@example.com
```

The `tmux` line is optional: tmux keeps the hub running after you close the
terminal. Omarchy includes tmux; on a Mac, install it with `brew install tmux`.
Leave the session with *Ctrl+b*, then *d*. Come back with
`tmux attach -t omajot-hub`. The
[Get started guide](https://renerocksai.github.io/omajot/get-started.html#tmux)
has more, and shows how to run the hub as a service that starts at boot
(systemd on Omarchy and Linux, launchd on macOS).

`tools/install-release.sh` downloads the released binary for this computer. It
checks the SHA-256 against `release.json` in the repository before it installs
the binary into `bin/omajot`. Replace `you@example.com` with your Tailscale
login name. On Windows (experimental), download `omajot-x86_64-windows.exe`
from the [releases](https://github.com/renerocksai/omajot/releases).

**2. Publish it on your tailnet**, on the same computer:

```sh
tailscale serve --bg --https=8443 http://127.0.0.1:8787
```

Your hub URL is now `https://your-mac.your-tailnet.ts.net:8443`. Do not use
Tailscale Funnel.

**3. Omarchy only: install the plugin** on your Omarchy computer:

```sh
omarchy plugin add https://github.com/renerocksai/omajot --enable
```

When the plugin starts the first time, it runs `tools/install-release.sh`. The
script downloads the omajot binary for this computer and checks its SHA-256. A
local build in `zig-out/` has priority, if it exists.

**4. For the plugin (and `omajot qr`): tell omajot where the hub is.** Create
`~/.config/omajot/config.json`:

```json
{ "hub": "https://your-mac.your-tailnet.ts.net:8443" }
```

**5. Open it in your browser and on your phone.** On a computer, open the hub
URL in the browser. Install Tailscale on the phone. Scan the QR code
from the hub, from `omajot qr` or from the web app (see above). Then add the web
app to the home screen.

If there is no release yet, build from source (below).

**Optional: start omajot like an app.** `tools/install-app.sh` (in the plugin
folder) adds omajot to the app launcher (*SUPER + SPACE*). For a key that opens
and closes the main window, add this line to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + N", "omajot", "omarchy-shell shell toggle io.github.renerocksai.omajot")
```

### Try it on one computer

```sh
tools/install-release.sh
bin/omajot hub --port 8787 --data /tmp/omajot-demo --no-auth &
tools/seed_sample.py --data /tmp/omajot-demo-replica --hub http://127.0.0.1:8787
```

Open `http://127.0.0.1:8787`. The sample notes are in `examples/sample-notes/`.

## Coming from Joplin?

Only for Joplin users; skip this if you start fresh. The importer needs
Python 3. Run it on the computer that has Joplin, in an omajot folder: with
the Omarchy plugin, that is the plugin folder that `omarchy plugin add` made
(below); without it, your omajot clone (run `tools/install-release.sh` there
first).

```sh
cd ~/.config/omarchy/plugins/io.github.renerocksai.omajot   # the plugin folder
tools/import_joplin.py --dry-run
tools/import_joplin.py --data ~/omajot-import
```

The importer uses your own build (`zig-out`) if there is one, else the release binary (`bin/omajot`).

The importer reads `~/.config/joplin-desktop` and does not change it. It sends
the notes to your hub, and the plugin gets them from there. You can run it
again: it skips notes that it imported before.

## Command line

| Command | What it does |
|---|---|
| `omajot hub --login <you> [--port 8787] [--data <dir>] [--url <url>]` | Runs the hub. Prints its phone URL and a QR code at start. |
| `omajot daemon [--hub <url> \| --no-hub] [--data <dir>]` | The local copy that the plugin uses. Speaks JSON lines on stdin and stdout. |
| `omajot qr [url]` | Prints a URL (default: your hub) as a QR code in the terminal. |

Command-line flags come first, then `~/.config/omajot/config.json`, then the
defaults. See the [CLI reference](https://renerocksai.github.io/omajot/cli.html).

## Platforms

| Platform | Binary |
|---|---|
| Linux x86_64, aarch64 | Static (musl). No shared libraries. |
| macOS arm64, x86_64 | Native. |
| Windows x86_64 | Experimental. It builds natively on bounded/http's IOCP backend. We did not run it as a hub yet. Tailscale for Windows supports `tailscale serve`. |

The web app runs in the browser on every platform.

## Build from source

omajot needs Zig 0.16.0 exactly.

- Omarchy and Arch Linux: `omarchy pkg add zig`. Arch ships Zig 0.16.0 today.
  If Arch has a newer Zig, install 0.16.0 with mise: `mise use -g zig@0.16.0`.
- macOS: download Zig 0.16.0 from [ziglang.org](https://ziglang.org/download/),
  or use mise: `mise use -g zig@0.16.0`.
- Do not use `omarchy-install-dev-env zig`. It installs the latest Zig, and a
  newer Zig cannot build omajot.

For the plugin, build in the plugin folder that `omarchy plugin add` made, and
restart the shell:

```sh
cd ~/.config/omarchy/plugins/io.github.renerocksai.omajot
zig build -Doptimize=ReleaseSafe
omarchy restart shell
```

Development:

```sh
zig build                 # zig-out/bin/omajot (Linux: static, musl)
zig build -Doptimize=ReleaseSafe -Dstrip=true   # the release build, about 2 MB
zig build test            # core, hub and daemon tests
zig build wasm            # zig-out/web/core.wasm
npm test                  # plugin model tests (+ a Qt JS engine smoke test)
cd web && npm ci && npm run build && npm test && npm run e2e
python3 tools/build_site.py   # the documentation site, into _site/
```

`web/dist/` is committed, so the hub needs no Node.js to serve the web app.

## Documentation

- [Get started](https://renerocksai.github.io/omajot/get-started.html)
- [Using omajot](https://renerocksai.github.io/omajot/using.html)
- [Command line](https://renerocksai.github.io/omajot/cli.html)
- [Under the hood](https://renerocksai.github.io/omajot/under-the-hood.html)
- [DESIGN.md](DESIGN.md): the decisions and why.
- [docs/PROTOCOL.md](docs/PROTOCOL.md): the client protocol, the hub API and the core API.

## License

MIT. See [LICENSE](LICENSE).
