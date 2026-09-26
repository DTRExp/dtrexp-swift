#!/usr/bin/env python3
import subprocess, sys, os, json, time, signal
from pathlib import Path

# The repo root, from the harness's own place: Tests/mutation/mutate.py.
# Usage: python3 Tests/mutation/mutate.py Tests/mutation/<spec>.json
ROOT = str(Path(__file__).resolve().parents[2])
SRC = os.path.join(ROOT, "Sources/DTRExp")

# Mutant spec: (id, file, old_substring, new_substring)
# old_substring MUST occur exactly once in the file.
MUTANTS = json.load(open(sys.argv[1]))


def preflight():
    """Every mutant checked before a single build: its file is there, `old`
    occurs exactly once and `new` differs — so a spec typo costs a second
    rather than the whole pass. `--dry-run` stops here."""
    problems = []
    for mid, f, old, new in (m[:4] for m in MUTANTS):
        path = os.path.join(SRC, f)
        if not os.path.exists(path):
            problems.append(f"{mid}: no file {f}")
            continue
        count = open(path).read().count(old)
        if count != 1:
            problems.append(f"{mid}: {f} holds {count} copies of {old!r}, want exactly 1")
        if old == new:
            problems.append(f"{mid}: new is the same as old")
    if problems:
        print(f"PREFLIGHT FAILED — {len(problems)} problem(s):")
        for problem in problems:
            print(f"  {problem}")
        sys.exit(1)
    print(f"preflight ok — {len(MUTANTS)} mutants over {len({m[1] for m in MUTANTS})} files")
    if "--dry-run" in sys.argv[2:]:
        sys.exit(0)


preflight()

# Snapshot originals
files = sorted({m[1] for m in MUTANTS})
orig = {f: open(os.path.join(SRC, f)).read() for f in files}

def run_bounded(command, cwd, timeout):
    """(returncode, output, timed_out). A run past `timeout` takes its whole
    process group with it — a hung mutant's test helper otherwise stays behind
    holding the build lock, and the next run waits on it — and counts as a
    kill, as Stryker counts a timeout."""
    process = subprocess.Popen(command, cwd=cwd, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
        return process.returncode, output or "", False
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        output, _ = process.communicate()
        return 124, (output or "") + "\nTIMED OUT", True


def run_tests():
    code, output, _ = run_bounded(["swift", "test"], ROOT, 300)
    return code == 0, output

# Baseline
ok, _ = run_tests()
if not ok:
    print("BASELINE FAILS — aborting"); sys.exit(1)
print("baseline green\n")

results = []
for mid, f, old, new in (m[:4] for m in MUTANTS):
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
