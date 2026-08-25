#!/usr/bin/env python3
"""Repository invariants that a compiler cannot check and a test bundle cannot see.

    python3 scripts/verify_repository.py

Every check here guards something that fails **silently** — no crash, no warning, no red test —
and would only be noticed by a person looking at the right screen at the right moment, or by App
Review. Each one exists because the failure it catches actually happened, or came close to.

Runs on any machine with Python 3 and no other dependency, so it gates the same way on a Mac
build agent as it does on the Windows box this repository is authored on.

Exit code 0 = every invariant holds. Non-zero = at least one is broken, with the reason.
"""

import io
import json
import os
import plistlib
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Named rather than written inline: ten of this repository's Swift files are still CRLF, and the
# checks below quote Swift's own triple-quote delimiter. Both are miserable to read as escapes
# buried in a regex, and easy to mangle when this file is edited by a script rather than by hand.
LF = chr(10)
CRLF = chr(13) + LF
QUOTE3 = chr(34) * 3
TRIPLE_QUOTE_AT_END = QUOTE3 + r"\s*$"
TRIPLE_QUOTE_AT_START = r"^\s*" + QUOTE3

FAILURES = []
NOTES = []


def fail(check, message):
    FAILURES.append("%s: %s" % (check, message))


def note(message):
    NOTES.append(message)


def read(*parts):
    with io.open(os.path.join(ROOT, *parts), encoding="utf-8", newline="") as handle:
        return handle.read()


def swift_sources(*roots):
    for root in roots:
        for base, _, files in os.walk(os.path.join(ROOT, root)):
            for name in sorted(files):
                if name.endswith(".swift"):
                    yield os.path.join(base, name)


# --------------------------------------------------------------------------- 1. identifier mirror

APP_IDENTIFIERS = os.path.join("CoreCredit", "Components", "AccessibilityIdentifiers.swift")
MIRROR_IDENTIFIERS = os.path.join("CoreCreditUITests", "UITestSupport.swift")

# Members the app declares that the UI-test target deliberately does not mirror, because no test
# queries them yet. Listed explicitly so "not mirrored" is always a decision, never an oversight.
UNMIRRORED_BY_DESIGN = {
    "Detail.binTag", "Detail.exportPacket", "Returns.editReference",
    "Settings.exportCSV", "Settings.subscription", "Settings.subscriptionScreen",
}

# Helpers that exist only in the mirror, because the app builds these identifiers with a function
# and a test matches on the prefix instead of reconstructing a runtime UUID.
MIRROR_ONLY_BY_DESIGN = {"Cores.rowPrefix", "ScanReview.rowPrefix"}


def parse_identifiers(path, root_enum):
    """{"Group.member": "value"} for every `static let` inside a nested enum of `root_enum`.

    Brace-depth tracked rather than indentation-matched. Both files declare other top-level enums
    after the identifier enum — `LaunchFlag`, `SystemLaunchArgument` — and an indentation-only
    parser walks straight out of the root and attributes their members to whichever nested group
    happened to be open last."""
    text = read(path).replace("\r\n", "\n")
    found = {}
    depth = 0
    root_depth = None
    group = None
    group_depth = None

    for line in text.split("\n"):
        code = line.split("//")[0]

        if root_depth is None and re.match(r"^enum %s\s*\{" % root_enum, code):
            root_depth = depth
            depth += code.count("{") - code.count("}")
            continue

        if root_depth is not None:
            nested = re.match(r"^\s*enum (\w+)\s*\{", code)
            if nested and group is None:
                group = nested.group(1)
                group_depth = depth
            elif group is not None:
                member = re.match(r'^\s*static let (\w+)\s*=\s*"([^"]*)"', code)
                if member:
                    found[group + "." + member.group(1)] = member.group(2)

        depth += code.count("{") - code.count("}")

        if group is not None and depth <= group_depth:
            group = None
            group_depth = None
        if root_depth is not None and depth <= root_depth:
            break

    return found


def check_identifier_mirror():
    """The UI-test bundle runs out of process and cannot import the app module, so
    `CoreCreditUITests/UITestSupport.swift` carries a hand-copied duplicate of every `A11y` string.
    Renaming one in the app does not fail to compile — it produces a query that never resolves, and
    a UI test that times out with a confusing message. This is the only thing that can see both."""
    app = parse_identifiers(APP_IDENTIFIERS, "A11y")
    mirror = parse_identifiers(MIRROR_IDENTIFIERS, "A11yID")

    if not app or not mirror:
        fail("identifier-mirror", "could not parse identifiers (app=%d, mirror=%d)"
             % (len(app), len(mirror)))
        return

    for key, value in sorted(mirror.items()):
        if key in MIRROR_ONLY_BY_DESIGN:
            continue
        if key not in app:
            fail("identifier-mirror",
                 "the UI tests mirror A11yID.%s = %r, which the app does not declare" % (key, value))
        elif app[key] != value:
            fail("identifier-mirror",
                 "A11y.%s is %r in the app but %r in the UI-test mirror" % (key, app[key], value))

    missing = sorted(set(app) - set(mirror) - UNMIRRORED_BY_DESIGN)
    if missing:
        fail("identifier-mirror",
             "the app declares identifiers the UI tests do not mirror, and they are not on the "
             "by-design list in this script: " + ", ".join(missing))

    note("identifier mirror: %d shared identifiers agree exactly" % len(set(app) & set(mirror)))


def check_identifier_references_resolve():
    """A reference to `A11y.Foo.bar` that does not exist is a compile error, but a reference in the
    *mirror* that has drifted is not. Both directions are checked from source."""
    app = parse_identifiers(APP_IDENTIFIERS, "A11y")
    mirror = parse_identifiers(MIRROR_IDENTIFIERS, "A11yID")
    # Function-built identifiers are legitimate and not `static let`s.
    functions = set(re.findall(r"static func (\w+)", read(APP_IDENTIFIERS)))
    mirror_functions = set(re.findall(r"static func (\w+)", read(MIRROR_IDENTIFIERS)))

    unresolved = set()
    for path in swift_sources("CoreCredit", "CoreCreditUITests", "CoreCreditTests"):
        if path.endswith("AccessibilityIdentifiers.swift"):
            continue
        text = io.open(path, encoding="utf-8", newline="").read()
        for enum, keys, funcs in (("A11y", app, functions), ("A11yID", mirror, mirror_functions)):
            for group, member in re.findall(r"\b%s\.(\w+)\.(\w+)" % enum, text):
                key = group + "." + member
                if key not in keys and member not in funcs:
                    unresolved.add("%s.%s" % (enum, key))
    if unresolved:
        fail("identifier-references", "unresolved: " + ", ".join(sorted(unresolved)))
    else:
        note("identifier references: every A11y/A11yID reference resolves")


# ------------------------------------------------------------------ 2. SwiftData model manifest

MANIFEST_PATH = os.path.join("scripts", "swiftdata-model-manifest.json")
MODELS_DIR = os.path.join("CoreCredit", "Models")


def parse_models():
    """{"CoreItem": {"id": "UUID", ...}} — the stored properties of every `@Model` class.

    Computed properties are skipped: they have a `{` on the declaration line and are not part of
    the persisted shape."""
    models = {}
    for name in sorted(os.listdir(os.path.join(ROOT, MODELS_DIR))):
        if not name.endswith(".swift"):
            continue
        text = read(MODELS_DIR, name).replace("\r\n", "\n")
        lines = text.split("\n")
        current = None
        depth_at_class = None
        depth = 0
        for index, line in enumerate(lines):
            code = line.split("//")[0]
            declaration = re.match(r"^(final )?class (\w+)\b", code)
            if declaration and index > 0 and "@Model" in lines[index - 1]:
                current = declaration.group(2)
                models[current] = {}
                depth_at_class = depth
            if current is not None:
                stored = re.match(r"^\s{4}(?:public\s+)?var (\w+)\s*:\s*([^={]+?)\s*(?:=|$)", code)
                if stored and "{" not in code:
                    models[current][stored.group(1)] = stored.group(2).strip()
            depth += code.count("{") - code.count("}")
            if current is not None and depth <= (depth_at_class or 0) and "}" in code:
                current = None
    return models


def check_model_manifest():
    """SwiftData migration guard.

    `CoreCreditSchemaV1/V2/V3` all return the *live* model types, so the versioned schemas describe
    identical entities and every migration stage is a structural no-op. That is safe only while
    every change is **additive** — SwiftData infers a purely additive change from the store's own
    entity hashes, so existing installs keep opening.

    It stops being safe the moment a property is renamed, retyped, removed, or made required. There
    is no automated way to notice that: the app compiles, the tests pass, and an existing install
    fails to open its store on a stranger's phone.

    So the persisted shape is pinned here. An additive change updates the manifest in the same
    commit and is fine. A non-additive one fails this check with instructions, and the historical
    schemas must be frozen into nested copies before it can proceed.
    """
    actual = parse_models()
    if not actual:
        fail("model-manifest", "no @Model classes were parsed out of %s" % MODELS_DIR)
        return

    manifest_file = os.path.join(ROOT, MANIFEST_PATH)
    if not os.path.exists(manifest_file):
        io.open(manifest_file, "w", encoding="utf-8", newline="\n").write(
            json.dumps(actual, indent=2, sort_keys=True) + "\n")
        note("model manifest: created at %s (%d models)" % (MANIFEST_PATH, len(actual)))
        return

    expected = json.load(io.open(manifest_file, encoding="utf-8"))

    for model in sorted(set(expected) - set(actual)):
        fail("model-manifest",
             "@Model %s was removed or renamed. That is NOT additive: freeze the historical "
             "schemas into nested model copies and add a real migration stage before doing this. "
             "See docs/CONTRACTS.md and docs/SCAN_CONTRACTS.md rule 8." % model)

    for model in sorted(set(actual) - set(expected)):
        note("model manifest: new @Model %s — additive, update %s in this commit"
             % (model, MANIFEST_PATH))

    for model in sorted(set(expected) & set(actual)):
        before, after = expected[model], actual[model]
        for prop in sorted(set(before) - set(after)):
            fail("model-manifest",
                 "%s.%s was removed or renamed (was %r). NOT additive — freeze the historical "
                 "schemas first." % (model, prop, before[prop]))
        for prop in sorted(set(before) & set(after)):
            if before[prop] != after[prop]:
                fail("model-manifest",
                     "%s.%s changed type from %r to %r. NOT additive — freeze the historical "
                     "schemas first." % (model, prop, before[prop], after[prop]))
        for prop in sorted(set(after) - set(before)):
            if not after[prop].endswith("?") and "=" not in after[prop]:
                note("model manifest: %s.%s is new and non-optional — it must have a default, or "
                     "existing stores will not open" % (model, prop))
            note("model manifest: %s.%s added (additive) — update %s in this commit"
                 % (model, prop, MANIFEST_PATH))

    note("model manifest: %d models, %d persisted properties checked"
         % (len(actual), sum(len(p) for p in actual.values())))


# ----------------------------------------------------------------------- 3. resource validation

def check_json_resources():
    checked = 0
    for relative in ("CoreCredit/Resources/Assets.xcassets",
                     "CoreCredit/Resources/Legal",
                     "StoreKit",
                     "scripts"):
        base = os.path.join(ROOT, relative)
        if not os.path.isdir(base):
            continue
        for current, _, files in os.walk(base):
            for name in files:
                if not name.endswith((".json", ".storekit")):
                    continue
                path = os.path.join(current, name)
                try:
                    json.load(io.open(path, encoding="utf-8"))
                    checked += 1
                except Exception as error:  # noqa: BLE001 - the message is the point
                    fail("json", "%s is not valid JSON: %s"
                         % (os.path.relpath(path, ROOT), error))
    note("json: %d resource files parse" % checked)


def check_plists():
    for name in ("CoreCredit-Info.plist", "CoreCreditQuickScanWidget-Info.plist"):
        path = os.path.join(ROOT, "Config", name)
        try:
            with io.open(path, "rb") as handle:
                plistlib.load(handle)
        except Exception as error:  # noqa: BLE001
            fail("plist", "%s did not parse: %s" % (name, error))
    note("plist: both Info.plists parse")


def check_launch_screen():
    """`INFOPLIST_KEY_UILaunchScreen_Generation` generates an *empty* UILaunchScreen dictionary and
    merges it on top of the partial Info.plist, silently replacing the real one. The only symptom
    is the app opening on a white flash again."""
    with io.open(os.path.join(ROOT, "Config", "CoreCredit-Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    launch = info.get("UILaunchScreen")
    if not isinstance(launch, dict) or not launch:
        fail("launch-screen", "UILaunchScreen is missing from Config/CoreCredit-Info.plist")
        return
    for key in ("UIColorName", "UIImageName"):
        if not launch.get(key):
            fail("launch-screen", "UILaunchScreen is missing %s" % key)

    project = read("CoreCredit.xcodeproj", "project.pbxproj")
    if "INFOPLIST_KEY_UILaunchScreen_Generation" in project:
        fail("launch-screen",
             "INFOPLIST_KEY_UILaunchScreen_Generation is set in project.pbxproj. It merges an "
             "empty UILaunchScreen dictionary over the real one — remove it.")

    for asset, kind in ((launch.get("UIColorName"), "colorset"),
                        (launch.get("UIImageName"), "imageset")):
        path = os.path.join(ROOT, "CoreCredit", "Resources", "Assets.xcassets",
                            "%s.%s" % (asset, kind), "Contents.json")
        if not os.path.exists(path):
            fail("launch-screen", "UILaunchScreen names %r but %s.%s is not in the asset catalog"
                 % (asset, asset, kind))
    note("launch screen: declared, both assets present, generation setting absent")


def check_privacy_manifest():
    path = os.path.join(ROOT, "CoreCredit", "Resources", "PrivacyInfo.xcprivacy")
    try:
        with io.open(path, "rb") as handle:
            manifest = plistlib.load(handle)
    except Exception as error:  # noqa: BLE001
        fail("privacy-manifest", "PrivacyInfo.xcprivacy did not parse: %s" % error)
        return

    if manifest.get("NSPrivacyTracking") is not False:
        fail("privacy-manifest", "NSPrivacyTracking must be false — docs/PRIVACY.md says so")
    if manifest.get("NSPrivacyTrackingDomains"):
        fail("privacy-manifest", "NSPrivacyTrackingDomains must be empty")
    if manifest.get("NSPrivacyCollectedDataTypes"):
        fail("privacy-manifest", "NSPrivacyCollectedDataTypes must be empty — the app collects "
                                 "nothing, and the policy published to the App Store says so")
    note("privacy manifest: no tracking, no tracking domains, no collected data types")


def check_storekit_matches_configuration():
    config = read("CoreCredit", "App", "AppConfiguration.swift")
    ids = re.findall(r'static let (?:monthly|annual)ProductID\s*=\s*"([^"]+)"', config)
    storekit = read("StoreKit", "CoreCredit.storekit")
    for product in ids:
        if product not in storekit:
            fail("storekit",
                 "%s is in AppConfiguration but not in StoreKit/CoreCredit.storekit. A product "
                 "identifier that does not exist is SILENT: StoreKit returns nothing and the "
                 "paywall shows its retry state." % product)
    note("storekit: %d product identifiers match the configuration" % len(ids))


def check_no_placeholders():
    """App Review rejects an unreachable support or privacy URL, and a stand-in is worse than a
    missing one because it looks deliberate."""
    banned = ("example.com", "example.org", "example.net", "support@example",
              "TO BE SUPPLIED", "TODO", "FIXME")
    allowed_paths = {
        # This file names the reserved hosts because it is the detector for them.
        os.path.join("CoreCredit", "App", "AppConfiguration.swift"),
        os.path.join("scripts", "verify_repository.py"),
    }
    for path in swift_sources("CoreCredit", "CoreCreditQuickScanWidget"):
        relative = os.path.relpath(path, ROOT)
        if relative in allowed_paths:
            continue
        text = io.open(path, encoding="utf-8", newline="").read()
        for token in banned:
            for line_number, line in enumerate(text.split("\n"), 1):
                if token in line and not line.strip().startswith(("//", "///", "*")):
                    fail("placeholders", "%s:%d contains %r" % (relative, line_number, token))

    for name in os.listdir(os.path.join(ROOT, "CoreCredit", "Resources", "Legal")):
        text = read("CoreCredit", "Resources", "Legal", name)
        for token in ("TO BE SUPPLIED", "example.com"):
            if token in text:
                fail("placeholders", "legal document %s contains %r" % (name, token))
    note("placeholders: no stand-in address or marker in shipping source or legal documents")


def check_published_pages_match_source():
    """The published Privacy Policy and Terms are generated from the JSON the app reads on device.
    A hand-edit to either copy would let the two say different things."""
    script = os.path.join(ROOT, "docs", "tools", "render_legal_pages.py")
    if not os.path.exists(script):
        fail("legal-pages", "docs/tools/render_legal_pages.py is missing")
        return

    before = {}
    output_dir = os.path.join(ROOT, "docs", "legal-public")
    for name in sorted(os.listdir(output_dir)):
        if name.endswith(".html"):
            before[name] = io.open(os.path.join(output_dir, name), encoding="utf-8").read()

    result = subprocess.run([sys.executable, script], capture_output=True, text=True, cwd=ROOT)
    if result.returncode != 0:
        fail("legal-pages", "render_legal_pages.py failed: %s" % result.stderr.strip()[:300])
        return

    for name, content in sorted(before.items()):
        now = io.open(os.path.join(output_dir, name), encoding="utf-8").read()
        if now != content:
            fail("legal-pages",
                 "docs/legal-public/%s does not match what the generator produces. Edit the JSON "
                 "in CoreCredit/Resources/Legal/ and re-run docs/tools/render_legal_pages.py — do "
                 "not edit the HTML by hand." % name)

    for name, content in sorted(before.items()):
        for tag in ("<script", "<iframe", "<img", "googleapis", "@import"):
            if tag in content.lower():
                fail("legal-pages", "%s contains %r — the pages must stay self-contained and "
                                    "tracker-free, which the Privacy Policy promises" % (name, tag))
    note("legal pages: %d generated pages match their source and carry no external resource"
         % len(before))


def check_banned_swift_constructs():
    patterns = [
        (r"\bfatalError\s*\(", "fatalError"),
        (r"\btry!\s", "try!"),
        (r"\bas!\s", "as!"),
    ]
    hits = 0
    for path in swift_sources("CoreCredit", "CoreCreditQuickScanWidget"):
        text = io.open(path, encoding="utf-8", newline="").read()
        for line_number, line in enumerate(text.split("\n"), 1):
            code = line.split("//")[0]
            for pattern, label in patterns:
                if re.search(pattern, code):
                    fail("banned-constructs", "%s:%d uses %s"
                         % (os.path.relpath(path, ROOT), line_number, label))
                    hits += 1
    if hits == 0:
        note("banned constructs: no fatalError, try!, or as! in shipping code")


# ------------------------------------------------------- 4. Swift Testing's sharp edges

# Public types Swift Testing puts in scope in any file that says `import Testing`. A name here
# that the app also declares is ambiguous at the use site, and the compiler says so in a way that
# takes a moment to read: "generic parameter 'AttachableValue' could not be inferred".
TESTING_MODULE_TYPES = {"Attachment", "Comment", "Issue", "Test", "Tag", "Confirmation",
                        "SourceLocation", "Trait"}

MACRO_CALL = re.compile(r"#(?:expect|require)\s*\(")


def _macro_call_spans(text):
    """Yields the balanced-paren span of every #expect/#require call."""
    for match in MACRO_CALL.finditer(text):
        index = text.index("(", match.start())
        depth, in_string = 0, False
        while index < len(text):
            char = text[index]
            if in_string:
                if char == "\\":
                    index += 2
                    continue
                if char == '"':
                    in_string = False
            elif char == '"':
                in_string = True
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        yield match.start(), text[match.start():index + 1]


def check_test_comment_literals():
    """A failure message built with `+` does not compile.

    Swift Testing's `Comment` is `ExpressibleByStringLiteral` and `ExpressibleByStringInterpolation`,
    so `"a"` and `"a \\(b)"` both convert. `"a " + "b"` does not: it is a function call returning
    `String`, and the error — *cannot convert value of type 'String' to expected argument type
    'Comment?'* — points at the message rather than at the concatenation.

    Wrap a long message in a multi-line literal with trailing backslashes instead. That is still a
    literal, and the backslash keeps the text on one line.
    """
    offenders = []
    for path in swift_sources("CoreCreditTests", "CoreCreditUITests"):
        text = io.open(path, encoding="utf-8", newline="").read().replace("\r\n", "\n")
        for offset, chunk in _macro_call_spans(text):
            if re.search(r'"\s*\+\s*"', chunk):
                line = text[:offset].count("\n") + 1
                offenders.append("%s:%d" % (os.path.relpath(path, ROOT), line))
    if offenders:
        fail("test-comments",
             "a #expect/#require message is built with `+`, which yields String and will not "
             "convert to Comment: " + ", ".join(offenders))
    else:
        note("test comments: every #expect/#require message is a literal, not a concatenation")


def check_testing_name_collisions():
    """An app type whose name Swift Testing also uses must be module-qualified in a test.

    `CoreCredit.Attachment` and `Testing.Attachment` are both in scope in a test file, so the bare
    name does not resolve. The compiler reports it as an inference failure on Testing's generic
    parameter, which does not obviously point at the app's own type.
    """
    app_types = set()
    for path in swift_sources("CoreCredit"):
        text = io.open(path, encoding="utf-8", newline="").read()
        for match in re.finditer(r"^(?:@\w+\s+)*(?:public\s+|final\s+)*(?:class|struct|enum)\s+(\w+)",
                                 text, re.M):
            app_types.add(match.group(1))

    collisions = sorted(app_types & TESTING_MODULE_TYPES)
    if not collisions:
        note("testing name collisions: no app type shares a name with Swift Testing")
        return

    offenders = []
    for path in swift_sources("CoreCreditTests", "CoreCreditUITests"):
        text = io.open(path, encoding="utf-8", newline="").read().replace("\r\n", "\n")
        if re.search(r"^import Testing$", text, re.M) is None:
            continue
        for number, line in enumerate(text.split("\n"), 1):
            code = line.split("//")[0]
            for name in collisions:
                if re.search(r"(?<![.\w])%s(?![\w])" % name, code):
                    offenders.append("%s:%d (%s)" % (os.path.relpath(path, ROOT), number, name))
    if offenders:
        fail("testing-collisions",
             "an app type that shares a name with Swift Testing is used unqualified in a test "
             "file; write CoreCredit.<Type>: " + ", ".join(offenders))
    else:
        note("testing name collisions: %s always module-qualified in tests"
             % ", ".join(collisions))


def check_multiline_string_literals():
    """A multi-line literal indented less than its closing delimiter does not compile.

    Swift measures indentation from the line carrying the closing delimiter and strips exactly
    that much from every content line. A content line with less than that is an error:
    *insufficient indentation of line in multi-line string literal*.

    This exists because sixteen of these were produced mechanically when the over-long #expect
    messages were re-wrapped. A generator that gets the padding wrong breaks every one of them at
    once, and the compiler is twenty minutes away on a build machine.
    """
    offenders, checked = [], 0
    for path in swift_sources("CoreCredit", "CoreCreditTests", "CoreCreditUITests"):
        source = io.open(path, encoding="utf-8", newline="").read()
        lines = source.replace(CRLF, LF).split(LF)
        index = 0
        while index < len(lines):
            if re.search(TRIPLE_QUOTE_AT_END, lines[index]):
                closer = index + 1
                while closer < len(lines) and not re.match(TRIPLE_QUOTE_AT_START, lines[closer]):
                    closer += 1
                if closer >= len(lines):
                    offenders.append("%s:%d (unterminated)"
                                     % (os.path.relpath(path, ROOT), index + 1))
                    break
                close_indent = len(lines[closer]) - len(lines[closer].lstrip())
                for number in range(index + 1, closer):
                    content = lines[number]
                    if content.strip() and len(content) - len(content.lstrip()) < close_indent:
                        offenders.append("%s:%d" % (os.path.relpath(path, ROOT), number + 1))
                checked += 1
                index = closer
            index += 1
    if offenders:
        fail("multiline-literals",
             "a multi-line string literal is indented less than its closing delimiter: "
             + ", ".join(offenders))
    else:
        note("multi-line literals: %d checked, all indented past their closing delimiter" % checked)


# Using one of these without importing its module is a compile error. SwiftUI and UIKit both
# re-export Foundation, so importing either satisfies the Foundation entries.
MODULE_SYMBOLS = {
    "SwiftData": [r"\bModelContext\b", r"\bModelContainer\b", r"\bFetchDescriptor\b",
                  r"\bModelConfiguration\b", r"@Model\b"],
    "Testing": [r"#expect\(", r"#require\(", r"@Test\b", r"@Suite\b"],
    "XCTest": [r"\bXCTAssert", r"\bXCUIApplication\b", r"\bXCTestCase\b", r"\bXCTContext\b"],
    "UIKit": [r"\bUIColor\b", r"\bUIImage\b", r"\bUIPasteboard\b", r"\bUIApplication\b"],
    "Foundation": [r"\bUserDefaults\b", r"\bJSONDecoder\b", r"\bJSONEncoder\b"],
}

IMPLIED_IMPORTS = {
    "SwiftUI": {"Foundation", "CoreGraphics", "UIKit"},
    "UIKit": {"Foundation", "CoreGraphics"},
    "XCTest": {"Foundation"},
    "SwiftData": {"Foundation"},
}


def check_module_imports():
    """Every file that uses a module's symbols imports that module."""
    offenders = []
    for path in swift_sources("CoreCredit", "CoreCreditTests", "CoreCreditUITests"):
        text = io.open(path, encoding="utf-8", newline="").read().replace(CRLF, LF)
        body = LF.join(line.split("//")[0] for line in text.split(LF))
        imports = set(re.findall(r"^\s*(?:@testable\s+)?import\s+(\w+)", text, re.M))
        for name in list(imports):
            imports |= IMPLIED_IMPORTS.get(name, set())
        for module, patterns in MODULE_SYMBOLS.items():
            if module in imports:
                continue
            for pattern in patterns:
                match = re.search(pattern, body)
                if match:
                    offenders.append("%s:%d uses %s without importing %s"
                                     % (os.path.relpath(path, ROOT),
                                        body[:match.start()].count(LF) + 1,
                                        match.group(0).strip(), module))
                    break
    if offenders:
        fail("module-imports", "; ".join(offenders))
    else:
        note("module imports: every file imports the modules whose symbols it uses")


def check_project_file():
    text = read("CoreCredit.xcodeproj", "project.pbxproj")
    if text.count("{") != text.count("}"):
        fail("pbxproj", "brace mismatch in project.pbxproj")
    for target in ("CoreCredit", "CoreCreditTests", "CoreCreditUITests",
                   "CoreCreditQuickScanWidget"):
        if "path = %s;" % target not in text:
            fail("pbxproj", "no synchronized root group for %s — new files in that folder would "
                            "not join the target" % target)
    note("pbxproj: parses, and all four targets use synchronized folder groups")


# ------------------------------------------------------- 17. releasing is never a side effect


def codemagic_workflow_keys():
    """The keys declared directly under each workflow in `codemagic.yaml`.

    A deliberately tiny reader rather than PyYAML: this script's contract is "Python 3 and no other
    dependency", and the shape being read is two levels of plain mapping keys. Comment lines are
    skipped, which matters — the file *talks about* `triggering:` in prose.
    """
    workflows = {}
    current = None
    inside = False

    for line in read("codemagic.yaml").replace(CRLF, LF).split(LF):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        if re.match(r"^workflows:\s*$", line):
            inside = True
            continue
        if not inside:
            continue
        if re.match(r"^[A-Za-z0-9_-]+:", line):
            # A new top-level key ends the workflows mapping.
            inside = False
            continue

        named = re.match(r"^  ([A-Za-z0-9_.-]+):\s*$", line)
        if named:
            current = named.group(1)
            workflows[current] = set()
            continue

        key = re.match(r"^    ([A-Za-z0-9_-]+):", line)
        if key and current is not None:
            workflows[current].add(key.group(1))

    return workflows


def check_release_is_never_a_side_effect():
    """No workflow may both start by itself and publish to App Store Connect.

    `corecredit-testflight` used to trigger on every push to `main`. That made *merging* a release
    action: a documentation fix, an audit, a typo — anything landing on the shipping branch sent a
    new build to TestFlight, advancing the build number for a release nobody decided to cut.

    Publishing has to be a decision somebody makes. Gating — building, testing — should be
    automatic. This check keeps the two apart, because the failure is entirely silent: re-adding a
    `triggering:` block breaks nothing, produces no warning, and is only noticed by testers
    receiving a build.
    """
    workflows = codemagic_workflow_keys()
    if not workflows:
        fail("release triggers",
             "no workflows parsed from codemagic.yaml — either the file or this reader changed "
             "shape, and the check is no longer guarding anything")
        return

    for name in sorted(workflows):
        keys = workflows[name]
        if "publishing" in keys and "triggering" in keys:
            fail("release triggers",
                 "workflow '%s' both triggers automatically and publishes. Merging would ship a "
                 "build as a side effect. Drop its `triggering:` block and start it by hand — see "
                 "docs/RELEASE.md." % name)

    publishing = sorted(name for name in workflows if "publishing" in workflows[name])
    if not publishing:
        fail("release triggers",
             "no workflow publishes at all — the release path is gone, not merely gated")
        return

    note("release triggers: %d workflows, %d publishing (%s), none self-triggering"
         % (len(workflows), len(publishing), ", ".join(publishing)))


# ------------------------------------ 18. UI tests drive a screen the way the screen is laid out

# Reaches that look backwards but are not, each for a stated reason. Anything *not* listed here is
# a control the test scrolls past and then reaches back for, which XCTest cannot recover from.
BACKWARD_REACH_ALLOWED = {
    # The vendor row sits high enough that typing into the amount field never scrolls it away.
    ("Editor.amount", "Editor.vendor"),
    # The vendor editor is a short sheet; Save is on screen without scrolling.
    ("Settings.vendorWindow", "Settings.vendorSave"),
    # Different onboarding *steps*, rendered one at a time. Source order says nothing about them.
    ("Onboarding.next", "Onboarding.shopName"),
}

INTERACTION_HELPERS = re.compile(r"\b(clearAndType|tapWhenHittable)\b")


def identifier_declaration_sites():
    """{"Editor.amount": ("CoreEditorView.swift", 384)} — where each identifier is applied.

    Line order inside one file approximates top-to-bottom order on screen, which is all this needs.
    """
    sites = {}
    for path in swift_sources("CoreCredit"):
        name = os.path.basename(path)
        text = io.open(path, encoding="utf-8", newline="").read().replace(CRLF, LF)
        for number, line in enumerate(text.split(LF), 1):
            if not re.search(r"accessibilityIdentifier|identifier:|fieldIdentifier:"
                             r"|disclosureIdentifier:", line):
                continue
            for match in re.finditer(r"A11y\.(\w+)\.(\w+)\b", line):
                sites.setdefault(match.group(1) + "." + match.group(2), (name, number))
    return sites


def check_ui_tests_run_top_to_bottom():
    """A UI test must not scroll past a control and then reach back up for it.

    `scrollUntilHittable` only swipes *up*, which reveals content below — so a control that has
    ended up above the viewport gets further away with every swipe, and the test fails as "exists
    but never became hittable" on something that was on screen moments earlier. It cannot swipe the
    other way either: every editor and review screen here is a sheet, and a downward drag on a
    sheet at the top of its scroll view dismisses it.

    This cost four full CI cycles to find twice — once on the core editor's expected-credit field,
    once on the credit sheet's memo number — at roughly forty minutes each. Two seconds here
    instead.
    """
    sites = identifier_declaration_sites()
    offenders = []

    for path in swift_sources("CoreCreditUITests"):
        name = os.path.basename(path)
        if name == "UITestSupport.swift":
            continue

        lines = io.open(path, encoding="utf-8", newline="").read().replace(CRLF, LF).split(LF)
        function = None
        sequence = []
        pending = None

        def inspect(owner, ordered):
            for (first, _), (second, where) in zip(ordered, ordered[1:]):
                if first not in sites or second not in sites:
                    continue
                first_file, first_line = sites[first]
                second_file, second_line = sites[second]
                # Different screens, or different identifier groups, say nothing about order.
                if first_file != second_file:
                    continue
                if first.split(".")[0] != second.split(".")[0]:
                    continue
                if second_line >= first_line:
                    continue
                if (first, second) in BACKWARD_REACH_ALLOWED:
                    continue
                offenders.append(
                    "%s:%d in %s() reaches %s (%s:%d) after %s (%s:%d) — %d lines back up the "
                    "screen" % (name, where, owner, second, second_file, second_line,
                                first, first_file, first_line, first_line - second_line)
                )

        for number, line in enumerate(lines, 1):
            declared = re.match(r"\s*(?:private )?func (\w+)", line)
            if declared:
                if function:
                    inspect(function, sequence)
                function, sequence = declared.group(1), []
            if INTERACTION_HELPERS.search(line):
                pending = number
            if pending is not None:
                used = re.search(r"A11yID\.(\w+)\.(\w+)\b", line)
                if used and number - pending <= 3:
                    sequence.append((used.group(1) + "." + used.group(2), number))
                    pending = None
        if function:
            inspect(function, sequence)

    if offenders:
        fail("ui-test order",
             "a UI test scrolls past a control and reaches back for it, which cannot succeed: "
             + "; ".join(offenders))
    else:
        note("ui test order: every typed and tapped sequence runs down the screen, never back up")


def check_notification_delegate_is_completion_handler_based():
    """The notification delegate must keep its completion-handler signatures, not the `async` ones.

    `UNUserNotificationCenterDelegate` is an Objective-C protocol whose two methods end in a
    completion handler. Swift offers an `async` spelling for each, and it looks like the better
    one. It is not: the compiler turns it into an `@objc` entry point that starts a task, runs the
    body, and then calls UserNotifications' completion handler from wherever that task finished —
    the cooperative pool. UIKit updates the window scene's snapshot and state-restoration archive
    inside that handler on the way in from a tap, and asserts it is on the main thread while doing
    it.

    Build 38 crashed on exactly that, 391ms into a launch from a tapped notification. Nothing about
    the `async` version reads as wrong, no test can see it, and the simulator does not reproduce
    it — which is what makes it worth a check here rather than a comment.
    """
    path = os.path.join("CoreCredit", "Services", "NotificationResponder.swift")
    try:
        source = read(path)
    except IOError:
        fail("notification delegate", "%s is missing" % path)
        return

    lines = source.replace(CRLF, LF).split(LF)
    signatures = []
    index = 0
    while index < len(lines):
        if "func userNotificationCenter(" in lines[index]:
            signature = []
            while index < len(lines):
                signature.append(lines[index].strip())
                if lines[index].rstrip().endswith("{"):
                    break
                index += 1
            signatures.append(" ".join(signature))
        index += 1

    # Two methods, no more and no fewer: `willPresent` and `didReceive`. A third would mean the
    # protocol grew a member this check has never seen and should be looked at by a person.
    if len(signatures) != 2:
        fail("notification delegate",
             "expected 2 `userNotificationCenter` implementations in %s, found %d — this check no "
             "longer knows what it is guarding" % (path, len(signatures)))
        return

    for signature in signatures:
        if "withCompletionHandler" not in signature:
            fail("notification delegate",
                 "`%s` does not take a completion handler. The `async` spelling of a "
                 "`UNUserNotificationCenterDelegate` method calls UIKit back off the main thread "
                 "and crashes on a notification tap." % signature)
        if ") async" in signature:
            fail("notification delegate",
                 "`%s` is declared `async`. Use the completion-handler form and call the handler "
                 "from the main actor." % signature)

    if not any(f.startswith("notification delegate") for f in FAILURES):
        note("notification delegate keeps its completion-handler signatures")


# ------------------------------------------- 20. permission primers keep their neutral wording

# The exact labels App Review rejected, and the exact spellings that must never come back.
#
# Deliberately three literal strings rather than a pattern over the word "allow". This repository
# is full of legitimate prose about allowing things: `.cameraDenied.explanation` tells a user to
# turn camera access back on, `NotificationAuthorizationStatus.provisional.explanation` describes
# iOS's own Allow affordance on a delivered notification, and several comments quote the system
# alert's "Don't Allow". A broad ban would fail on all of those, and a check that cries wolf is a
# check the next person deletes.
REJECTED_PRIMER_LABELS = ("Allow camera access", "Allow Camera", "Allow reminders")

# Every custom screen this app shows *before* an Apple permission alert, and the neutral action it
# must present. Both are `PrimaryButtonLabel`, which is the shipping button's visible text.
PERMISSION_PRIMERS = (
    (os.path.join("CoreCredit", "Features", "Capture", "ScanSheet.swift"),
     "the camera primer, shown for .cameraNotDetermined"),
    (os.path.join("CoreCredit", "Features", "Settings", "NotificationSettingsView.swift"),
     "the notification primer, shown for .notDetermined"),
)

NEUTRAL_PRIMER_ACTION = 'PrimaryButtonLabel("Continue"'


def check_permission_primer_labels():
    """A pre-permission screen may not imitate the system alert's affirmative choice.

    App Review rejected build 64 (version 1.0, iPad Air 11-inch (M3), 25 August 2026, submission
    c53826ac-ebd3-4cc4-9ef5-df185143a175) under guideline 5.1.1(iv): the camera primer's button
    said "Allow camera access". Apple asked for neutral wording such as Continue or Next.

    Nothing a compiler or a test bundle checks can see this. The label is a string, the app builds
    and runs perfectly with the rejected wording, and the cost of finding out is another review
    cycle. So it is pinned in three directions here: the rejected spellings cannot reappear in
    shipping code, each primer must still carry a neutral action, and the availability model's own
    `.cameraNotDetermined` copy must stay neutral too.
    """
    for path in swift_sources("CoreCredit", "CoreCreditQuickScanWidget"):
        relative = os.path.relpath(path, ROOT)
        text = io.open(path, encoding="utf-8", newline="").read().replace(CRLF, LF)
        for number, line in enumerate(text.split(LF), 1):
            # Comments are stripped, so the prose above each primer may name the rejected wording
            # in order to explain why it is banned.
            code = line.split("//")[0]
            for label in REJECTED_PRIMER_LABELS:
                if label in code:
                    fail("permission-primers",
                         "%s:%d ships the label %r. App Review rejected build 64 under guideline "
                         "5.1.1(iv) for exactly this: a custom screen shown before an Apple "
                         "permission alert may not imitate the affirmative choice inside it. Use "
                         "a neutral action such as Continue."
                         % (relative, number, label))

    for relative, description in PERMISSION_PRIMERS:
        try:
            text = read(relative).replace(CRLF, LF)
        except IOError:
            fail("permission-primers", "%s is missing — %s no longer has a home, and this check "
                                       "is no longer guarding anything" % (relative, description))
            continue
        if NEUTRAL_PRIMER_ACTION not in text:
            fail("permission-primers",
                 "%s no longer offers %s. A pre-permission screen still needs a neutral action, "
                 "and guideline 5.1.1(iv) is why it has to be that one."
                 % (relative, NEUTRAL_PRIMER_ACTION))

    # `ScannerAvailability` carries the same copy as a value, so a UI that renders `actionTitle`
    # instead of its own literal cannot reintroduce the rejected wording by the back door.
    availability = read("CoreCredit", "Services", "ScannerAvailability.swift").replace(CRLF, LF)
    arms = re.findall(r"case \.cameraNotDetermined:\s*\n\s*return " + chr(34) + r"([^" + chr(34)
                      + r"]*)" + chr(34), availability)
    if not arms:
        fail("permission-primers",
             "no `case .cameraNotDetermined:` returning a string literal was found in "
             "ScannerAvailability.swift — this check no longer knows what it is guarding")
    else:
        if "Continue" not in arms:
            fail("permission-primers",
                 "ScannerAvailability has no `.cameraNotDetermined` string equal to 'Continue'. "
                 "Its `actionTitle` is the neutral action a permission primer renders; found %r."
                 % (arms,))
        for value in arms:
            for label in REJECTED_PRIMER_LABELS:
                if label in value:
                    fail("permission-primers",
                         "ScannerAvailability's `.cameraNotDetermined` copy %r contains the "
                         "rejected label %r." % (value, label))

    if not any(f.startswith("permission-primers") for f in FAILURES):
        note("permission primers: %d pre-permission screens offer a neutral action, and none of "
             "%s appears in shipping code"
             % (len(PERMISSION_PRIMERS), " / ".join(repr(l) for l in REJECTED_PRIMER_LABELS)))


def main():
    check_identifier_mirror()
    check_identifier_references_resolve()
    check_model_manifest()
    check_json_resources()
    check_plists()
    check_launch_screen()
    check_privacy_manifest()
    check_storekit_matches_configuration()
    check_no_placeholders()
    check_published_pages_match_source()
    check_banned_swift_constructs()
    check_test_comment_literals()
    check_testing_name_collisions()
    check_multiline_string_literals()
    check_module_imports()
    check_project_file()
    check_release_is_never_a_side_effect()
    check_ui_tests_run_top_to_bottom()
    check_notification_delegate_is_completion_handler_based()
    check_permission_primer_labels()

    print("CoreCredit repository invariants")
    print("=" * 72)
    for message in NOTES:
        print("  ok    %s" % message)
    if FAILURES:
        print()
        for message in FAILURES:
            print("  FAIL  %s" % message)
        print()
        print("%d invariant(s) broken" % len(FAILURES))
        return 1
    print()
    print("all %d invariants hold" % len(NOTES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
