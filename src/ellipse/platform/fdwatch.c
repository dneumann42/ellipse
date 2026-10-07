/* Readable-fd wakeups for the frame loop (see fdwatch.nim).
 *
 * One helper thread sleeps in poll() on the watched descriptors plus a
 * control pipe. When a descriptor turns readable the thread disarms it
 * (so poll does not report it again before the main thread has read it)
 * and pushes one SDL user event, which wakes SDL_WaitEventTimeout. The
 * main thread takes the ready descriptors, runs their callbacks and
 * re-arms them. The thread never touches anything but this file's state
 * and SDL_PushEvent, which SDL documents as thread-safe. */

#include <SDL3/SDL.h>
#include <poll.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#define MAX_FDS 256

typedef struct {
  int fd;
  int armed;  /* polled by the thread */
  int fired;  /* readable, waiting for the main thread */
} Entry;

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static Entry entries[MAX_FDS];
static int count = 0;
static int ctl[2] = {-1, -1};
static int started = 0;
static Uint32 event_type = 0;

static void poke(void) {
  if (ctl[1] >= 0) {
    char b = 1;
    ssize_t n = write(ctl[1], &b, 1);
    (void)n;
  }
}

static void *watch_thread(void *arg) {
  (void)arg;
  struct pollfd fds[MAX_FDS + 1];
  for (;;) {
    int n = 0;
    fds[n].fd = ctl[0];
    fds[n].events = POLLIN;
    fds[n].revents = 0;
    n++;
    pthread_mutex_lock(&lock);
    for (int i = 0; i < count; i++) {
      if (entries[i].armed) {
        fds[n].fd = entries[i].fd;
        fds[n].events = POLLIN;
        fds[n].revents = 0;
        n++;
      }
    }
    pthread_mutex_unlock(&lock);
    int r = poll(fds, (nfds_t)n, -1);
    if (r < 0) {
      if (errno == EINTR)
        continue;
      return NULL;
    }
    if (fds[0].revents) {
      char buf[64];
      while (read(ctl[0], buf, sizeof buf) > 0) {
      }
    }
    int any = 0;
    pthread_mutex_lock(&lock);
    for (int k = 1; k < n; k++) {
      if (!fds[k].revents)
        continue;
      for (int i = 0; i < count; i++) {
        if (entries[i].fd == fds[k].fd && entries[i].armed) {
          entries[i].armed = 0;
          entries[i].fired = 1;
          any = 1;
        }
      }
    }
    pthread_mutex_unlock(&lock);
    if (any) {
      SDL_Event ev;
      SDL_zero(ev);
      ev.type = event_type;
      SDL_PushEvent(&ev);
    }
  }
  return NULL;
}

static int start(void) {
  if (started)
    return 1;
  if (event_type == 0) {
    event_type = SDL_RegisterEvents(1);
    if (event_type == 0)
      return 0;
  }
  if (pipe(ctl) != 0)
    return 0;
  fcntl(ctl[0], F_SETFL, fcntl(ctl[0], F_GETFL) | O_NONBLOCK);
  fcntl(ctl[1], F_SETFL, fcntl(ctl[1], F_GETFL) | O_NONBLOCK);
  fcntl(ctl[0], F_SETFD, FD_CLOEXEC);
  fcntl(ctl[1], F_SETFD, FD_CLOEXEC);
  pthread_t t;
  if (pthread_create(&t, NULL, watch_thread, NULL) != 0)
    return 0;
  pthread_detach(t);
  started = 1;
  return 1;
}

int ellipse_fdwatch_add(int fd) {
  if (!start())
    return 0;
  pthread_mutex_lock(&lock);
  int ok = count < MAX_FDS;
  if (ok) {
    for (int i = 0; i < count; i++)
      if (entries[i].fd == fd)
        ok = 0;
  }
  if (ok) {
    entries[count].fd = fd;
    entries[count].armed = 1;
    entries[count].fired = 0;
    count++;
  }
  pthread_mutex_unlock(&lock);
  poke();
  return ok;
}

void ellipse_fdwatch_remove(int fd) {
  pthread_mutex_lock(&lock);
  for (int i = 0; i < count; i++) {
    if (entries[i].fd == fd) {
      entries[i] = entries[count - 1];
      count--;
      break;
    }
  }
  pthread_mutex_unlock(&lock);
  poke();
}

int ellipse_fdwatch_take(int *out, int cap) {
  int n = 0;
  pthread_mutex_lock(&lock);
  for (int i = 0; i < count && n < cap; i++) {
    if (entries[i].fired) {
      entries[i].fired = 0;
      out[n++] = entries[i].fd;
    }
  }
  pthread_mutex_unlock(&lock);
  return n;
}

void ellipse_fdwatch_rearm(int fd) {
  pthread_mutex_lock(&lock);
  for (int i = 0; i < count; i++)
    if (entries[i].fd == fd)
      entries[i].armed = 1;
  pthread_mutex_unlock(&lock);
  poke();
}

unsigned int ellipse_fdwatch_event_type(void) { return event_type; }
