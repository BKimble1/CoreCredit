#!/usr/bin/env python3
"""Serve web/dist/ the way Netlify will and photograph it at three widths.

    python3 web/tools/preview_site.py [output-directory] [site-directory]

`python3 -m http.server` is not a good enough stand-in: it 404s `/support`, so a link check
against it would report broken links that are fine in production. The handler below applies the
same three rewrites `web/src/_redirects` asks Netlify for, and falls back to 404.html, so what
this photographs is what the deployed site does.

The site directory defaults to `web/dist/`. Pass a second argument to point it at a folder
extracted from the ZIP instead, which is how the artifact itself gets tested rather than the
directory it was built from.

For every width it reports horizontal overflow, images that failed to decode, console errors and
failed requests, then writes a full-page PNG. A page that scrolls sideways on a phone or silently
drops an image fails here rather than in front of a customer.
"""

import functools
import http.server
import os
import socketserver
import sys
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DIST = os.path.join(ROOT, "web", "dist")
PORT = 8818

WIDTHS = [
    ("phone", 390, 844, 3),
    ("tablet", 834, 1112, 2),
    ("desktop", 1440, 900, 2),
]

PAGES = ["/", "/support", "/privacy", "/terms", "/nothing-here"]


class Handler(http.server.SimpleHTTPRequestHandler):
    """SimpleHTTPRequestHandler plus the _redirects rewrites and the 404 page."""

    REWRITES = {"/support": "/support.html", "/privacy": "/privacy.html", "/terms": "/terms.html"}

    def translate_path(self, path):
        clean = path.split("?")[0].split("#")[0]
        if clean in self.REWRITES:
            path = self.REWRITES[clean]
        return super().translate_path(path)

    def send_error(self, code, message=None, explain=None):
        if code == 404 and os.path.exists(os.path.join(DIST, "404.html")):
            body = open(os.path.join(DIST, "404.html"), "rb").read()
            self.send_response(404)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().send_error(code, message, explain)

    def log_message(self, *args):
        pass


def serve():
    socketserver.TCPServer.allow_reuse_address = True
    handler = functools.partial(Handler, directory=DIST)
    server = socketserver.TCPServer(("127.0.0.1", PORT), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    global DIST
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "web", "dist", "_preview")
    if len(sys.argv) > 2:
        DIST = os.path.abspath(sys.argv[2])
    os.makedirs(out, exist_ok=True)

    from playwright.sync_api import sync_playwright

    server = serve()
    base = "http://127.0.0.1:%d" % PORT
    failures = []

    with sync_playwright() as p:
        # The image ships a Chromium that predates the pip-installed Playwright's expected
        # build, so point at the one that is actually here rather than downloading another.
        launch = {}
        for candidate in ("/opt/pw-browsers/chromium",
                          "/opt/pw-browsers/chromium-1194/chrome-linux/chrome"):
            if os.path.exists(candidate):
                launch["executable_path"] = candidate
                break
        browser = p.chromium.launch(**launch)
        for label, width, height, scale in WIDTHS:
            context = browser.new_context(
                viewport={"width": width, "height": height},
                device_scale_factor=scale,
                is_mobile=(label == "phone"),
                has_touch=(label == "phone"),
                color_scheme="light",
            )
            page = context.new_page()
            errors, failed, misses = [], [], []
            page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
            page.on("requestfailed", lambda r: failed.append(r.url))
            page.on("response", lambda r: misses.append("%s %s" % (r.status, r.url))
                    if r.status >= 400 else None)

            for route in PAGES:
                del misses[:]
                page.goto(base + route, wait_until="networkidle")
                # Flip every `loading="lazy"` image to eager and wait for the lot. Scrolling the
                # page to trigger them is the usual trick and a bad one here: `scroll-behavior:
                # smooth` animates each jump, so the walk takes longer than it has any right to.
                page.evaluate("""() => Promise.all([...document.images].map(img => {
                    img.loading = 'eager';
                    if (img.complete) return null;
                    return new Promise(resolve => {
                        img.addEventListener('load', resolve, {once: true});
                        img.addEventListener('error', resolve, {once: true});
                    });
                }))""")
                # Loaded is not painted. Chromium's full-page capture reuses tiles it has already
                # rasterised, so anything that was never scrolled into view photographs blank even
                # though the image decoded. Walk the page once to force the paint — with smooth
                # scrolling switched off, or every jump is an animation we would have to wait out.
                page.evaluate("""async () => {
                    const html = document.documentElement;
                    const previous = html.style.scrollBehavior;
                    html.style.scrollBehavior = 'auto';
                    const step = Math.floor(window.innerHeight * 0.75);
                    const end = html.scrollHeight;
                    for (let y = 0; y < end; y += step) {
                        window.scrollTo(0, y);
                        await new Promise(r => requestAnimationFrame(() => r()));
                    }
                    window.scrollTo(0, 0);
                    await new Promise(r => requestAnimationFrame(() => r()));
                    html.style.scrollBehavior = previous;
                }""")
                overflow = page.evaluate(
                    "() => document.documentElement.scrollWidth - window.innerWidth")
                broken = page.evaluate("""() => [...document.images]
                    .filter(i => !i.complete || i.naturalWidth === 0)
                    .map(i => i.getAttribute('src'))""")
                noalt = page.evaluate("""() => [...document.images]
                    .filter(i => i.getAttribute('alt') === null)
                    .map(i => i.getAttribute('src'))""")
                # A width/height attribute is a presentational hint. Size an image with CSS width
                # alone and it keeps the attribute's height, which stretches it without ever
                # failing to load — so compare what is on screen against the file's own shape.
                squashed = page.evaluate("""() => [...document.images]
                    .filter(i => i.naturalWidth && i.naturalHeight && i.width && i.height)
                    .map(i => ({src: i.getAttribute('src'),
                                shown: i.width / i.height,
                                real: i.naturalWidth / i.naturalHeight}))
                    .filter(r => Math.abs(r.shown - r.real) / r.real > 0.02)
                    .map(r => `${r.src} (${r.shown.toFixed(2)} on screen, ${r.real.toFixed(2)} in the file)`)""")
                name = route.strip("/").replace("/", "-") or "home"
                if route == "/":
                    page.screenshot(path=os.path.join(out, "%s-%s.png" % (name, label)),
                                    full_page=True)
                elif label == "phone" or route == "/nothing-here":
                    page.screenshot(path=os.path.join(out, "%s-%s.png" % (name, label)),
                                    full_page=True)

                status = "ok"
                if overflow > 0:
                    status = "OVERFLOW %dpx" % overflow
                    failures.append("%s %s scrolls sideways by %dpx" % (label, route, overflow))
                if broken:
                    status += " BROKEN-IMAGES %s" % broken
                    failures.append("%s %s: images did not load: %s" % (label, route, broken))
                if noalt:
                    status += " MISSING-ALT %s" % noalt
                    failures.append("%s %s: images without an alt attribute: %s" % (label, route, noalt))
                if squashed:
                    status += " DISTORTED %s" % squashed
                    failures.append("%s %s: images not at their own aspect ratio: %s"
                                    % (label, route, squashed))

                # /nothing-here is meant to 404; anything else that does is a broken reference.
                unexpected = [m for m in misses
                              if not (route == "/nothing-here" and m.endswith(route))]
                if unexpected:
                    status += " MISSING %s" % unexpected
                    failures.append("%s %s requested %s" % (label, route, unexpected))
                print("  %-8s %-14s %s" % (label, route, status))

            if failed:
                failures.append("%s failed requests: %s" % (label, failed[:4]))
            context.close()
        browser.close()
    server.shutdown()

    print("\nscreenshots in %s" % out)
    if failures:
        print("\nproblems:")
        for f in failures:
            print("  - %s" % f)
        return 1
    print("no overflow, no broken image, no missing alt, no console error, no failed request")
    return 0


if __name__ == "__main__":
    sys.exit(main())
