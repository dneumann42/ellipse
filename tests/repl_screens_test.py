"""The repl's terminal screens, locally and attached to a running app.

Piped input never shows the item view, the results view, the pickers or the
forms, so these drive `bin/owl repl` on a pseudo-terminal: the same screens
must come up, cursorable, on this repl's documents and, while attached, on
the app's. Needs bin/owl and python3. Run from the repo root (make test).
"""
import os, pty, re, select, shutil, signal, subprocess, sys, time

ROOT = os.getcwd()
OWL = os.path.join(ROOT, "bin", "owl")
BASE = os.path.join(ROOT, "nimcache", "owl_screens_test")
APP = os.path.join(BASE, "app")
DOWN = b"\x1b[B"
F1 = b"\x1bOP"
F2 = b"\x1bOQ"
ESC = b"\x1b"

failures = []
passed = 0


def expect(cond, msg):
    global passed
    if cond:
        passed += 1
    else:
        failures.append(msg)
        print("FAILED:", msg)


class Repl:
    def __init__(self, cwd):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            os.execv(OWL, ["owl", "repl"])
        self.out = b""
        self.read(1.5)

    def read(self, t):
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    self.out += os.read(self.fd, 65536)
                except OSError:
                    return

    def send(self, keys, wait=1.0):
        mark = len(self.out)
        os.write(self.fd, keys)
        self.read(wait)
        raw = self.out[mark:]
        return re.sub(rb"\x1b\[[0-9;?<>=]*[A-Za-z]|\x1b\][^\x07]*\x07|\r", b"", raw).decode("utf8", "replace")

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except OSError:
            pass


def cursor_row(screen):
    # the selected item: the last view drawn, the line with the bar
    rows = [l for l in screen.split("\n") if "▌" in l]
    return rows[-1] if rows else ""


def screens(r, where, doc):
    s = r.send(b"items\n", 1.2)
    expect(("%s · " % doc) in s and " items " in s, where + ": items opens the item view of " + doc + ":\n" + s[-600:])
    expect("#1  ▌" in s, where + ": the first item is selected")
    s = r.send(DOWN + DOWN, 0.8)
    expect("#3  ▌" in cursor_row(s) or "#3  ▌" in s, where + ": the cursor moves down the items:\n" + s[-400:])
    s = r.send(b"e", 1.0)
    expect("editing in " + doc in s, where + ": e puts the item into the prompt:\n" + s[-300:])
    r.send(ESC, 0.5)
    r.send(b"\x15", 0.3)  # C-u: clear the prompt
    s = r.send(b"(+ 40 2)\n", 1.0)
    expect("=> 42" in s, where + ": code runs")
    s = r.send(F2, 1.2)
    expect("results · " in s and "(+ 40 2)" in s, where + ": F2 shows the results:\n" + s[-400:])
    r.send(ESC, 0.6)
    r.send(F1, 1.0)
    r.send(b"items", 0.5)
    s = r.send(b"\r", 1.2)
    expect("items: which module?" in s, where + ": items from the menu asks which module:\n" + s[-400:])
    # Escape there means no module: items falls back to the active one
    s = r.send(ESC, 1.0)
    expect(("%s \u00b7 " % doc) in s, where + ": a cancelled pick shows the active document:\n" + s[-300:])
    r.send(ESC, 0.6)
    s = r.send(b"show\n", 1.2)
    expect(("show: which item of %s?" % doc) in s, where + ": show picks an item of " + doc + ":\n" + s[-400:])
    r.send(ESC, 0.6)
    s = r.send(b"settings\n", 1.2)
    expect("Settings" in s and "Record statements" in s, where + ": settings is a form")
    r.send(ESC, 0.6)


def main():
    shutil.rmtree(BASE, ignore_errors=True)
    os.makedirs(BASE)
    subprocess.run([OWL, "new", "app", "gui"], cwd=BASE, check=True, stdout=subprocess.DEVNULL)
    env = dict(os.environ, SDL_VIDEODRIVER="offscreen")
    app = subprocess.Popen([OWL, "run"], cwd=APP, env=env, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        time.sleep(2)
        r = Repl(APP)
        screens(r, "local", "scratch")
        s = r.send(b"attach %d\n" % app.pid, 1.5)
        expect("attached to app" in s, "attach:\n" + s)
        screens(r, "attached", "main")
        s = r.send(b"items\n", 1.2)
        r.send(DOWN * 6, 0.8)
        s = r.send(b"d", 1.2)
        expect("dropped" in s, "attached: d drops an item of the app's document:\n" + s[-300:])
        r.send(b"stop\n", 1.5)
        r.close()
    finally:
        app.kill()
        app.wait()
    if failures:
        sys.exit("repl screens tests failed: %d of %d" % (len(failures), passed + len(failures)))
    print("repl screens tests OK (%d assertions)" % passed)


main()
