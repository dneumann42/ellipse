"""Any ellipse app in the terminal: bin/gallery run with --tui on a
pseudo-terminal, driven by real key, mouse, paste and resize input.

The app's output is replayed into a small screen model (cursor moves,
clears, text; colours ignored) and the test reads the screen the way a
user would. Checks: the first frame; a click toggles a checkbox; typing
into a field; a wheel scroll; a resize relayouts; Ctrl+Q exits with the
terminal restored. Needs bin/gallery and python3. Run from the repo root.
"""
import fcntl, os, pty, re, select, signal, struct, sys, termios, time
import unicodedata

ROOT = os.getcwd()
APP = os.path.join(ROOT, "bin", "gallery")

failures = []
passed = 0


def expect(cond, msg):
    global passed
    if cond:
        passed += 1
    else:
        failures.append(msg)
        print("FAILED:", msg)


def width(ch):
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


class Screen:
    """Just enough of a terminal for what the cell renderer writes."""

    def __init__(self, cols, rows):
        self.resize(cols, rows)
        self.alt = False
        self.pending = ""

    def resize(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.grid = [[" "] * cols for _ in range(rows)]
        self.r = self.c = 0

    def feed(self, data):
        s = self.pending + data
        self.pending = ""
        i = 0
        while i < len(s):
            ch = s[i]
            if ch == "\x1b":
                if i + 1 >= len(s):
                    self.pending = s[i:]
                    return
                if s[i + 1] == "[":
                    m = re.compile(r"\[([0-9;?<>=]*)[ -/]*([@-~])").match(s, i + 1)
                    if not m:
                        self.pending = s[i:]
                        return
                    self.csi(m.group(1), m.group(2))
                    i = m.end()
                    continue
                if s[i + 1] == "]":
                    end = s.find("\x07", i)
                    if end < 0:
                        self.pending = s[i:]
                        return
                    i = end + 1
                    continue
                i += 2
                continue
            if ch in "\r\n":
                i += 1
                continue
            w = width(ch)
            if w == 0:
                i += 1
                continue
            if 0 <= self.r < self.rows and 0 <= self.c < self.cols:
                self.grid[self.r][self.c] = ch
                if w == 2 and self.c + 1 < self.cols:
                    self.grid[self.r][self.c + 1] = ""
            self.c += w
            i += 1

    def csi(self, params, final):
        if final == "H":
            p = [int(x) if x else 1 for x in params.split(";")] if params else [1, 1]
            self.r, self.c = p[0] - 1, (p[1] - 1 if len(p) > 1 else 0)
        elif final == "J" and params == "2":
            self.grid = [[" "] * self.cols for _ in range(self.rows)]
        elif final in "hl" and params == "?1049":
            self.alt = final == "h"

    def text(self):
        return "\n".join("".join(row).rstrip() for row in self.grid)

    def find(self, needle):
        """(col, row) of the first occurrence of `needle`, or None."""
        for r, row in enumerate(self.grid):
            line = "".join(x if x else "" for x in row)
            c = line.find(needle)
            if c >= 0:
                # map the string index back to a column (wide glyphs take 2)
                col = 0
                k = 0
                for x in row:
                    if k == c:
                        return (col, r)
                    k += len(x)
                    col += 1
                return (c, r)
        return None


class App:
    def __init__(self, cols, rows, args=()):
        self.screen = Screen(cols, rows)
        self.raw = b""
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ["TERM"] = "xterm-256color"
            os.environ["COLORTERM"] = "truecolor"
            os.environ.pop("ELLIPSE_TUI", None)
            os.execv(APP, ["gallery", "--tui", *args])
        self.setsize(cols, rows)
        self.read(2.5)

    def setsize(self, cols, rows):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def read(self, t):
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    chunk = os.read(self.fd, 1 << 16)
                except OSError:
                    return False
                if not chunk:
                    return False
                self.raw += chunk
                self.screen.feed(chunk.decode("utf8", "replace"))
        return True

    def send(self, data, wait=0.6):
        os.write(self.fd, data)
        self.read(wait)

    def click(self, col, row):
        """Left click on a 0-based cell (SGR mouse is 1-based)."""
        self.send(b"\x1b[<35;%d;%dM" % (col + 1, row + 1), 0.15)
        self.send(b"\x1b[<0;%d;%dM" % (col + 1, row + 1), 0.15)
        self.send(b"\x1b[<0;%d;%dm" % (col + 1, row + 1))

    def wait_exit(self, t):
        end = time.time() + t
        while time.time() < end:
            self.read(0.1)
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return status
        return None

    def kill(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except OSError:
            pass


def main():
    if not os.path.exists(APP):
        print("needs bin/gallery (make bin/gallery)")
        sys.exit(1)
    app = App(110, 60)
    try:
        s = app.screen
        expect(s.alt, "entered the alternate screen")
        expect(s.find("Widget Gallery") is not None, "first frame shows the gallery:\n" + s.text())
        expect(s.find("[File][View]") is not None, "menu bar on one row")

        # A click on the VSync checkbox's box toggles it.
        pos = s.find("VSync")
        expect(pos is not None, "VSync checkbox shown")
        if pos:
            # The tick is an accent-filled cell: colour only, so look for the
            # cell being rewritten rather than at the text.
            mark = len(app.raw)
            app.click(pos[0] - 3, pos[1])
            accent = b"48;2;96;130;220m "   # the default theme's accent
            expect(accent in app.raw[mark:], "clicking the checkbox fills its tick")

        # Click the Artist field, type, and see the text.
        pos = s.find("Ada Lovelace")
        expect(pos is not None, "Artist field shown")
        if pos:
            app.click(pos[0] + 2, pos[1])
            app.send(b"\x05")            # C-e: end of line
            app.send(b" Byron")
            at = s.find("Ada Lovelace Byron")
            expect(at is not None, "typing lands in the focused field:\n" + s.text())
            # The caret is the terminal's cursor, shown right after the text.
            shows = re.findall(rb"\x1b\[(\d+);(\d+)H\x1b\[5 q\x1b\[\?25h", app.raw)
            if at and shows:
                row, col = int(shows[-1][0]) - 1, int(shows[-1][1]) - 1
                expect((col, row) == (at[0] + len("Ada Lovelace Byron"), at[1]),
                       "cursor at the caret: %r vs text at %r" % ((col, row), at))
            else:
                expect(False, "the cursor is shown while a field is focused")
            app.send(b"\r")

        # The wheel scrolls the page: the heading moves up.
        top = s.find("Widget Gallery")
        app.send(b"\x1b[<65;50;20M" * 6, 1.2)
        moved = s.find("Widget Gallery")
        expect(top is not None and (moved is None or moved[1] < top[1]),
               "wheel scrolls the page (%r -> %r)" % (top, moved))

        # A resize relayouts to the new width.
        app.setsize(80, 30)
        s.resize(80, 30)
        app.raw = b""
        os.kill(app.pid, signal.SIGWINCH)
        app.read(2.0)
        right = max((len(l) for l in s.text().splitlines()), default=0)
        expect(right <= 80 and right > 40, "relayout at 80 columns (widest line %d, %d bytes: %r)"
               % (right, len(app.raw), s.pending[:80]))

        # Ctrl+Q quits and gives the terminal back.
        app.send(b"\x11", 0.2)
        status = app.wait_exit(3.0)
        expect(status is not None and os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0,
               "Ctrl+Q exits cleanly (status %r)" % (status,))
        tail = app.raw[-200:]
        expect(b"\x1b[?1049l" in tail and b"\x1b[?1000l" in tail and b"\x1b[?25h" in tail,
               "terminal restored on exit: %r" % tail)
    finally:
        app.kill()

    print("tui backend: %d passed, %d failed" % (passed, len(failures)))
    sys.exit(1 if failures else 0)


main()
