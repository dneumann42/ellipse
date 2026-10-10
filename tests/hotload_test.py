"""Hot-loaded widgets, driven end-to-end while the app runs.

Creates a scratch project (`ellipse new gui` + two `--hot` widgets) under
nimcache/hotload_test/, builds its hot binary, runs it offscreen and saves
widget sources while it lives -- asserting what a real editing session
must get: one save rebuilds exactly the one changed module, every content
change actually reaches the library that gets loaded (even with a
back-dated mtime), rapid saves converge on the last one, an unmodified
boot reuses the libraries without running the compiler, and a broken save
fails visibly while the previous library keeps serving. Needs bin/ellipse
and the nimony toolchain (make bin/ellipse). Run from the repo root
(make test), or standalone: python3 -I tests/hotload_test.py
"""
import glob, os, shutil, subprocess, sys, time

ROOT = os.getcwd()
ELLIPSE = os.path.join(ROOT, "bin", "ellipse")
NIMONY = os.path.join(ROOT, "build", "nimony", "bin", "nimony")
BASE = os.path.join(ROOT, "nimcache", "hotload_test", "proj")
PROJ = "probe"
LOG1 = os.path.join(ROOT, "nimcache", "hotload_test", "run1.log")
LOG2 = os.path.join(ROOT, "nimcache", "hotload_test", "run2.log")
LOG3 = os.path.join(ROOT, "nimcache", "hotload_test", "run3.log")

PILL = os.path.join(BASE, "src", PROJ, "pill.nim")
STATUS = os.path.join(BASE, "src", PROJ, "status.nim")
HOTDIR = os.path.join(BASE, "build", "hot")

BUILDING = "hot: building "
LOADED = "hot: loaded "
FAILED = "hot: build failed"
NIMONY_ENV = dict(os.environ, NIMONY=NIMONY)


class TestError(Exception):
    pass


def check(cond, what):
    if not cond:
        raise TestError(what)


def sh(args, cwd, timeout=1200):
    p = subprocess.run(args, cwd=cwd, env=NIMONY_ENV,
                       capture_output=True, text=True, timeout=timeout)
    check(p.returncode == 0,
          "`%s` exited %d:\n%s\n%s" % (" ".join(args), p.returncode,
                                       p.stdout[-2000:], p.stderr[-2000:]))
    return p.stdout


def log_text(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", errors="replace")
    except FileNotFoundError:
        return ""


def count(text, needle):
    return text.count(needle)


def wait_for(what, pred, timeout, path, proc, poll=2.0):
    """Poll `pred(log_text(path))` until true or timeout; a dead app fails fast."""
    end = time.time() + timeout
    while time.time() < end:
        if proc is not None and proc.poll() is not None:
            raise TestError("app exited (code %s) before: %s\nlog tail: %s"
                            % (proc.returncode, what, log_text(path)[-1500:]))
        if pred(log_text(path)):
            return
        time.sleep(poll)
    raise TestError("timeout waiting for: " + what)


def run_app(logpath):
    """Start the offscreen hot app; the log file is where stderr lands."""
    fh = open(logpath, "wb")
    env = dict(NIMONY_ENV, SDL_VIDEODRIVER="offscreen")
    proc = subprocess.Popen([os.path.join(BASE, "bin", PROJ + "-hot")],
                            cwd=BASE, env=env, stdout=fh, stderr=fh)
    return proc, fh


def edit_pill(marker):
    """Rewrite the pill widget's body to paint `marker` alongside its label:
    the literal lands in the built library, so its bytes say which source
    the running app really loaded. Any earlier test marker line is dropped,
    so every save changes the content."""
    with open(PILL) as f:
        src = f.read()
    anchor = "    text(label)"
    check(anchor in src, "pill.nim lost its body line %r" % anchor)
    src = src.replace(anchor, anchor + '\n    text("%s")' % marker, 1)
    keep = []
    for line in src.splitlines(True):
        s = line.strip()
        if s.startswith('text("MARK') and s != 'text("%s")' % marker:
            continue
        keep.append(line)
    with open(PILL, "w") as f:
        f.write("".join(keep))


def backdated_save(marker):
    """A save whose content changes but whose mtime is older than the
    library on disk -- the git-checkout shape mtime freshness gets wrong."""
    tmp = os.path.join(ROOT, "nimcache", "hotload_test", "pill_backdated.nim")
    with open(PILL) as f:
        src = f.read()
    anchor = '    text("MARK-AAA")'
    check(anchor in src, "expected MARK-AAA in pill before the backdated save")
    with open(tmp, "w") as f:
        f.write(src.replace(anchor, '    text("%s")' % marker))
    old = time.time() - 3600
    os.utime(tmp, (old, old))
    shutil.copy2(tmp, PILL)          # content new, mtime ancient


def staged_with(marker):
    """The newest staged pill library whose bytes contain `marker` -- a
    string literal in the widget's body lands verbatim in the library's
    rodata, so this proves which source the staged code came from."""
    want = marker.encode()
    files = sorted(glob.glob(os.path.join(HOTDIR, "pill.*.so")),
                   key=os.path.getmtime, reverse=True)
    for p in files:
        with open(p, "rb") as f:
            if want in f.read():
                return p
    return None


def staged_body_present(marker):
    return staged_with(marker) is not None


def main():
    check(os.path.exists(ELLIPSE), "needs bin/ellipse (make bin/ellipse)")
    check(os.path.exists(NIMONY), "needs the nimony toolchain at " + NIMONY)
    for log in (LOG1, LOG2, LOG3):
        try:
            os.remove(log)
        except FileNotFoundError:
            pass

    print("hotload: scaffolding a scratch project ...", flush=True)
    shutil.rmtree(os.path.dirname(BASE), ignore_errors=True)
    os.makedirs(os.path.dirname(BASE), exist_ok=True)
    sh([ELLIPSE, "new", "gui", PROJ, "--dir:" + BASE, "--yes"], ROOT)
    sh([ELLIPSE, "new", "widget", "Pill", "--hot", "--params", "label: string",
        "--yes"], BASE)
    sh([ELLIPSE, "new", "widget", "Status", "--hot", "--params", "label: string",
        "--yes"], BASE)
    check(os.path.exists(PILL), "no pill.nim generated")
    check(os.path.exists(STATUS), "no status.nim generated")

    print("hotload: building the hot binary ...", flush=True)
    sh(["make", "bin/%s-hot" % PROJ], BASE, timeout=1800)

    # --- boot: both modules build once and load --------------------------
    print("hotload: booting the app (first build takes a while) ...",
          flush=True)
    proc, fh = run_app(LOG1)
    try:
        wait_for("two modules loaded at boot",
                 lambda t: count(t, LOADED) >= 2, 1800, LOG1, proc)
        check(count(log_text(LOG1), BUILDING + os.path.join("src", PROJ, "pill.nim")) >= 1,
              "boot never built pill")
        # every staged lib must match its source's first body line: fresh
        # modules, nothing stale left from a previous scratch dir
        check(not staged_body_present("MARK-AAA"), "marker before a save?")

        # --- save #1: one module rebuilds, exactly one ------------------
        print("hotload: save -> rebuild + reload ...", flush=True)
        base_loads = count(log_text(LOG1), LOADED)
        base_status_builds = count(
            log_text(LOG1), BUILDING + os.path.join("src", PROJ, "status.nim"))
        edit_pill("MARK-AAA")
        wait_for("pill rebuild after save #1",
                 lambda t: count(t, LOADED) >= base_loads + 1, 900, LOG1, proc)
        check(staged_body_present("MARK-AAA"),
              "staged library does not contain the saved text (MARK-AAA)")
        t = log_text(LOG1)
        check(count(t, BUILDING + os.path.join("src", PROJ, "status.nim"))
              == base_status_builds,
              "saving pill rebuilt status too -- per-file watching broken")

        # --- save #2: content change with a back-dated mtime -------------
        print("hotload: backdated-mtime save ...", flush=True)
        base_loads = count(log_text(LOG1), LOADED)
        backdated_save("MARK-BBB")
        wait_for("reload after the backdated save",
                 lambda t: count(t, LOADED) >= base_loads + 1, 900, LOG1, proc)
        wait_for("the backdated change in a staged lib",
                 lambda t: staged_body_present("MARK-BBB"), 60, LOG1, proc)

        # --- rapid double save: the last content wins --------------------
        print("hotload: rapid double save ...", flush=True)
        edit_pill("MARK-C1")
        time.sleep(0.5)
        edit_pill("MARK-C2")
        wait_for("the final rapid-save change loaded",
                 lambda t: staged_body_present("MARK-C2"), 900, LOG1, proc)
        # let any queued rebuild for C1 finish before we relaunch
        time.sleep(35)

        # --- restart with no changes: reuse, zero compiler runs ----------
        print("hotload: restart reuses libraries ...", flush=True)
        proc.terminate()
        proc.wait(timeout=30)
        fh.close()
        proc, fh = run_app(LOG2)
        wait_for("two modules loaded on restart",
                 lambda t: count(t, LOADED) >= 2, 600, LOG2, proc)
        t2 = log_text(LOG2)
        builds2 = [l for l in t2.splitlines() if BUILDING in l]
        check(not builds2,
              "up-to-date boot ran the compiler anyway: "
              + (builds2[0] if builds2 else ""))
        check(staged_body_present("MARK-C2"),
              "restart lost the last loaded content")

        # --- broken save: visible failure, app keeps serving --------------
        print("hotload: broken save ...", flush=True)
        base_loads = count(log_text(LOG2), LOADED)
        with open(PILL) as f:
            good = f.read()
        with open(PILL, "w") as f:
            f.write(good + "\nthis is not nim ###\n")
        wait_for("the failed build reported",
                 lambda t: count(t, FAILED) >= 1, 900, LOG2, proc)
        check(proc.poll() is None, "the app died on a failed build")
        check(count(log_text(LOG2), LOADED) == base_loads,
              "a failed build swapped entries anyway")
        with open(PILL, "w") as f:
            f.write(good)          # fix
        edit_pill("MARK-E")
        wait_for("the recovery reload",
                 lambda t: count(t, LOADED) >= base_loads + 1, 900, LOG2, proc)
        wait_for("the fixed source loaded",
                 lambda t: staged_body_present("MARK-E"), 900, LOG2, proc)

        # --- third boot: everything survives two sessions of edits -------
        print("hotload: final restart ...", flush=True)
        proc.terminate()
        proc.wait(timeout=30)
        fh.close()
        proc, fh = run_app(LOG3)
        wait_for("loaded on the final restart",
                 lambda t: count(t, LOADED) >= 2, 600, LOG3, proc)
        check(staged_body_present("MARK-E"),
              "the final boot did not serve the newest content")
        proc.terminate()
        proc.wait(timeout=30)
        fh.close()
        proc = None
        print("hotload: OK")
    finally:
        if proc is not None and proc.poll() is None:
            proc.kill()
        try:
            fh.close()
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())
