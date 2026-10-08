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
DATA = os.path.join(BASE, "data")   # the projects owl knows, kept out of ~
RUN = b"\x1b[13;5u"      # Ctrl+Enter, as the kitty keyboard protocol sends it
DOWN = b"\x1b[B"
RIGHT = b"\x1b[C"
F10 = b"\x1b[21~"
F1 = b"\x1bOP"
F2 = b"\x1bOQ"
F3 = b"\x1bOR"
CTRL_PGUP = b"\x1b[5;5~"
CTRL_PGDN = b"\x1b[6;5~"
ESC = b"\x1b"
CTRL_A = b"\x01"
CTRL_D = b"\x04"
CTRL_N = b"\x0e"
CTRL_V = b"\x16"
ALT_O = b"\x1bo"
ALT_V = b"\x1bv"
ALT_LT = b"\x1b<"
ALT_GT = b"\x1b>"
CTRL_P = b"\x10"
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
        super().__init__([OWL, "repl", "--tui"], 110, 34, cwd=cwd, settle=1.0,
                         env={"XDG_DATA_HOME": DATA})
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


def panel(screen):
    # the document panel: the right part of each row
    return "\n".join(l[62:] for l in screen.split("\n")[1:-1])


def panel_row(screen, needle):
    rows = [l for l in panel(screen).split("\n") if needle in l]
    return rows[0] if rows else ""


def click(r, col, row):
    # an SGR mouse press, then the release in a later frame, as a hand would
    r.type(b"\x1b[<0;%d;%dM" % (col, row), 0.4)
    return r.type(b"\x1b[<0;%d;%dm" % (col, row), 1.2)


def menu_bar(r):
    s = r.screen.text()
    expect("[File]" in s and "[Project]" in s and "[Repl]" in s,
           "the menu bar has a menu per section of the commands:\n" + s)
    r.type(F10, 0.8)
    s = r.type(DOWN, 1.0)
    expect("open   <module>" in s, "F10 then Down opens File, listing its commands:\n" + s)
    s = r.type(RIGHT, 1.0)
    expect("rerun" in s and "open   <module>" not in s, "Right moves to the next menu:\n" + s)
    r.type(DOWN + DOWN + b"\r", 1.5)
    expect(r.shows("show: which item of"), "picking show reads its item:\n" + r.screen.text())
    r.type(ESC, 1.0)
    # a click opens a menu, which stays open (it used to blink shut)
    col = r.screen.text().split("\n")[0].index("[Project]") + 2
    s = click(r, col, 1)
    expect("open-project" in s, "a clicked menu stays open:\n" + s)
    s = r.type(b"", 0.8)
    expect("open-project" in s, "and is still open a moment later:\n" + s)
    # clicking one of its items runs that command
    lines = s.split("\n")
    row = [i for i, l in enumerate(lines) if "projects" in l and "open-project" not in l][0]
    col = lines[row].index("projects") + 2
    click(r, col, row + 1)
    expect(r.shows("* app"), "clicking projects in the menu lists them:\n" + r.screen.text())
    r.type(F10, 0.8)
    r.type(ESC, 0.8)
    r.run(b"(+ 2 3)")
    expect(r.shows("=> 5"), "Escape gives the keys back to the prompt:\n" + r.screen.text())


def documents(r):
    r.run(b"new other")
    r.run(b"y = 5")
    s = r.screen.text()
    expect("scratch" in panel(s) and "other •" in panel(s) and "y = 5" in panel(s),
           "the panel has a tab per document and shows the active one:\n" + s)
    r.type(CTRL_PGUP, 1.2)
    s = r.screen.text()
    expect("switch scratch" in s and "scratch>" in s and "y = 5" not in panel(s),
           "Ctrl+PgUp switches to the previous document:\n" + s)
    r.type(CTRL_PGDN, 1.2)
    expect(r.shows("other>") and "y = 5" in panel(r.screen.text()),
           "Ctrl+PgDn switches back:\n" + r.screen.text())
    r.type(F3, 1.0)
    expect("other •" not in r.screen.text(), "F3 hides the panel:\n" + r.screen.text())
    r.type(F3, 1.0)
    expect("other •" in r.screen.text(), "F3 shows it again:\n" + r.screen.text())
    # Alt+O gives the panel the keys: the items view's keys, emacs motion too
    s = r.type(ALT_O, 1.0)
    expect("enter/e edit" in panel(s) and "▌" in panel_row(s, "y = 5"),
           "Alt+O focuses the panel on the last item:\n" + s)
    s = r.type(ALT_LT, 0.8)
    expect("▌" in panel_row(s, "#1"), "M-< goes to the first item:\n" + s)
    s = r.type(CTRL_N, 0.8)
    expect("▌" in panel_row(s, "#2"), "C-n moves down:\n" + s)
    s = r.type(CTRL_V, 0.8)
    expect("▌" in panel_row(s, "y = 5"), "C-v pages down:\n" + s)
    s = r.type(ALT_V, 0.8)
    expect("▌" in panel_row(s, "#1"), "M-v pages up:\n" + s)
    r.type(ALT_GT, 0.8)
    s = r.type(CTRL_P, 0.8)
    expect("▌" in panel_row(s, "export all"), "M-> then C-p:\n" + s)
    r.type(b"e", 1.2)
    expect(r.shows("editing in other") and "enter/e edit" not in panel(r.screen.text()),
           "e edits the item in the prompt and gives the keys back:\n" + r.screen.text())
    r.type(CTRL_A + BACKSPACE, 0.5)
    r.type(ALT_O, 1.0)
    r.type(b"d", 1.2)
    expect(r.shows("dropped y = 5") and "y = 5" not in panel(r.screen.text()),
           "d drops the item from the panel:\n" + r.screen.text())
    s = r.type(ESC, 1.0)
    expect("enter/e edit" not in panel(s), "Escape gives the keys back to the prompt:\n" + s)
    r.run(b"(+ 1 1)")
    expect(r.shows("=> 2"), "the prompt has the keys again:\n" + r.screen.text())
    r.run(b"switch scratch")
    expect(r.shows("scratch>"), "switch makes a document active:\n" + r.screen.text())


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
    # C-n / C-p move a picker's selection like Down / Up
    r.type(F1, 1.0)
    s = r.type(CTRL_N + CTRL_N + CTRL_N + CTRL_P)
    expect(r.shows("Commands · ") and
           "open <module>" in cursor_row(s), where + ": C-n/C-p move the menu's selection:\n" + s)
    # a picker opened from another starts with an empty filter on the same
    # field: typing there (a path's ~, a non-ASCII label) must not crash
    r.type(b"open-project", 0.6)
    r.type(b"\r", 1.2)
    expect(r.shows("Open which project?") and "current project" in r.screen.text(),
           where + ": open-project picks among the projects owl knows:\n" + r.screen.text())
    s = r.type(b"~/x", 1.0)
    expect("[~/x" in s and "Defect" not in s and "error" not in s,
           where + ": typing in the project picker's filter:\n" + s)
    r.type(ESC)


def main():
    shutil.rmtree(BASE, ignore_errors=True)
    os.makedirs(BASE)
    env = dict(os.environ, SDL_VIDEODRIVER="offscreen", XDG_DATA_HOME=DATA)
    subprocess.run([OWL, "new", "app", "gui"], cwd=BASE, env=env, check=True, stdout=subprocess.DEVNULL)
    app = subprocess.Popen([OWL, "run"], cwd=APP, env=env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           start_new_session=True)
    r = None
    try:
        time.sleep(2)
        r = Repl(APP)
        screens(r, "local", "scratch")
        menu_bar(r)
        documents(r)
        r.run(b"attach %d" % app.pid, 1.5)
        expect(r.shows("attached to app"), "attach:\n" + r.screen.text())
        expect("main" in panel(r.screen.text()) and "clicks = 0" in panel(r.screen.text()),
               "attached, the panel shows the app's documents:\n" + r.screen.text())
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
