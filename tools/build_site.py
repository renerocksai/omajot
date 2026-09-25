#!/usr/bin/env python3
"""Build omajot's GitHub Pages site into _site/.

    python3 tools/build_site.py            # build and check
    python3 -m http.server -d _site 8000   # preview at http://127.0.0.1:8000

Pages are HTML fragments in site/pages/ with a JSON header comment; the shared
shell is site/template.html. Numbers are not typed by hand: the build measures
web/dist/core.wasm and reads limits straight from the Zig sources, so the site
cannot drift from the code. Placeholders:

    {{wasm_kib}} {{wasm_gzip_kib}}           size of web/dist/core.wasm
    {{bytes:FILE:NAME}} {{ms:FILE:NAME}} {{num:FILE:NAME}}
                                             `pub const NAME` or `.NAME = …` in FILE
    {{qr_terminal}}                          site/assets/qr-terminal.txt, escaped
    {{shot:NAME:ALT}}                        site/assets/shots/NAME-{light,dark}.webp

Every local link, image and #anchor is checked; a broken one fails the build.
"""
import gzip
import html
import json
import re
import shutil
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "site"
OUT = ROOT / "_site"
REPO = "https://github.com/renerocksai/omajot"
# Where GitHub Pages serves the site (custom domain); link previews need absolute URLs.
SITE_URL = "https://renerocks.ai/omajot/"
ORDER = ["index", "get-started", "using", "cli", "under-the-hood"]


def zig_value(file, name):
    """Evaluate a simple integer constant (`16 << 20`, `120_000`, `1 << 20`)."""
    source = (ROOT / file).read_text()
    match = (re.search(rf"pub const {re.escape(name)}(?::\s*\w+)?\s*=\s*([^;]+);", source)
             or re.search(rf"\.{re.escape(name)}\s*=\s*([^,\n]+),", source))
    if not match:
        sys.exit(f"build_site: {name} not found in {file}")
    expr = match.group(1).replace("_", "")
    if not re.fullmatch(r"[\d\s<>*+()-]+", expr):
        sys.exit(f"build_site: {file}:{name} = {match.group(1)!r} is not a simple number")
    return int(eval(expr))  # digits and operators only, checked above


def fmt_bytes(n):
    for unit, size in (("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10)):
        if n >= size and n % size == 0:
            return f"{n // size} {unit}"
    return f"{n:,} bytes".replace(",", " ")


def fmt_ms(n):
    return f"{n // 1000} s" if n % 1000 == 0 else f"{n} ms"


def qr_terminal():
    """`omajot qr` output: the text lines as terminal text, the code rows in a white box."""
    lines = (SITE / "assets/qr-terminal.txt").read_text().rstrip("\n").split("\n")
    blocks = set(" \u2580\u2584\u2588")
    rows = [i for i, line in enumerate(lines) if line and set(line) <= blocks and len(line) > 20]
    first, last = rows[0], rows[-1]
    text = lambda part: html.escape("\n".join(part).strip("\n"))
    return (text(lines[:first]) + '\n<span class="qr">' + html.escape("\n".join(lines[first:last + 1]))
            + "</span>\n" + text(lines[last + 1:]))


def shot(name, alt):
    light, dark = f"assets/shots/{name}-light.webp", f"assets/shots/{name}-dark.webp"
    # Light by default; site.js switches the source to the dark shot with the theme toggle.
    return (f'<picture><source srcset="{dark}" media="not all">'
            f'<img src="{light}" alt="{html.escape(alt)}" loading="lazy" data-light="{light}" data-dark="{dark}"></picture>')


def expand(text):
    wasm = (ROOT / "web/dist/core.wasm").read_bytes()
    values = {
        "wasm_kib": str(round(len(wasm) / 1024)),
        "wasm_gzip_kib": str(round(len(gzip.compress(wasm, 9)) / 1024)),
        "qr_terminal": qr_terminal(),
        "year": str(date.today().year),
    }

    def repl(match):
        key = match.group(1)
        if key in values:
            return values[key]
        kind, _, rest = key.partition(":")
        if kind == "shot":
            name, _, alt = rest.partition(":")
            return shot(name, alt)
        file, _, name = rest.rpartition(":")
        value = zig_value(file, name)
        return {"bytes": fmt_bytes, "ms": fmt_ms, "num": lambda v: f"{v:,}".replace(",", " ")}[kind](value)

    return re.sub(r"\{\{([^{}]+)\}\}", repl, text)


def main():
    template = (SITE / "template.html").read_text()
    pages = {}
    for name in ORDER:
        raw = (SITE / "pages" / f"{name}.html").read_text()
        header = re.match(r"<!--\s*(\{.*?\})\s*-->\s*", raw, re.S)
        pages[name] = (json.loads(header.group(1)), raw[header.end():])

    if OUT.exists():
        shutil.rmtree(OUT)
    shutil.copytree(SITE / "assets", OUT / "assets")
    (OUT / ".nojekyll").write_text("")

    for name, (meta, body) in pages.items():
        nav = "\n".join(
            f'<a href="{other}.html"{" aria-current=\"page\"" if other == name else ""}>{html.escape(pages[other][0]["nav"])}</a>'
            for other in ORDER)
        page = template
        url = SITE_URL + ("" if name == "index" else f"{name}.html")
        for key, value in (("title", meta["title"]), ("description", meta["description"]),
                           ("url", url), ("image", SITE_URL + "assets/og-card.jpg"),
                           ("nav", nav), ("page", name), ("repo", REPO), ("content", body)):
            page = page.replace("{{" + key + "}}", value)
        (OUT / f"{name}.html").write_text(expand(page))

    check()
    print(f"site built in {OUT.relative_to(ROOT)}/ ({len(pages)} pages)")


def check():
    """Fail on broken local links, images and anchors."""
    ids = {p.name: set(re.findall(r'\sid="([^"]+)"', p.read_text())) for p in OUT.glob("*.html")}
    problems = []
    for page in OUT.glob("*.html"):
        for attr, target in re.findall(r'\s(href|src|srcset|data-light|data-dark)="([^"]+)"', page.read_text()):
            if re.match(r"(https?:|mailto:|data:)", target):
                continue
            path, _, anchor = target.partition("#")
            file = path or page.name
            if path and not (OUT / path).exists():
                problems.append(f"{page.name}: missing {target}")
            elif anchor and file.endswith(".html") and anchor not in ids.get(file, set()):
                problems.append(f"{page.name}: missing anchor {target}")
    if problems:
        sys.exit("build_site: broken links\n  " + "\n  ".join(problems))


if __name__ == "__main__":
    main()
