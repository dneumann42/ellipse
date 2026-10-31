/* Readable-fd wakeups for the frame loop (see fdwatch.nim).
 *
 * Two ways to wait, picked by the platform:
 *
 * - thread (a window): one helper thread sleeps in poll() on the watched
 *   descriptors plus a control pipe. When a descriptor turns readable the
 *   thread disarms it (so poll does not report it again before the main
 *   thread has read it) and calls the waker the platform installed, which
 *   wakes the window's event queue (SDL_PushEvent, see sdl_wake.c). The
 *   thread never touches anything but this file's state and the waker.
 * - direct (the terminal): no thread. The main thread sleeps in poll()
 *   itself (ellipse_fdwatch_wait), so the terminal backend needs no event
 *   queue -- and no SDL.
 *
 * Either way the main thread takes the ready descriptors, runs their
 * callbacks and re-arms them. Nothing here depends on SDL. */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <poll.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <time.h>

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
static void (*waker)(void) = 0;

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
    if (any && waker)
      waker();
  }
  return NULL;
}

/* Thread mode: start the helper thread; `wake` is called (on that thread)
 * whenever a watched descriptor turned readable. */
int ellipse_fdwatch_use_thread(void (*wake)(void)) {
  waker = wake;
  if (started)
    return 1;
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

int ellipse_fdwatch_ready(void) {
  /* Whether any watched descriptor has fired and waits to be run: the peek
     a host loop takes before sleeping in its event system (see
     `platform.waitForWakes`), so an fd wake-up never sleeps past itself. */
  int ready = 0;
  pthread_mutex_lock(&lock);
  for (int i = 0; i < count; i++)
    if (entries[i].fired)
      ready = 1;
  pthread_mutex_unlock(&lock);
  return ready;
}

void ellipse_fdwatch_rearm(int fd) {
  pthread_mutex_lock(&lock);
  for (int i = 0; i < count; i++)
    if (entries[i].fd == fd)
      entries[i].armed = 1;
  pthread_mutex_unlock(&lock);
  poke();
}

/* Direct mode: sleep in poll() on the armed descriptors for up to `ns`
 * nanoseconds (-1: until one is readable, 0: just look), marking the
 * readable ones fired. Returns how many fired. */
int ellipse_fdwatch_wait(int64_t ns) {
  struct pollfd fds[MAX_FDS];
  int n = 0;
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
  int r;
#ifdef __linux__
  struct timespec ts;
  struct timespec *tp = 0;
  if (ns >= 0) {
    ts.tv_sec = (time_t)(ns / 1000000000);
    ts.tv_nsec = (long)(ns % 1000000000);
    tp = &ts;
  }
  r = ppoll(fds, (nfds_t)n, tp, 0);
#else
  int ms = ns < 0 ? -1 : (int)((ns + 999999) / 1000000);
  r = poll(fds, (nfds_t)n, ms);
#endif
  if (r <= 0)
    return 0;
  int fired = 0;
  pthread_mutex_lock(&lock);
  for (int k = 0; k < n; k++) {
    if (!fds[k].revents)
      continue;
    for (int i = 0; i < count; i++) {
      if (entries[i].fd == fds[k].fd && entries[i].armed) {
        entries[i].armed = 0;
        entries[i].fired = 1;
        fired++;
      }
    }
  }
  pthread_mutex_unlock(&lock);
  return fired;
}
