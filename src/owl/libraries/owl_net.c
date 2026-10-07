/* What std/posix does not bind, for owl's net module: unix sockets,
 * poll and file-change notification (inotify). The protocols on top (the attach
 * server, the repl client, project reloading) are written in owl. POSIX
 * only; on Windows the module is a stub. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>


static void owl_cloexec(int fd) { fcntl(fd, F_SETFD, FD_CLOEXEC); }

static void owl_nonblock(int fd) {
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
}

static int owl_unix_addr(struct sockaddr_un *a, const char *path) {
  memset(a, 0, sizeof *a);
  a->sun_family = AF_UNIX;
  if (strlen(path) >= sizeof a->sun_path)
    return 0;
  strcpy(a->sun_path, path);
  return 1;
}

/* A listening socket at path, readable by its owner only; a stale socket
 * file left by a dead process is replaced. Non-blocking. */
int owl_unix_listen(const char *path) {
  struct sockaddr_un a;
  if (!owl_unix_addr(&a, path))
    return -1;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0)
    return -1;
  owl_cloexec(fd);
  unlink(path);
  mode_t old = umask(0077);
  int ok = bind(fd, (struct sockaddr *)&a, sizeof a) == 0;
  umask(old);
  if (!ok || listen(fd, 8) != 0) {
    close(fd);
    return -1;
  }
  chmod(path, 0600);
  owl_nonblock(fd);
  return fd;
}

int owl_unix_connect(const char *path) {
  struct sockaddr_un a;
  if (!owl_unix_addr(&a, path))
    return -1;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0)
    return -1;
  owl_cloexec(fd);
  if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

/* A waiting connection, non-blocking, or -1 when there is none. */
int owl_accept(int fd) {
  int c = accept(fd, NULL, NULL);
  if (c < 0)
    return -1;
  owl_cloexec(c);
  owl_nonblock(c);
  return c;
}

/* Up to cap bytes. timeout_ms < 0 waits for data; otherwise at most that
 * long. > 0: bytes read, 0: the other end closed, -2: nothing yet,
 * -1: an error. */
int owl_read(int fd, char *buf, int cap, int timeout_ms) {
  struct pollfd p = {fd, POLLIN, 0};
  int r;
  do {
    r = poll(&p, 1, timeout_ms);
  } while (r < 0 && errno == EINTR);
  if (r < 0)
    return -1;
  if (r == 0)
    return -2;
  ssize_t n;
  do {
    n = read(fd, buf, (size_t)cap);
  } while (n < 0 && errno == EINTR);
  if (n < 0)
    return (errno == EAGAIN || errno == EWOULDBLOCK) ? -2 : -1;
  return (int)n;
}

/* All of buf, waiting while a non-blocking socket is full. 0 on success. */
int owl_write_all(int fd, const char *buf, int len) {
  int done = 0;
  while (done < len) {
    ssize_t n = send(fd, buf + done, (size_t)(len - done), MSG_NOSIGNAL);
    if (n < 0) {
      if (errno == EINTR)
        continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        struct pollfd p = {fd, POLLOUT, 0};
        poll(&p, 1, 1000);
        continue;
      }
      return -1;
    }
    done += (int)n;
  }
  return 0;
}

void owl_close(int fd) { close(fd); }

int owl_watch_open(void) {
  int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
  return fd;
}

int owl_watch_add(int fd, const char *dir) {
  return inotify_add_watch(fd, dir,
                           IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE |
                               IN_DELETE);
}

/* The pending events as "wd\tname\n" lines in buf; the length, 0 when
 * there are none. */
int owl_watch_read(int fd, char *out, int cap) {
  char buf[8192] __attribute__((aligned(__alignof__(struct inotify_event))));
  int used = 0;
  for (;;) {
    ssize_t n = read(fd, buf, sizeof buf);
    if (n <= 0)
      break;
    for (char *p = buf; p < buf + n;) {
      struct inotify_event *e = (struct inotify_event *)p;
      if (e->len > 0) {
        char line[64];
        int k = snprintf(line, sizeof line, "%d\t", e->wd);
        int nl = (int)strlen(e->name);
        if (used + k + nl + 1 < cap) {
          memcpy(out + used, line, (size_t)k);
          used += k;
          memcpy(out + used, e->name, (size_t)nl);
          used += nl;
          out[used++] = '\n';
        }
      }
      p += sizeof(struct inotify_event) + e->len;
    }
  }
  return used;
}
