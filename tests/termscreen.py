"""A pseudo-terminal and just enough of a terminal model to read what an
ellipse app in --tui mode draws: cursor moves, clears and text (colours
ignored). Shared by the tests that drive TUI apps; import it after putting
tests/ on sys.path (the tests run with python3 -I).
"""
import codecs, fcntl, os, pty, re, select, signal, struct, termios, time
import unicodedata


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


class PtyApp:
    """`argv` run on a pseudo-terminal of cols x rows, in `cwd`."""

    def __init__(self, argv, cols=100, rows=30, cwd=None, env=None, settle=2.0):
        self.screen = Screen(cols, rows)
        self.raw = b""
        self.decoder = codecs.getincrementaldecoder("utf8")("replace")
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            if cwd:
                os.chdir(cwd)
            os.environ["TERM"] = "xterm-256color"
            os.environ["COLORTERM"] = "truecolor"
            os.environ.pop("ELLIPSE_TUI", None)
            for k, v in (env or {}).items():
                os.environ[k] = v
            os.execv(argv[0], argv)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.read(settle)

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
                self.screen.feed(self.decoder.decode(chunk))
        return True

    def send(self, data, wait=0.6):
        os.write(self.fd, data)
        self.read(wait)
        return self.screen.text()

    def wait_for(self, needle, t=5.0):
        """Read until `needle` is on the screen (True) or `t` passes."""
        end = time.time() + t
        while time.time() < end:
            if needle in self.screen.text():
                return True
            self.read(0.1)
        return needle in self.screen.text()

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
