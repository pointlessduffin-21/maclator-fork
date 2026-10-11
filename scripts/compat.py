#!/usr/bin/env python3
"""Maintain the compatibility list from Maclator's own run records.

  scripts/compat.py import [path]   merge the launcher's compat.json into docs/compatibility.json
  scripts/compat.py markdown        regenerate the table region of docs/COMPATIBILITY.md (between the
                                    compat:start / compat:end markers) from docs/compatibility.json
"""
import json
import os
import plistlib
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIST = os.path.join(ROOT, "docs", "compatibility.json")
MARKDOWN = os.path.join(ROOT, "docs", "COMPATIBILITY.md")
SUPPORT = os.path.expanduser("~/Library/Application Support/Maclator")
GENERIC_NOTE = "Opened a window."

SECTIONS = [
    ("works", "Works", "The app starts and opens its window."),
    ("partial", "Partly works", "The app starts, but something breaks or is missing."),
    ("fails", "Doesn't run", "The app does not get as far as a usable window."),
    ("untested", "Not tried", "No result recorded yet."),
]


def load(path):
    with open(path) as f:
        return json.load(f)


def info_name(app_path):
    try:
        with open(os.path.join(app_path, "Contents", "Info.plist"), "rb") as f:
            info = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException):
        return None
    return info.get("CFBundleDisplayName") or info.get("CFBundleName")


def app_name(bundle_id):
    paths = []
    try:
        out = subprocess.run(["mdfind", "kMDItemCFBundleIdentifier == '%s'" % bundle_id],
                             capture_output=True, text=True).stdout
        paths += [p for p in out.splitlines() if p.endswith(".app")]
    except OSError:
        pass
    try:
        for p in load(os.path.join(SUPPORT, "added.json")):
            try:
                with open(os.path.join(p, "Contents", "Info.plist"), "rb") as f:
                    if plistlib.load(f).get("CFBundleIdentifier") == bundle_id:
                        paths.append(p)
            except (OSError, plistlib.InvalidFileException):
                pass
    except (OSError, ValueError):
        pass
    for p in paths:
        name = info_name(p)
        if name:
            return name
    return bundle_id


def cmd_import(path):
    path = path or os.path.join(SUPPORT, "compat.json")
    records = load(path)
    data = load(LIST)
    apps = {a["bundleID"]: a for a in data["apps"]}
    for bid, r in sorted(records.items()):
        verdict = r.get("verdict", "untested")
        tested = r.get("tested", "")
        note = (r.get("note") or "").strip()
        first = r.get("firstWindow")
        if first is not None:
            first = int(round(first))
        cur = apps.get(bid)
        if cur is None:
            cur = {"name": app_name(bid), "bundleID": bid, "verdict": verdict, "note": note, "tested": tested}
            if first is not None:
                cur["firstWindow"] = first
            data["apps"].append(cur)
            print("added   %s (%s): %s" % (cur["name"], bid, verdict))
            continue
        if tested < cur.get("tested", ""):
            print("kept    %s: bundled result is newer (%s)" % (cur["name"], cur["tested"]))
            continue
        new = dict(cur)
        new["verdict"] = verdict
        new["tested"] = tested
        if first is not None:
            new["firstWindow"] = first
        if not (note == GENERIC_NOTE and verdict == cur["verdict"]) and note:
            new["note"] = note
        changes = ["%s %r -> %r" % (k, cur.get(k), new.get(k)) for k in new if new.get(k) != cur.get(k)]
        if changes:
            cur.clear()
            cur.update(new)
            print("updated %s: %s" % (cur["name"], "; ".join(changes)))
        else:
            print("same    %s" % cur["name"])
    data["apps"].sort(key=lambda a: (a["name"].lower(), a["bundleID"]))
    with open(LIST, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def cell(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


START = "<!-- compat:start -->"
END = "<!-- compat:end -->"


def cmd_markdown():
    data = load(LIST)
    out = [
        "Generated from [compatibility.json](compatibility.json) by `scripts/compat.py markdown`; the launcher app "
        "reads the same file. Times are to the first window on a first launch with an empty translation cache.",
        "",
        "Recorded on: %s." % data["host"],
        "",
        "- **Works**: the app starts and opens its window; anything beyond that is in the notes.",
        "- **Partly works**: it starts, but something breaks or is missing (see the notes).",
        "- **Doesn't run**: it never reaches a usable window.",
        "- **Not tried**: no result recorded.",
    ]
    apps = sorted(data["apps"], key=lambda a: (a["name"].lower(), a["bundleID"]))
    for verdict, title, _ in SECTIONS:
        rows = [a for a in apps if a["verdict"] == verdict]
        if not rows:
            continue
        out += ["", "### %s (%d)" % (title, len(rows)), "",
                "| App | Bundle ID | First window | Tested | Notes |", "|---|---|---|---|---|"]
        for a in rows:
            fw = a.get("firstWindow")
            fw = "%d s" % round(fw) if fw is not None else ""
            out.append("| %s | `%s` | %s | %s | %s |" % (
                cell(a["name"]), a["bundleID"], fw, a.get("tested", ""), cell(a.get("note", ""))))
    region = START + "\n" + "\n".join(out) + "\n" + END
    try:
        with open(MARKDOWN) as f:
            page = f.read()
    except OSError:
        page = "# Compatibility list\n\n" + START + "\n" + END + "\n"
    if START in page and END in page and page.index(START) < page.index(END):
        page = page[:page.index(START)] + region + page[page.index(END) + len(END):]
    else:
        page = page.rstrip("\n") + "\n\n" + region + "\n"
    with open(MARKDOWN, "w") as f:
        f.write(page)
    print("wrote", os.path.relpath(MARKDOWN, ROOT))


def main():
    args = sys.argv[1:]
    if args[:1] == ["import"] and len(args) <= 2:
        cmd_import(args[1] if len(args) > 1 else None)
    elif args == ["markdown"]:
        cmd_markdown()
    else:
        sys.exit(__doc__)


main()
