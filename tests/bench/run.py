#!/usr/bin/env python3
"""Owl interpreter benchmarks.

Runs every tests/bench/*.owl with bin/owl, checks its output against
tests/bench/expected/<name>.out (so a speedup never changes what owl
computes) and prints the best wall time of several runs, and, when perf is
installed, the user-space instructions executed (in millions). Wall time on
a busy or frequency-scaling machine is noisy; the instruction count is
stable to well under 1%, so it is the number to steer by.

  python3 -I tests/bench/run.py               run all, compare to the baseline
  python3 -I tests/bench/run.py fib loop      run some
  python3 -I tests/bench/run.py --runs 10     more runs per benchmark
  python3 -I tests/bench/run.py --save        store these times as the baseline
  python3 -I tests/bench/run.py --record      (re)write the expected outputs
  python3 -I tests/bench/run.py --owl PATH    benchmark another owl binary

The baseline lives in tests/bench/baseline.json.
"""

import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OWL = os.path.join(ROOT, "bin", "owl")
EXPECTED = os.path.join(HERE, "expected")
BASELINE = os.path.join(HERE, "baseline.json")


PERF = shutil.which("perf")


def run_once(owl, path):
    env = dict(os.environ, OWL_BENCH_DIR=HERE)
    start = time.perf_counter()
    proc = subprocess.run([owl, "run", path], cwd=HERE, env=env,
                          capture_output=True, text=True)
    elapsed = time.perf_counter() - start
    return elapsed, proc.returncode, proc.stdout, proc.stderr


def instructions(owl, path):
    """User-space instructions of one run, or None without perf."""
    if not PERF:
        return None
    env = dict(os.environ, OWL_BENCH_DIR=HERE)
    proc = subprocess.run([PERF, "stat", "-x", ",", "-e", "instructions:u",
                           owl, "run", path], cwd=HERE, env=env,
                          capture_output=True, text=True)
    for line in proc.stderr.splitlines():
        parts = line.split(",")
        if len(parts) > 2 and parts[2].startswith("instructions"):
            try:
                return int(parts[0])
            except ValueError:
                return None
    return None


def main(argv):
    runs = 5
    owl = OWL
    save = record = False
    names = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--runs":
            i += 1
            runs = int(argv[i])
        elif a == "--owl":
            i += 1
            owl = os.path.abspath(argv[i])
        elif a == "--save":
            save = True
        elif a == "--record":
            record = True
        else:
            names.append(a)
        i += 1
    if not names:
        names = sorted(f[:-4] for f in os.listdir(HERE) if f.endswith(".owl"))

    baseline = {}
    if os.path.exists(BASELINE):
        with open(BASELINE) as f:
            baseline = json.load(f)

    os.makedirs(EXPECTED, exist_ok=True)
    results = {}
    failed = False
    total = base_total = 0.0
    insns = base_insns = 0
    print(f"{'bench':<12}{'best':>9}{'base':>9}{'speedup':>9}"
          f"{'Minsn':>10}{'base':>10}{'ratio':>8}")
    for name in names:
        path = os.path.join(HERE, name + ".owl")
        best = None
        out = ""
        for _ in range(runs):
            elapsed, code, stdout, stderr = run_once(owl, path)
            if code != 0:
                print(f"{name}: exit {code}\n{stderr}")
                failed = True
                break
            out = stdout
            best = elapsed if best is None else min(best, elapsed)
        if best is None:
            continue
        exp_path = os.path.join(EXPECTED, name + ".out")
        if record or not os.path.exists(exp_path):
            with open(exp_path, "w") as f:
                f.write(out)
        else:
            with open(exp_path) as f:
                want = f.read()
            if want != out:
                print(f"{name}: OUTPUT CHANGED\n  want: {want!r}\n  got:  {out!r}")
                failed = True
        ins = instructions(owl, path)
        results[name] = best
        if ins is not None:
            results[name + ":insn"] = ins
        base = baseline.get(name)
        base_ins = baseline.get(name + ":insn")
        total += best
        line = f"{name:<12}{best:>8.3f}s"
        if base:
            base_total += base
            line += f"{base:>8.3f}s{base / best:>8.2f}x"
        else:
            line += f"{'-':>9}{'-':>9}"
        if ins is not None:
            line += f"{ins / 1e6:>10.1f}"
            if base_ins:
                insns += ins
                base_insns += base_ins
                line += f"{base_ins / 1e6:>10.1f}{base_ins / ins:>7.2f}x"
        print(line)
    if base_total > 0:
        line = f"{'total':<12}{total:>8.3f}s{base_total:>8.3f}s{base_total / total:>8.2f}x"
        if base_insns:
            line += f"{insns / 1e6:>10.1f}{base_insns / 1e6:>10.1f}{base_insns / insns:>7.2f}x"
        print(line)
    if save and not failed:
        baseline.update(results)
        with open(BASELINE, "w") as f:
            json.dump(baseline, f, indent=2, sort_keys=True)
            f.write("\n")
        print("baseline saved")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
