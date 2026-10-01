#!/usr/bin/env python3
"""Kotlin -> Flutter port tracker.  Run from the repo root:

  python3 tools/port_status.py               # PORT_STATUS.md dobara banata hai
  python3 tools/port_status.py --baseline    # sab .kt ka current hash "ported" maan leta hai (pehli baar)
  python3 tools/port_status.py --accept ItemSearchActivity.kt [...]
                                             # file Flutter mein port/update kar di -> hash save

Kaam:
  * kotlin_reference/main/*.kt scan karta hai
  * tools/port_map.json se Dart target + status (done/partial/todo/skip) leta hai
  * agar done/partial file ka .kt Android mein badal gaya (hash farq) => "CHANGED" flag
  * map mein na milne wali nayi .kt => "NEW" flag (port_map.json mein add karein)
"""
import hashlib, json, os, sys, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KT = os.path.join(ROOT, "kotlin_reference", "main")
MAP = os.path.join(ROOT, "tools", "port_map.json")
HASHES = os.path.join(ROOT, "tools", "ported_hashes.json")
OUT = os.path.join(ROOT, "PORT_STATUS.md")

PHASES = {
    0: "Foundation (models, DB, colors, widgets)", 1: "Products", 2: "Purchase", 3: "Sale",
    4: "Login, roles, settings, dashboard", 5: "Item search, rates, items, sale extras",
    6: "Parties (customer/supplier)", 7: "History", 8: "Cash, expense, accounts",
    9: "Reports & stock", 10: "Cloud sync (Firestore)", 11: "Backup", 12: "Print & scan",
    13: "Maintenance tools", 99: "Android-only (skip)",
}

def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()[:16]

def loc(path):
    with open(path, encoding="utf-8", errors="ignore") as f:
        return sum(1 for _ in f)

def load(p, default):
    return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else default

def main():
    files = sorted(f for f in os.listdir(KT) if f.endswith(".kt"))
    hashes = load(HASHES, {})
    if "--baseline" in sys.argv:
        hashes = {f: sha(os.path.join(KT, f)) for f in files}
        json.dump(hashes, open(HASHES, "w"), indent=1, sort_keys=True)
        print("baseline saved for", len(files), "files"); return
    if "--accept" in sys.argv:
        for f in sys.argv[sys.argv.index("--accept") + 1:]:
            hashes[f] = sha(os.path.join(KT, f)); print("accepted", f)
        json.dump(hashes, open(HASHES, "w"), indent=1, sort_keys=True)

    entries = load(MAP, [])
    known = {e["kotlin"] for e in entries}
    new = [f for f in files if f not in known]
    gone = [e["kotlin"] for e in entries if e["kotlin"] not in files]

    # Map mein likhi Dart files sach mein maujood hain? (done/partial entries ke liye)
    import re
    missing_dart = []
    for e in entries:
        if e["status"] not in ("done", "partial"): continue
        for dp in re.findall(r"lib/[\w/.\-]+\.dart", e.get("dart") or ""):
            if not os.path.exists(dp): missing_dart.append((e["kotlin"], dp))

    tot = collections.Counter(); done = collections.Counter()
    by_phase = collections.defaultdict(list); changed = []
    for e in entries:
        p = os.path.join(KT, e["kotlin"])
        if not os.path.exists(p): continue
        n = loc(p); e["_loc"] = n
        if e["status"] == "skip": pass
        else:
            tot[e["phase"]] += n
            if e["status"] == "done": done[e["phase"]] += n
            elif e["status"] == "partial": done[e["phase"]] += n // 2
        if e["status"] in ("done", "partial") and hashes.get(e["kotlin"]) != sha(p):
            e["_changed"] = True; changed.append(e["kotlin"])
        by_phase[e["phase"]].append(e)

    T = sum(tot.values()); D = sum(done.values())
    L = ["# PORT_STATUS (auto-generated — edit mat karein)",
         "", "`python3 tools/port_status.py` chala kar dobara banayein.", "",
         f"**Overall (lines of Kotlin ke hisaab se): {100*D//max(T,1)}%**  ({D}/{T})", ""]
    if new:
        L += ["## ⚠ NEW Kotlin files (port_map.json mein add karein)", ""] + [f"- {f}" for f in new] + [""]
    if gone:
        L += ["## ⚠ Map mein hain magar kotlin_reference mein nahi", ""] + [f"- {f}" for f in gone] + [""]
    if missing_dart:
        L += ["## ⚠ Map mein Dart file likhi hai magar maujood nahi", ""] + [f"- {k} → {d}" for k, d in missing_dart] + [""]
    if changed:
        L += ["## 🔁 Android mein badli, Flutter update chahiye", ""] + [f"- {f} → {next(e['dart'] for e in entries if e['kotlin']==f)}" for f in changed] + [""]
    icon = {"done": "✅", "partial": "🟡", "todo": "⬜", "skip": "➖"}
    for ph in sorted(by_phase):
        pct = f" — {100*done[ph]//tot[ph]}%" if tot[ph] else ""
        L += [f"## Phase {ph}: {PHASES.get(ph,'')}{pct}", "", "| | Kotlin | LOC | Flutter | Note |", "|---|---|---|---|---|"]
        for e in by_phase[ph]:
            flag = " 🔁" if e.get("_changed") else ""
            L.append(f"| {icon[e['status']]} | {e['kotlin']}{flag} | {e['_loc']} | {e['dart'] or '—'} | {e['note']} |")
        L.append("")
    open(OUT, "w", encoding="utf-8").write("\n".join(L))
    print(f"PORT_STATUS.md updated — {100*D//max(T,1)}% | new:{len(new)} changed:{len(changed)} missing_dart:{len(missing_dart)}")

if __name__ == "__main__":
    main()
