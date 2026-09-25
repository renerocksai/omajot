# Spike 0d — what the Wayland clipboard offers on paste

Date: 2026-09-25, Omarchy / Hyprland 0.56, Chromium 152, LibreOffice 26.8.
Method: a test page (heading, bold/italic/code/link, umlauts and emoji, nested
list, checkboxes, ordered list, quote, code block, table, one `data:` image and
one `file://` image). Copied with Ctrl+A / Ctrl+C, sent with `hyprctl`, then
inspected with `wl-paste --list-types` / `wl-paste -t <type>`. Firefox is not
installed, so it was not tested. The user's clipboard was saved before and restored after.

## Results

**Chromium, select + copy** → `text/html`, `text/plain` (+ chromium-internal types).
- HTML is a fragment (no `<html>`/`<meta charset>`), UTF-8, with **heavy inline
  `style="…"` noise** on every block element; the converter must ignore attributes.
- Checkboxes arrive as `<input type="checkbox" checked="">` → map to `- [x]` / `- [ ]`.
- `data:` images survive as-is; local images arrive as absolute `file://` URLs.
- No `image/*` type, even though the selection contains images.

**Chromium, "Copy image"** → `image/png`, `text/html` (`<img src=…>`), `text/x-moz-url`.
- `text/html` is listed **before** `image/png`, so the order of `--list-types` is
  not a preference order. We apply our own priority.

**LibreOffice Writer, select + copy** → `text/rtf`, `text/richtext`, `text/html`,
**`text/markdown`**, `text/plain;charset=utf-16`, `text/plain;charset=utf-8`, …
- `text/markdown` is good: headings, emphasis, code, links, nested lists,
  quote, fenced code, a GFM table, and images as `![](data:…)` / `![](file://…)`.
- LibreOffice's `text/html` contains **no `<img>`** at all, so markdown is strictly better here.
- RTF is offered, but only alongside HTML and markdown, which confirms we don't need an RTF parser.

## Resulting paste priority (replaces the list in DESIGN.md)

1. `image/*` → attachment (only present for real image copies, never for mixed selections).
2. `text/uri-list` → copy files in as attachments. *(Not tested here; no file manager copy was driven.)*
3. `text/markdown` → use as-is.
4. `text/html` → our converter.
5. `text/plain`.

For markdown and HTML alike, post-process image references: `data:` URIs are decoded
and `file://` paths are copied into `attachments/<sha256>.<ext>`. Remote `http(s)`
images are downloaded (decided).
