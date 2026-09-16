#!/usr/bin/env python3
"""Assemble corecredit.idlery.com and write the deployable bundle Netlify expects.

    python3 web/tools/build_site.py

The site is two things joined at the hip:

  * `web/src/` — the marketing home page, the 404 page, the images, and the Netlify
    `_redirects` / `_headers` files. Hand-authored, edited here.
  * `docs/legal-public/` — support.html, privacy.html and terms.html, *generated* by
    `docs/tools/render_legal_pages.py` from the JSON the app reads on device. Never edited by
    hand; `scripts/verify_repository.py` fails the build if they drift from their source.

This script copies both into `web/dist/` and zips that directory into
`web/corecredit-netlify.zip` — index.html at the root of the archive, no enclosing folder,
which is what Netlify's drag-and-drop deploy wants.

It refuses to write a bundle that would embarrass the site:

  * every page must be reachable, and every local `src`/`href` a page names must exist;
  * no page may load a script, an iframe, or anything at all from another origin, because the
    Privacy Policy those pages link to promises exactly that;
  * nothing from node_modules, no dotfile beyond the two Netlify ones, and no app source.

The archive is written with a fixed timestamp so that rebuilding unchanged content produces a
byte-identical file, and the commit that changes the ZIP is a commit that changed the site.
"""

import io
import os
import re
import shutil
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "web", "src")
LEGAL = os.path.join(ROOT, "docs", "legal-public")
DIST = os.path.join(ROOT, "web", "dist")
ZIP = os.path.join(ROOT, "web", "corecredit-netlify.zip")

LEGAL_PAGES = ("support.html", "privacy.html", "terms.html")

# Deterministic archive: same content in, same bytes out.
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)

APP_STORE_URL = "https://apps.apple.com/us/app/corecredit-core-return-ledger/id6802336957"

problems = []


def fail(message):
    problems.append(message)


def copy_tree(source, destination):
    for name in sorted(os.listdir(source)):
        if name in (".DS_Store",):
            continue
        s, d = os.path.join(source, name), os.path.join(destination, name)
        if os.path.isdir(s):
            os.makedirs(d, exist_ok=True)
            copy_tree(s, d)
        else:
            shutil.copy2(s, d)


def build_dist():
    if os.path.isdir(DIST):
        shutil.rmtree(DIST)
    os.makedirs(DIST)
    copy_tree(SRC, DIST)
    for name in LEGAL_PAGES:
        source = os.path.join(LEGAL, name)
        if not os.path.exists(source):
            fail("docs/legal-public/%s is missing — run docs/tools/render_legal_pages.py" % name)
            continue
        shutil.copy2(source, os.path.join(DIST, name))


def relative_files():
    out = []
    for folder, _, names in os.walk(DIST):
        for name in sorted(names):
            full = os.path.join(folder, name)
            out.append(os.path.relpath(full, DIST).replace(os.sep, "/"))
    return sorted(out)


# ----------------------------------------------------------------------------- checks

EXTERNAL = re.compile(r"""(?:src|href)\s*=\s*["'](https?:)?//([^"'/]+)""", re.I)
LOCAL_REF = re.compile(r"""(?:src|href)\s*=\s*["']([^"':#][^"'#]*)""", re.I)
BANNED_TAGS = ("<script", "<iframe", "<object", "<embed", "@import")

# The one origin a page is allowed to point at, and only as a link a person clicks.
ALLOWED_LINK_HOSTS = {"apps.apple.com", "corecredit.idlery.com", "www.sitemaps.org",
                      "www.w3.org"}


def check_pages(files):
    pages = [f for f in files if f.endswith(".html")]
    if "index.html" not in pages:
        fail("index.html is not at the root of the bundle")

    for page in pages:
        text = io.open(os.path.join(DIST, page), encoding="utf-8").read()
        lowered = text.lower()

        for tag in BANNED_TAGS:
            if tag in lowered:
                fail("%s contains %r — the site carries no script and no embedded frame" % (page, tag))

        for _, host in EXTERNAL.findall(text):
            if host.lower() not in ALLOWED_LINK_HOSTS:
                fail("%s points at %s — every asset must be served from this site" % (page, host))

        # Images and stylesheets must be local. A link to another origin is fine, and so is a
        # canonical URL, which is metadata rather than a fetch; a *loaded* resource from another
        # origin is not, because it would leak a visitor's IP address to a third party.
        for match in re.finditer(r"<(?:img|link|source)\b[^>]*>", text, re.I):
            tag = match.group(0)
            rel = re.search(r"""rel\s*=\s*["']([^"']+)""", tag, re.I)
            if rel and rel.group(1).strip().lower() in ("canonical", "alternate", "me"):
                continue
            for attr in re.findall(r"""(?:src|href|srcset)\s*=\s*["']([^"']+)""", tag, re.I):
                if attr.startswith("http") or attr.startswith("//"):
                    fail("%s loads %s from another origin" % (page, attr))

        for ref in LOCAL_REF.findall(text):
            ref = ref.split("?")[0].strip()
            if not ref or ref.startswith("mailto:") or ref.startswith("http") or ref.startswith("//"):
                continue
            if ref in ("./",):
                continue
            target = ref[2:] if ref.startswith("./") else ref.lstrip("/")
            if target in files:
                continue
            if target + ".html" in files:      # /support -> support.html, via _redirects
                continue
            fail("%s links to %r, which the bundle does not contain" % (page, ref))

    # Every download link has to be the real one.
    home = io.open(os.path.join(DIST, "index.html"), encoding="utf-8").read()
    store_links = re.findall(r"""href=["'](https://apps\.apple\.com[^"']*)""", home)
    if not store_links:
        fail("index.html has no App Store link")
    for link in store_links:
        if link != APP_STORE_URL:
            fail("index.html links to %s, not the App Store URL for this app" % link)
    return pages, store_links


def check_contents(files):
    if any("node_modules/" in f for f in files):
        fail("the bundle contains node_modules")
    for f in files:
        name = os.path.basename(f)
        if name.startswith(".") and name not in ("_redirects", "_headers"):
            fail("the bundle contains the dotfile %s" % f)
        if name in ("_redirects", "_headers") and "/" in f:
            fail("%s must sit at the root of the bundle to take effect" % f)
    for required in ("_redirects", "_headers", "404.html", "robots.txt"):
        if required not in files:
            fail("the bundle is missing %s" % required)
    for name in LEGAL_PAGES:
        if name not in files:
            fail("the bundle is missing %s" % name)


def write_zip(files):
    if os.path.exists(ZIP):
        os.remove(ZIP)
    with zipfile.ZipFile(ZIP, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in files:
            info = zipfile.ZipInfo(name, date_time=ZIP_TIMESTAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            with io.open(os.path.join(DIST, name), "rb") as handle:
                archive.writestr(info, handle.read())


def main():
    build_dist()
    files = relative_files()
    check_contents(files)
    pages, store_links = check_pages(files)

    if problems:
        print("the site was not packaged:")
        for problem in problems:
            print("  - %s" % problem)
        return 1

    write_zip(files)

    print("web/dist/ (%d files, %d pages)" % (len(files), len(pages)))
    for name in files:
        size = os.path.getsize(os.path.join(DIST, name))
        print("  %-28s %8.1f KB" % (name, size / 1024.0))
    print("web/corecredit-netlify.zip  %.1f KB, %d App Store links, all pointing at id6802336957"
          % (os.path.getsize(ZIP) / 1024.0, len(store_links)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
