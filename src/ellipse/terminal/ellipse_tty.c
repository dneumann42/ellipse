/* The terminal an ellipse app draws in (see tty.nim): raw mode, the size,
 * a pipe that turns signals into readable bytes for the frame loop, and a
 * restore path every exit takes -- normal exit, a fatal signal, a crash --
 * so the shell is never left raw, mouse-reporting or on the alternate
 * screen. */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

static struct termios saved;
static int have_saved = 0;
static int is_raw = 0;
static int sig_pipe[2] = {-1, -1};
static char leave_seq[512];
static int leave_len = 0;

static void put_all(const char *s, int len) {
  /* stdin is non-blocking, and on a terminal stdout shares its open file:
   * a full pty buffer answers EAGAIN, so wait for it to drain -- a frame
   * cut off mid-sequence would garble the screen. */
  while (len > 0) {
    ssize_t n = write(STDOUT_FILENO, s, (size_t)len);
    if (n < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        struct pollfd p = { STDOUT_FILENO, POLLOUT, 0 };
        poll(&p, 1, 1000);
        continue;
      }
      return;
    }
    s += n;
    len -= (int)n;
  }
}

static void restore(void) {
  if (leave_len > 0) {
    put_all(leave_seq, leave_len);
    leave_len = 0;
  }
  if (is_raw && have_saved) {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved);
    /* The shell shares this open file: hand it back blocking. */
    fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) & ~O_NONBLOCK);
    is_raw = 0;
  }
}

static void on_signal(int sig) {
  /* Async-signal-safe: one byte down the pipe; the loop reads it. */
  char b = sig == SIGWINCH ? 'w' : 'q';
  if (sig_pipe[1] >= 0) {
    ssize_t n = write(sig_pipe[1], &b, 1);
    (void)n;
  }
}

static void on_fatal(int sig) {
  restore();
  signal(sig, SIG_DFL);
  raise(sig);
}

int ellipse_tty_is_tty(void) {
  return isatty(STDIN_FILENO) && isatty(STDOUT_FILENO);
}

/* Raw mode plus the signal pipe. Returns the pipe's read end, or -1. */
int ellipse_tty_open(void) {
  if (tcgetattr(STDIN_FILENO, &saved) != 0) return -1;
  have_saved = 1;
  if (pipe(sig_pipe) != 0) return -1;
  fcntl(sig_pipe[0], F_SETFL, O_NONBLOCK);
  fcntl(sig_pipe[1], F_SETFL, O_NONBLOCK);
  atexit(restore);
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_signal;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART;
  sigaction(SIGWINCH, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGHUP, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);
  signal(SIGSEGV, on_fatal);
  signal(SIGABRT, on_fatal);
  signal(SIGBUS, on_fatal);
  signal(SIGFPE, on_fatal);
  struct termios raw = saved;
  raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
  raw.c_oflag &= ~(OPOST);
  raw.c_cflag |= CS8;
  raw.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
  raw.c_cc[VMIN] = 1;
  raw.c_cc[VTIME] = 0;
  if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0) return -1;
  is_raw = 1;
  fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);
  return sig_pipe[0];
}

/* What restore writes before leaving raw mode: the sequences that undo
 * the ones the app entered with. */
void ellipse_tty_set_leave(const char *s, int len) {
  if (len > (int)sizeof leave_seq) len = (int)sizeof leave_seq;
  memcpy(leave_seq, s, (size_t)len);
  leave_len = len;
}

void ellipse_tty_close(void) { restore(); }

void ellipse_tty_size(int *cols, int *rows) {
  struct winsize ws;
  *cols = 80;
  *rows = 24;
  if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
    *cols = ws.ws_col;
    *rows = ws.ws_row;
  }
}

void ellipse_tty_write(const char *s, int len) { put_all(s, len); }

/* Whatever `fd` has ready, without blocking: bytes read, 0 for nothing,
 * -1 at end of input. */
int ellipse_tty_read(int fd, char *buf, int cap) {
  for (;;) {
    ssize_t n = read(fd, buf, (size_t)cap);
    if (n > 0) return (int)n;
    if (n == 0) return -1;
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
    return -1;
  }
}
