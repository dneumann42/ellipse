"""The repl app's screens in the terminal, locally and attached to a running app.

Piped input never shows the item view, the results view, the pickers or the
forms, so this drives `bin/owl repl --tui` on a pseudo-terminal and reads the
screen (tests/termscreen.py): the same screens must come up, cursorable, on
this repl's documents and, while attached, on the app's. The window face of
the same app is tests/repl_gui_test.nim. Needs bin/owl (either build) and
python3. Run from the repo root (make test).
"""
import os, shutil, subprocess, sys, time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.getcwd(), "tests"))
from termscreen import PtyApp

ROOT = os.getcwd()
OWL = os.path.join(ROOT, "bin", "owl")
BASE = os.path.join(ROOT, "nimcache", "owl_screens_test")
APP = os.path.join(BASE, "app")
RUN = b"\x1b[13;5u"      # Ctrl+Enter, as the kitty keyboard protocol sends it
DOWN = b"\x1b[B"
F1 = b"\x1bOP"
F2 = b"\x1bOQ"
ESC = b"\x1b"
CTRL_A = b"\x01"
CTRL_D = b"\x04"
BACKSPACE = b"\x7f"

failures = []
passed = 0


def expect(cond, msg):
    global passed
    if cond:
        passed += 1
    else:
        failures.append(msg)
        print("FAILED:", msg)


class Repl(PtyApp):
    def __init__(self, cwd):
        super().__init__([OWL, "repl", "--tui"], 110, 34, cwd=cwd, settle=1.0)
        self.wait_for("> ", 5)

    def type(self, keys, wait=0.8):
        return self.send(keys, wait)

    def run(self, code, wait=1.2):
        return self.send(code + RUN, wait)

    def shows(self, needle, t=3.0):
        return self.wait_for(needle, t)


def cursor_row(screen):
    # the selected row of a list: the one with the bar
    rows = [l for l in screen.split("\n") if "▌" in l]
    return rows[0] if rows else ""


def screens(r, where, doc):
    r.run(b"items")
    ok = r.shows("%s · " % doc) and r.shows(" items")
    expect(ok, where + ": items opens the item view of " + doc + ":\n" + r.screen.text())
    expect("#1" in cursor_row(r.screen.text()), where + ": the first item is selected:\n" + r.screen.text())
    s = r.type(DOWN + DOWN)
    expect("#3" in cursor_row(s), where + ": the cursor moves down the items:\n" + s)
    r.type(b"e")
    expect(r.shows("editing in " + doc), where + ": e puts the item into the prompt:\n" + r.screen.text())
    r.type(CTRL_A + BACKSPACE, 0.5)   # clear the prompt
    r.run(b"(+ 40 2)")
    expect(r.shows("=> 42"), where + ": code runs:\n" + r.screen.text())
    r.type(F2, 1.2)
    expect(r.shows("results · ") and "(+ 40 2)" in r.screen.text(),
           where + ": F2 shows the results:\n" + r.screen.text())
    r.type(ESC)
    r.type(F1, 1.0)
    expect(r.shows("Commands · "), where + ": F1 opens the menu:\n" + r.screen.text())
    r.type(b"items", 0.6)
    r.type(b"\r", 1.2)
    expect(r.shows("items: which module?"), where + ": items from the menu asks which module:\n" + r.screen.text())
    # Escape there means no module: items falls back to the active one
    r.type(ESC, 1.2)
    expect(r.shows("%s · " % doc), where + ": a cancelled pick shows the active document:\n" + r.screen.text())
    r.type(ESC)
    r.run(b"show")
    expect(r.shows("show: which item of %s?" % doc), where + ": show picks an item of " + doc + ":\n" + r.screen.text())
    r.type(ESC)
    r.run(b"settings")
    expect(r.shows("Settings") and "Record statements" in r.screen.text(), where + ": settings is a form:\n" + r.screen.text())
    r.type(ESC)
    expect(r.shows("settings unchanged"), where + ": Escape cancels the form:\n" + r.screen.text())


def main():
    shutil.rmtree(BASE, ignore_errors=True)
    os.makedirs(BASE)
    subprocess.run([OWL, "new", "app", "gui"], cwd=BASE, check=True, stdout=subprocess.DEVNULL)
    env = dict(os.environ, SDL_VIDEODRIVER="offscreen")
    app = subprocess.Popen([OWL, "run"], cwd=APP, env=env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           start_new_session=True)
    r = None
    try:
        time.sleep(2)
        r = Repl(APP)
        screens(r, "local", "scratch")
        r.run(b"attach %d" % app.pid, 1.5)
        expect(r.shows("attached to app"), "attach:\n" + r.screen.text())
        screens(r, "attached", "main")
        r.run(b"items")
        r.shows("main · ")
        r.type(DOWN * 6)
        r.type(b"d", 1.2)
        expect(r.shows("dropped"), "attached: d drops an item of the app's document:\n" + r.screen.text())
        r.run(b"stop", 1.5)
        expect(r.shows("stopped app"), "stop closes the app:\n" + r.screen.text())
        # leaving with an unsaved document asks first; Leave goes
        r.run(b"x = 1")
        r.type(b"\x11", 1.0)   # Ctrl+Q: closing the app asks the same
        expect(r.shows("Leave the repl?"), "Ctrl+Q asks about unsaved documents:\n" + r.screen.text())
        r.type(ESC, 0.8)
        expect(r.wait_exit(0.5) is None and "Leave the repl?" not in r.screen.text(),
               "Escape there stays:\n" + r.screen.text())
        r.type(CTRL_D, 1.0)
        expect(r.shows("Leave the repl?"), "Ctrl+D asks about unsaved documents:\n" + r.screen.text())
        r.type(b"\x1b[C\r", 0.5)
        status = r.wait_exit(5)
        expect(status == 0, "Leave ends the repl (status %r)" % (status,))
        expect(r.raw.endswith(b"\x1b[?1049l") or b"\x1b[?1049l" in r.raw[-200:],
               "the terminal is given back (alternate screen left)")
    finally:
        if r is not None:
            r.kill()
        app.kill()
        app.wait()
    if failures:
        sys.exit("repl screens tests failed: %d of %d" % (len(failures), passed + len(failures)))
    print("repl screens tests OK (%d assertions)" % passed)


main()
