/* The window backend's half of fdwatch: the helper thread wakes SDL's
 * event queue with one user event (SDL_PushEvent is thread-safe). Only
 * compiled when SDL is built in (platform.nim, `withSdl`). */

#include <SDL3/SDL.h>

int ellipse_fdwatch_use_thread(void (*wake)(void));

static Uint32 wake_type = 0;

static void push_wake(void) {
  SDL_Event ev;
  SDL_zero(ev);
  ev.type = wake_type;
  SDL_PushEvent(&ev);
}

/* Register the event type and start the helper thread; returns the type
 * (0 when SDL could not register one). */
unsigned int ellipse_sdl_fdwake_start(void) {
  if (wake_type == 0) {
    wake_type = SDL_RegisterEvents(1);
    if (wake_type == 0)
      return 0;
  }
  if (!ellipse_fdwatch_use_thread(push_wake))
    return 0;
  return wake_type;
}
