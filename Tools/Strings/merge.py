#!/usr/bin/env python3
"""Merge Tools/Strings/*.json into WatchpostApp/Localizable.xcstrings and audit the Swift sources.

Usage (from the project root):
  Tools/Strings/merge.py            merge + write the catalog, then audit
  Tools/Strings/merge.py --check    audit only (nothing written); exit 1 when a key is missing
  Tools/Strings/merge.py --list     print every key the Swift sources use, with its zh-Hans

The catalog is generated, never edited by hand: change a JSON file and merge again.
Audit rules: every user-facing key used in Swift has a zh-Hans value; keys are never written
in Chinese (CJK in code is an error, except literals that only match server text); interpolated
literals resolve to a catalog key with %@ / %lld; format specifiers match between key and value.
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STRINGS_DIR = os.path.join(ROOT, "Tools", "Strings")
CATALOG = os.path.join(ROOT, "WatchpostApp", "Localizable.xcstrings")
INFO_CATALOG = os.path.join(ROOT, "WatchpostApp", "InfoPlist.xcstrings")
INFO_PLIST = os.path.join(ROOT, "WatchpostApp", "Info.plist")
APP_DIR = os.path.join(ROOT, "WatchpostApp")
LANG = "zh-Hans"

# The first string argument of these calls is a user-facing key.
CALLS = [
    r"String\(\s*localized\s*:", r"Text\(", r"Button\(", r"Label\(", r"Toggle\(", r"Section\(",
    r"Picker\(", r"DatePicker\(", r"TextField\(", r"SecureField\(", r"Link\(", r"Menu\(", r"ProgressView\(",
    r"LabeledContent\(", r"ContentUnavailableView\(", r"NSLocalizedString\(",
    r"LocalizedStringResource\(", r"LocalizedStringKey\(", r"UIAction\(", r"failureMessage\(",
    r"\.navigationTitle\(", r"\.navigationSubtitle\(", r"\.accessibilityLabel\(", r"\.accessibilityHint\(",
    r"\.accessibilityValue\(", r"\.alert\(", r"\.confirmationDialog\(", r"\.help\(",
]
LIT = r'"((?:[^"\\]|\\.)*)"'
KEY_RE = re.compile(r"(?<![\w.])(?:" + "|".join(CALLS) + r")\s*" + LIT, re.S)
# Both branches of a conditional label: .accessibilityLabel(isOn ? "On" : "Off")
TERNARY_RE = re.compile(r"\.accessibility(?:Label|Hint|Value)\(\s*[^()\"]*\?\s*" + LIT + r"\s*:\s*" + LIT)
# Named string arguments that are keys too (label:, prompt:, title:, message:, placeholder:).
NAMED_RE = re.compile(r"\b(?:label|prompt|title|message|placeholder)\s*:\s*" + LIT)
# String literals anywhere in the comment-stripped code.
ANY_LIT_RE = re.compile(LIT)
# Two or more words: prose, which only ever reaches the screen through a localizing parameter.
PROSE_RE = re.compile(r"^(?:[A-Za-z][A-Za-z'’]*[ ,:;!?…]+)+[A-Za-z][A-Za-z'’]*[.!?…]*$")


def is_prose(text):
    """Two or more words; a sentence end counts as a separator (so "eye.slash" is not prose)."""
    return bool(PROSE_RE.match(text.replace(". ", "  ").strip()))
# Contexts whose literals are never shown (or are localized by a function the scanner knows).
NOT_UI_RE = re.compile(
    r"(?:systemImage|systemName|tableName|bundle|forInfoDictionaryKey|rawValue|verbatim| localizedString|"
    r"Logger|os_log|print|debugPrint|fatalError|assertionFailure|precondition(?:Failure)?|assert)\s*[( :]\s*$"
    r"|(?:String|URL|NSNotification\.Name|UserDefaults|CharacterSet|Predicate|NSRegularExpression|"
    r"ProcessInfo|URLComponents)\(\s*(?:string|reflecting|named|contentsOf|url|label|format)?[^()]*[,:(]\s*$"
    r"|(?:Image|UIImage|UIImage\.named|LocalizedStringResource|NSLocalizedString|LocalizedStringKey)\(\s*$"
    r"|\b(?:case|\.self)\s*$")
# Literals that are only matched against something (server text), never shown.
MATCH_RE = re.compile(
    r"\b(?:contains|hasPrefix|hasSuffix|range\s*\(\s*of|split\s*\(\s*separator|"
    r"components\s*\(\s*separatedBy|replacingOccurrences\s*\(\s*of|target)\s*[(:]\s*" + LIT)
COMMENT_RE = re.compile(r"\bcomment\s*:\s*" + LIT)
CJK_RE = re.compile(r"[\u3000-\u303f\u3400-\u9fff\uf900-\ufaff]")
# A format specifier: optional position (%1$@), flags, width, length, conversion.
SPEC_RE = re.compile(r"%(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|z|t|j)?[@diouxXDOUeEfgGaAcCsSpF]")


def strip_comments(src):
    """Blank out // and /* */ comments (newlines kept) without touching string literals."""
    out = []
    stack = []  # ["code", paren_depth] | ["linec"] | ["blockc", depth] | ["str", triple]
    i, n = 0, len(src)
    while i < n:
        top = stack[-1] if stack else None
        mode = top[0] if top else "code"
        c = src[i]
        if mode == "code":
            if src.startswith("//", i):
                stack.append(["linec"]); out.append("  "); i += 2; continue
            if src.startswith("/*", i):
                stack.append(["blockc", 1]); out.append("  "); i += 2; continue
            if src.startswith('"""', i):
                stack.append(["str", True]); out.append('"""'); i += 3; continue
            if c == '"':
                stack.append(["str", False]); out.append('"'); i += 1; continue
            if top is not None:  # code inside \( … ) of a string literal
                if c == "(":
                    top[1] += 1
                elif c == ")":
                    if top[1] == 0:
                        stack.pop()
                    else:
                        top[1] -= 1
            out.append(c); i += 1; continue
        if mode == "linec":
            if c == "\n":
                stack.pop(); out.append("\n")
            else:
                out.append(" ")
            i += 1; continue
        if mode == "blockc":
            if src.startswith("/*", i):
                top[1] += 1; out.append("  "); i += 2; continue
            if src.startswith("*/", i):
                top[1] -= 1; out.append("  "); i += 2
                if top[1] == 0:
                    stack.pop()
                continue
            out.append(c if c == "\n" else " "); i += 1; continue
        # inside a string literal
        if c == "\\":
            out.append(src[i:i + 2]); i += 2; continue
        if src.startswith("\\(", i):
            stack.append(["code", 0]); out.append("\\("); i += 2; continue
        triple = top[1]
        if (triple and src.startswith('"""', i)) or (not triple and c == '"'):
            out.append('"""' if triple else '"'); i += 3 if triple else 1; stack.pop(); continue
        out.append(c); i += 1
    return "".join(out)


def unescape(lit):
    return (lit.replace("\\\\", "\x00").replace('\\"', '"').replace("\\n", "\n").replace("\\t", "\t")
            .replace("\x00", "\\"))


def split_interp(raw):
    """Split a literal body into (text parts, interpolation expressions), parentheses balanced."""
    texts, exprs, buf, i = [], [], "", 0
    while i < len(raw):
        if raw.startswith("\\(", i):
            texts.append(buf); buf = ""
            depth, j = 1, i + 2
            while j < len(raw) and depth:
                if raw[j] == "(":
                    depth += 1
                elif raw[j] == ")":
                    depth -= 1
                j += 1
            exprs.append(raw[i + 2:j - 1]); i = j
        elif raw[i] == "\\":
            buf += raw[i:i + 2]; i += 2
        else:
            buf += raw[i]; i += 1
    texts.append(buf)
    return texts, exprs


def interp_candidates(raw):
    """Catalog keys an interpolated literal can produce: each \\(…) is %@ (String) or %lld (Int)."""
    texts, _ = split_interp(raw)
    outs = [""]
    for text in texts[:-1]:
        outs = [o + text + spec for o in outs for spec in ("%@", "%lld")]
    return [unescape(o + texts[-1]) for o in outs]


def blank(code, pattern, group):
    """Replace a captured literal with spaces so later checks skip it; positions stay the same."""
    def repl(m):
        return m.group(0)[:m.start(group) - m.start()] + " " * len(m.group(group)) + m.group(0)[m.end(group) - m.start():]
    return pattern.sub(repl, code)


def swift_files():
    for path in sorted(glob.glob(os.path.join(APP_DIR, "**", "*.swift"), recursive=True)):
        if os.sep + ".airbuild" + os.sep in path:
            continue
        yield path


def scan(known):
    """Return (uses, notes, errors): uses = {key: [relpath:line, …]} for every key the code uses.
    `known` holds the catalog keys plus the plain keys found in an earlier pass."""
    uses, notes, errors = {}, [], []
    for path in swift_files():
        rel = os.path.relpath(path, ROOT)
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        code = strip_comments(src)
        line_of = lambda pos: code.count("\n", 0, pos) + 1
        first_spans = []
        for m in KEY_RE.finditer(code):
            first_spans.append(m.span(1))
            raw, where = m.group(1), "%s:%d" % (rel, line_of(m.start()))
            if "\\(" in raw:
                found = [k for k in interp_candidates(raw) if k in known]
                if not found:
                    notes.append("%s: interpolated literal without a catalog key: %s" % (where, " / ".join(interp_candidates(raw))))
                for k in found:
                    uses.setdefault(k, []).append(where)
                continue
            key = unescape(raw)
            if key.strip():
                uses.setdefault(key, []).append(where)
        for m in TERNARY_RE.finditer(code):
            for g in (1, 2):
                uses.setdefault(unescape(m.group(g)), []).append("%s:%d (conditional label)" % (rel, line_of(m.start(g))))
        for m in NAMED_RE.finditer(code):
            if any(a <= m.start(1) < b for a, b in first_spans):
                continue
            raw = m.group(1)
            if "\\(" in raw or not raw.strip():
                continue
            uses.setdefault(unescape(raw), []).append("%s:%d (%s:)" % (rel, line_of(m.start()), m.group(0).split(":")[0]))
        plain = blank(blank(code, COMMENT_RE, 1), MATCH_RE, 1)
        known_spans = (first_spans + [m.span(1) for m in NAMED_RE.finditer(code)]
                       + [m.span(g) for m in TERNARY_RE.finditer(code) for g in (1, 2)]
                       + [m.span(1) for m in COMMENT_RE.finditer(code)])
        line_start = 0
        for pos, line in enumerate(code.split("\n")):
            line_start += pos and len(code.split("\n")[pos - 1]) + 1
            for lit in ANY_LIT_RE.finditer(line):
                if not is_prose(unescape(lit.group(1))):
                    continue
                a, b = line_start + lit.start(1), line_start + lit.end(1)
                if any(x <= a < y for x, y in known_spans) or CJK_RE.search(lit.group(1)):
                    continue
                if NOT_UI_RE.search(line[:lit.start()]):
                    continue
                call = re.search(r"([\w.]+)\s*\(", line[:lit.start()][::-1])
                notes.append("%s:%d: prose literal outside a known localization call (%s): %s"
                             % (rel, pos + 1, call.group(1)[::-1] if call else "?", lit.group(0)))
        m = CJK_RE.search(plain)
        if m:
            errors.append("%s:%d: CJK character in code or a string literal (keys and code are English): %s"
                          % (rel, plain.count("\n", 0, m.start()) + 1, m.group(0)))
    return uses, notes, errors


def scan_all(tables):
    plain, _, _ = scan(set(tables))  # pass 1: plain keys
    return scan(set(tables) | set(plain))  # pass 2: interpolated literals find the pass-1 keys


def norm_spec(spec):
    return re.sub(r"^\d+\$", "%", spec)


def load_tables():
    """Read every Tools/Strings/*.json. A value is the zh-Hans string, or {"zh-Hans": …, "comment": …}."""
    tables, errors = {}, []
    for path in sorted(glob.glob(os.path.join(STRINGS_DIR, "*.json"))):
        name = os.path.basename(path)
        if name == "merge.py":
            continue
        target = INFO_CATALOG if name.startswith("InfoPlist.") else CATALOG
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
        except (ValueError, OSError) as exc:
            errors.append("{}: cannot read ({})".format(name, exc))
            continue
        if not isinstance(data, dict):
            errors.append("{}: not a flat JSON object".format(name))
            continue
        for key, value in data.items():
            comment = None
            if isinstance(value, dict):
                comment, value = value.get("comment"), value.get(LANG)
            if not isinstance(value, str) or not value.strip():
                errors.append("{}: {!r} has no {} value".format(name, key, LANG))
                continue
            if value != value.strip() and key == key.strip():
                errors.append("{}: {!r} value has leading or trailing whitespace".format(name, key))
            k_specs = sorted(norm_spec(s) for s in SPEC_RE.findall(key))
            v_specs = sorted(norm_spec(s) for s in SPEC_RE.findall(value))
            if k_specs != v_specs:
                errors.append("{}: {!r} placeholders differ (key {}, {} {})".format(name, key, k_specs, LANG, v_specs))
            if key in tables and (tables[key][0] != value or tables[key][3] != target):
                errors.append("{}: {!r} already has a different value or target in {}".format(name, key, tables[key][2]))
                continue
            tables.setdefault(key, (value, comment, name, target))
    return tables, errors


def write_catalog(tables, target):
    strings = {}
    for key in sorted(k for k in tables if tables[k][3] == target):
        value, comment = tables[key][:2]
        entry = {"extractionState": "manual",
                 "localizations": {LANG: {"stringUnit": {"state": "translated", "value": value}}}}
        if comment:
            entry["comment"] = comment
        strings[key] = entry
    doc = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    text = json.dumps(doc, indent=2, ensure_ascii=False, sort_keys=True)
    text = re.sub(r'^(\s*"[^"\\]*"):(\s)', r"\1 :\2", text, flags=re.M)  # Xcode's own spacing
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(text + "\n")
    return len(strings)


def main(argv):
    if "--help" in argv or "-h" in argv:
        print(__doc__.strip())
        return 0
    check, list_only = "--check" in argv, "--list" in argv
    tables, errors = load_tables()
    app_tables = {k: v for k, v in tables.items() if v[3] == CATALOG}
    uses, notes, cjk = scan_all(app_tables)
    missing = {k: v for k, v in uses.items() if k not in app_tables}
    unused = sorted(k for k in app_tables if k not in uses)
    if os.path.exists(INFO_PLIST):
        with open(INFO_PLIST, encoding="utf-8") as fh:
            plist_keys = set(re.findall(r"<key>([^<]+)</key>", fh.read()))
        for key, (_, _, name, _) in sorted(tables.items()):
            if name.startswith("InfoPlist.") and key not in plist_keys:
                errors.append("{}: {!r} is not a key of WatchpostApp/Info.plist".format(name, key))
    else:
        errors.append("WatchpostApp/Info.plist not found")
    if list_only:
        for key in sorted(uses):
            print("{:<60} {:<16} {}".format(key[:60], (app_tables.get(key) or ("—",))[0][:16], " ".join(uses[key][:3])))
    for err in errors + cjk:
        print("ERROR    " + err)
    for key, where in missing.items():
        print("MISSING  {!r}  ({})".format(key, ", ".join(where[:3])))
    for note in notes:
        print("REVIEW   " + note)
    for key in unused:
        print("unused   {!r}  ({})".format(key, app_tables[key][2]))
    if not list_only:
        if not errors and not check:
            for target in (CATALOG, INFO_CATALOG):
                n = write_catalog(tables, target)
                print("wrote {} keys to {}".format(n, os.path.relpath(target, ROOT)))
        print("{} keys in code, {} in tables, {} missing, {} unused".format(len(uses), len(app_tables), len(missing), len(unused)))
    return 1 if (errors or cjk or missing) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
