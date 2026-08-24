#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys

HOME = os.path.expanduser("~")
XDG_DATA_HOME = os.environ.get("XDG_DATA_HOME", os.path.join(HOME, ".local", "share"))
DESKTOP_DIRS = [
    os.path.join(HOME, ".local", "share", "applications"),
    os.path.join(XDG_DATA_HOME, "applications"),
    "/usr/local/share/applications",
    "/usr/share/applications",
]

ALIASES = {
}

_NORM_ALIASES = {}


def run(cmd):
    return subprocess.run(cmd, text=True, capture_output=True)


def norm(s):
    return re.sub(r"[-_.\s]", "", (s or "")).lower()


def hint_to_str(h):
    if isinstance(h, dict):
        return h.get("value") or ""
    if isinstance(h, list):
        return h[0] if h else ""
    return h or ""


def find_desktop(name):
    if not name:
        return None
    candidates = [name]
    low = name.lower()
    if low != name:
        candidates.append(low)
    for c in candidates:
        base = c[:-8] if c.endswith(".desktop") else c
        fn = base + ".desktop"
        for d in DESKTOP_DIRS:
            p = os.path.join(d, fn)
            if os.path.isfile(p):
                return p
    return None


def desktop_id_from_path(path):
    base = os.path.basename(path)
    return base[:-8] if base.endswith(".desktop") else base


def parse_wmclass(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    in_main = False
    wmclass = None
    for ln in lines:
        s = ln.strip()
        if s.startswith("["):
            in_main = (s == "[Desktop Entry]")
            continue
        if not in_main:
            continue
        if s.startswith("StartupWMClass="):
            wmclass = s.split("=", 1)[1]
    return wmclass


def notification(nid):
    r = run(["makoctl", "list", "-j"])
    try:
        data = json.loads(r.stdout or "[]")
    except json.JSONDecodeError:
        return {}
    for n in data:
        if str(n.get("id")) == str(nid):
            return n
    return {}


def windows():
    r = run(["niri", "msg", "-j", "windows"])
    try:
        return json.loads(r.stdout or "[]")
    except json.JSONDecodeError:
        return []


def focus_window(win_id):
    run(["niri", "msg", "action", "focus-window", "--id", str(win_id)])


def launch_by_id(desktop_id):
    if not desktop_id:
        return False
    run(["gtk-launch", desktop_id])
    return True


def build_keys(desktop_entry, app_name):
    keys = []
    for k in (desktop_entry, app_name):
        if k and k not in keys:
            keys.append(k)

    path = find_desktop(desktop_entry) or find_desktop(app_name)
    wmclass = parse_wmclass(path) if path else None
    if wmclass and wmclass not in keys:
        keys.insert(0, wmclass)

    if _NORM_ALIASES:
        for k in list(keys):
            mapped = _NORM_ALIASES.get(norm(k))
            if mapped and mapped not in keys:
                keys.insert(0, mapped)

    return keys, path


def pick_window(keys):
    best = None
    for w in windows():
        aid = w.get("app_id") or ""
        n_aid = norm(aid)
        if not n_aid:
            continue
        score = 0
        for k in keys:
            nk = norm(k)
            if nk and n_aid == nk:
                score = 100
                break
        if score == 0:
            for k in keys:
                nk = norm(k)
                if nk and (nk in n_aid or n_aid in nk):
                    score = 50
                    break
        if score > 0:
            ft = ((w.get("focus_timestamp") or {}).get("secs")) or 0
            if best is None or score > best[0] or (score == best[0] and ft > best[1]):
                best = (score, ft, w.get("id"))
    return best


def main():
    _NORM_ALIASES.update({norm(k): v for k, v in ALIASES.items()})

    args = sys.argv[1:]
    focus_only = False
    nid = ""
    for a in args:
        if a == "--focus-only":
            focus_only = True
        elif not nid:
            nid = a

    n = notification(nid)
    app_name = (n.get("app_name") or n.get("app-name") or "").strip()
    desktop_entry = (n.get("desktop_entry") or "").strip()
    if not desktop_entry:
        desktop_entry = (hint_to_str((n.get("hints") or {}).get("desktop-entry")) or "").strip()

    keys, path = build_keys(desktop_entry, app_name)
    best = pick_window(keys)

    if best is not None:
        focus_window(best[2])
    elif not focus_only:
        launched = False
        if path:
            launched = launch_by_id(desktop_id_from_path(path))
        elif desktop_entry:
            base = desktop_entry[:-8] if desktop_entry.endswith(".desktop") else desktop_entry
            launched = launch_by_id(base)
        elif app_name:
            launched = launch_by_id(app_name)
        _ = launched

    if nid and not focus_only:
        run(["makoctl", "dismiss", "-n", str(nid)])


if __name__ == "__main__":
    main()
