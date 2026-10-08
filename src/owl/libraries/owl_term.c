/* Terminal primitives for owl's term module: raw mode, timed byte reads and
 * the window size. Everything above this (key decoding, editing, drawing) is
 * written in owl. */
#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

static struct termios owl_saved;
static int owl_have_saved = 0;
static int owl_is_raw = 0;

static void owl_restore(void) {
  if (owl_is_raw && owl_have_saved) {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &owl_saved);
    owl_is_raw = 0;
  }
}

int owl_term_is_tty(void) {
  return isatty(STDIN_FILENO) && isatty(STDOUT_FILENO);
}

int owl_term_stderr_is_tty(void) {
  return isatty(STDERR_FILENO);
}

/* on != 0 switches stdin to raw mode, 0 restores the original settings. The
 * original is also restored at exit, so a crash in owl code never leaves the
 * shell raw. */
int owl_term_raw(int on) {
  if (!on) {
    owl_restore();
    return 0;
  }
  if (owl_is_raw) return 0;
  if (!owl_have_saved) {
    if (tcgetattr(STDIN_FILENO, &owl_saved) != 0) return -1;
    owl_have_saved = 1;
    atexit(owl_restore);
  }
  struct termios raw = owl_saved;
  raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
  raw.c_oflag &= ~(OPOST);
  raw.c_cflag |= CS8;
  raw.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
  raw.c_cc[VMIN] = 1;
  raw.c_cc[VTIME] = 0;
  if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0) return -1;
  owl_is_raw = 1;
  return 0;
}

/* One byte from stdin. timeout_ms < 0 waits forever. Returns the byte, -1 at
 * end of input and -2 when the timeout passes first. */
int owl_term_read_byte(int timeout_ms) {
  for (;;) {
    struct pollfd p = { STDIN_FILENO, POLLIN, 0 };
    int ready = poll(&p, 1, timeout_ms);
    if (ready < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (ready == 0) return -2;
    unsigned char c;
    ssize_t n = read(STDIN_FILENO, &c, 1);
    if (n == 1) return c;
    if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
    return -1;
  }
}

void owl_term_size(int *rows, int *cols) {
  struct winsize ws;
  *rows = 24;
  *cols = 80;
  if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
    *rows = ws.ws_row;
    *cols = ws.ws_col;
  }
}

void owl_term_write(const char *s, int len) {
  while (len > 0) {
    ssize_t n = write(STDOUT_FILENO, s, (size_t)len);
    if (n < 0) {
      if (errno == EINTR) continue;
      return;
    }
    s += n;
    len -= (int)n;
  }
}
