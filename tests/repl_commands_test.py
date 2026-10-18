"""The repl's commands (made with `interactive` in repl.owl) and the projects
owl knows across runs, through tests/repl_driver.owl: no app, so a command
that would read what is missing on a screen prints the screen's title and
is cancelled. The projects file goes to a scratch XDG_DATA_HOME. Needs
bin/owl; run from the repo root (make test_repl).
"""
import os, shutil, subprocess, sys

sys.dont_write_bytecode = True

ROOT = os.getcwd()
OWL = os.path.join(ROOT, "bin", "owl")
DRIVER = os.path.join(ROOT, "tests", "repl_driver.owl")
BASE = os.path.join(ROOT, "build", "owl_commands_test")
DATA = os.path.join(BASE, "data")
ENV = dict(os.environ, XDG_DATA_HOME=DATA)

failures = []
passed = 0


def expect(cond, msg):
    global passed
    if cond:
        passed += 1
    else:
        failures.append(msg)
        print("FAILED:", msg)


def repl(lines, cwd=BASE):
    r = subprocess.run([OWL, "run", DRIVER], cwd=cwd, env=ENV, input="\n".join(lines) + "\n",
                       capture_output=True, text=True, timeout=60)
    return r.stdout + r.stderr


def owl(*args):
    r = subprocess.run([OWL, *args], cwd=BASE, env=ENV, capture_output=True, text=True, timeout=60)
    return r.stdout + r.stderr


def commands():
    out = repl(["help"])
    expect("show <item> [module]" in out and "open-project <dir>" in out
           and "move-project <name> <dir>" in out,
           "help shows each command's parameters from its definition:\n" + out)
    out = repl(["fun double x:", "    * x 2", "", "show double", "drop"])
    expect("* x 2" in out, "typed parameters are bound:\n" + out)
    expect("screen: drop: which item of scratch?" in out and "cancelled" in out,
           "a missing parameter is read on a screen, and cancelling cancels:\n" + out)
    out = repl(["new", "docs"])
    expect("screen:" not in out and "scratch2" in out,
           "a parameter that may be left out is not read when typed:\n" + out)
    out = repl(["text extra words"])
    expect("use io" in out, "words past the parameters are ignored:\n" + out)


def failures_shown():
    out = repl(["run", "detach", "open nope", "show nothere", "open-project /tmp", "reload"])
    expect("╭─" not in out, "a command that fails shows no error window:\n" + out)
    for line in ["run needs a project: open-project, or new-project <dir> --gui",
                 "not attached to a program; attach <pid> first",
                 "no module nope here",
                 "no item nothere in scratch; items lists them",
                 "no project in /tmp (no project.owl)",
                 "scratch has no file to reload from; save writes one"]:
        expect(line in out, "the failure says what to do: " + line + "\n" + out)
    expect("details shows where" not in out, "a refusal is not a fault:\n" + out)
    out = repl(["forget-project nope", "details"])
    expect("details shows where" in out and "╭─" in out,
           "a fault says details shows where, and details shows the report:\n" + out)
    out = repl(["no-such-name 1"])
    expect("╭─" in out and "unbound symbol: no-such-name" in out,
           "code typed into a document still shows the whole report:\n" + out)


def projects():
    out = owl("new", "one")
    out += owl("new", "two", "--gui")
    listed = owl("projects")
    expect(listed.index("two") < listed.index("one"),
           "owl new remembers projects, newest first:\n" + out + listed)
    out = repl(["projects", "open-project one", "project"], cwd=os.path.join(BASE, "two"))
    expect("* two" in out and "project one at" in out,
           "the repl lists them (* current) and opens one by name:\n" + out)
    expect(owl("projects").split("\n")[0].startswith("one"), "opening one moves it first")
    os.rename(os.path.join(BASE, "one"), os.path.join(BASE, "moved"))
    out = repl(["projects", "open-project one"])
    expect("(moved or gone)" in out and "move-project or forget-project" in out,
           "a moved project is marked, and opening it says what to do:\n" + out)
    out = repl(["move-project one " + os.path.join(BASE, "moved"), "open-project one", "project"])
    expect("is now at " + os.path.join(BASE, "moved") in out and "project one at" in out,
           "move-project points owl at the new directory:\n" + out)
    out = repl(["forget-project two", "projects", "forget-project two"])
    expect("forgot" in out and "two " not in out.split("forgot")[1].split("does not know")[0]
           and "does not know a project" in out,
           "forget-project drops it, and forgetting it again fails:\n" + out)
    expect(os.path.exists(os.path.join(BASE, "two", "project.owl")), "its files stay")
    out = repl(["forget-project"])
    expect("screen: forget-project: which project?" in out, "the name is read when missing:\n" + out)


def main():
    shutil.rmtree(BASE, ignore_errors=True)
    os.makedirs(BASE)
    commands()
    failures_shown()
    projects()
    if failures:
        sys.exit("repl commands tests failed: %d of %d" % (len(failures), passed + len(failures)))
    print("repl commands tests OK (%d assertions)" % passed)


main()
