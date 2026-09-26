#!/usr/bin/env python3
import subprocess, sys, os, json, time
from pathlib import Path

# The repo root, from the harness's own place: Tests/mutation/mutate.py.
# Usage: python3 Tests/mutation/mutate.py Tests/mutation/<spec>.json
ROOT = str(Path(__file__).resolve().parents[2])
SRC = os.path.join(ROOT, "Sources/DTRExp")

# Mutant spec: (id, file, old_substring, new_substring)
# old_substring MUST occur exactly once in the file.
MUTANTS = json.load(open(sys.argv[1]))

# Snapshot originals
files = sorted({m[1] for m in MUTANTS})
orig = {f: open(os.path.join(SRC, f)).read() for f in files}

def run_tests():
    r = subprocess.run(["swift", "test"], cwd=ROOT,
                       capture_output=True, text=True, timeout=300)
    return r.returncode == 0, r.stdout + r.stderr

# Baseline
ok, _ = run_tests()
if not ok:
    print("BASELINE FAILS — aborting"); sys.exit(1)
print("baseline green\n")

results = []
for mid, f, old, new in MUTANTS:
    path = os.path.join(SRC, f)
    content = orig[f]
    cnt = content.count(old)
    if cnt != 1:
        results.append((mid, f, "BADSPEC", f"count={cnt}"))
        print(f"[BADSPEC {cnt}] {mid}: {old!r}")
        continue
    mutated = content.replace(old, new, 1)
    open(path, "w").write(mutated)
    try:
        passed, out = run_tests()
    finally:
        open(path, "w").write(content)  # restore
    status = "SURVIVED" if passed else "killed"
    results.append((mid, f, status, ""))
    print(f"[{status}] {mid}")

# restore all (belt & suspenders)
for f in files:
    open(os.path.join(SRC, f), "w").write(orig[f])

print("\n==== SUMMARY ====")
killed = sum(1 for r in results if r[2] == "killed")
survived = [r for r in results if r[2] == "SURVIVED"]
bad = [r for r in results if r[2] == "BADSPEC"]
print(f"total={len(results)} killed={killed} survived={len(survived)} badspec={len(bad)}")
if survived:
    print("\nSURVIVORS:")
    for r in survived: print(f"  {r[0]}")
if bad:
    print("\nBADSPEC:")
    for r in bad: print(f"  {r[0]}: {r[3]}")
json.dump(results, open(sys.argv[1].replace(".json","_results.json"),"w"), indent=1)
