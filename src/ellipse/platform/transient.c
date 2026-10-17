/* Cross-process window parenting for ellipse's dialog windows.
 *
 * A dialog that runs as its own process still belongs to the window that
 * opened it: the window manager should stack it above that window, centre
 * it there, and (when modal) treat the pair as one. SDL can only parent
 * windows of the same process, so this file speaks each platform's own
 * protocol, given a *token* naming the parent window:
 *
 *   wayland:<handle>   xdg-foreign v2 export handle (SDL exports every
 *                      toplevel); the child imports it and sets itself as
 *                      a child, then marks itself modal via xdg-dialog v1
 *   x11:<xid>          WM_TRANSIENT_FOR on the child (libX11 is loaded at
 *                      runtime through SDL, so nothing links against it)
 *   win32:<hwnd>       the child's owner window (GWLP_HWNDPARENT)
 *
 * A token for another windowing system than the child's (an X11 parent
 * and a Wayland child, say) is ignored: the dialog then opens unparented.
 *
 * The Wayland half lives in wayland/dialog_parent.c, compiled only for
 * Linux targets (with the protocol code it needs); `transient.nim` routes
 * `wayland:` tokens there.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <SDL3/SDL.h>

static int driver_is(const char *name) {
    const char *d = SDL_GetCurrentVideoDriver();
    return d && strcmp(d, name) == 0;
}

static const char *after_prefix(const char *token, const char *prefix) {
    size_t n = strlen(prefix);
    if (!token || strncmp(token, prefix, n) != 0) return NULL;
    return token + n;
}

/* ---- X11 ----------------------------------------------------------------- */

#if defined(__linux__) || defined(__unix__)
typedef int (*XSetTransientForHintFn)(void *display, unsigned long w,
                                      unsigned long parent);
typedef int (*XFlushFn)(void *display);

static int x11_attach(SDL_Window *win, unsigned long parent) {
    SDL_PropertiesID props = SDL_GetWindowProperties(win);
    void *display = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_X11_DISPLAY_POINTER, NULL);
    unsigned long xid =
        (unsigned long)SDL_GetNumberProperty(props, SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
    if (!display || !xid || !parent) return 0;
    SDL_SharedObject *lib = SDL_LoadObject("libX11.so.6");
    if (!lib) return 0;
    XSetTransientForHintFn set =
        (XSetTransientForHintFn)SDL_LoadFunction(lib, "XSetTransientForHint");
    XFlushFn flush = (XFlushFn)SDL_LoadFunction(lib, "XFlush");
    int ok = 0;
    if (set) {
        set(display, xid, parent);
        if (flush) flush(display);
        ok = 1;
    }
    /* libX11 stays loaded: SDL's X11 backend holds it anyway */
    return ok;
}
#endif

/* ---- Windows ------------------------------------------------------------- */

#if defined(_WIN32)
#include <windows.h>

static HWND win32_hwnd(SDL_Window *win) {
    return (HWND)SDL_GetPointerProperty(SDL_GetWindowProperties(win),
                                        SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
}

static int win32_attach(SDL_Window *win, unsigned long long parent) {
    HWND child = win32_hwnd(win);
    if (!child || !parent) return 0;
    /* GWLP_HWNDPARENT on a top-level window sets its *owner*: it stays
     * above the owner, minimizes with it, and has no taskbar button. */
    SetWindowLongPtrW(child, GWLP_HWNDPARENT, (LONG_PTR)parent);
    SetForegroundWindow(child);
    return 1;
}
#endif

/* ---- API ----------------------------------------------------------------- */

/* Write the token naming `win` into `buf` ("" when this platform has none
 * yet -- e.g. the Wayland export handle arrives a roundtrip after the
 * window maps). Returns the token's length. */
int ellipse_parent_token(SDL_Window *win, char *buf, int cap) {
    if (!win || !buf || cap <= 0) return 0;
    buf[0] = 0;
    SDL_PropertiesID props = SDL_GetWindowProperties(win);
    if (driver_is("wayland")) {
        const char *h = SDL_GetStringProperty(props,
            SDL_PROP_WINDOW_WAYLAND_XDG_TOPLEVEL_EXPORT_HANDLE_STRING, NULL);
        if (h && *h) SDL_snprintf(buf, (size_t)cap, "wayland:%s", h);
    } else if (driver_is("x11")) {
        Sint64 xid = SDL_GetNumberProperty(props, SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
        if (xid) SDL_snprintf(buf, (size_t)cap, "x11:%llu", (unsigned long long)xid);
    } else if (driver_is("windows")) {
        void *hwnd = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
        if (hwnd) SDL_snprintf(buf, (size_t)cap, "win32:%llu",
                               (unsigned long long)(uintptr_t)hwnd);
    }
    return (int)strlen(buf);
}

/* Make `win` (a dialog process's window) a child of the window `token`
 * names. Returns 1 when a parent link was made. */
int ellipse_attach_parent(SDL_Window *win, const char *token, int modal) {
    if (!win || !token) return 0;
    const char *rest;
#if defined(__linux__) || defined(__unix__)
    if ((rest = after_prefix(token, "x11:")) && driver_is("x11"))
        return x11_attach(win, strtoul(rest, NULL, 10));
#endif
#if defined(_WIN32)
    if ((rest = after_prefix(token, "win32:")) && driver_is("windows"))
        return win32_attach(win, _strtoui64(rest, NULL, 10));
#endif
    (void)rest; (void)modal;
    return 0;
}

/* Enable or disable input to `win` -- Windows' native modality: the owner
 * of a modal dialog is disabled until the dialog closes. A no-op on the
 * other platforms, whose window managers have no such state. */
void ellipse_window_enable(SDL_Window *win, int enabled) {
#if defined(_WIN32)
    HWND h = win32_hwnd(win);
    if (h) {
        EnableWindow(h, enabled ? TRUE : FALSE);
        if (enabled) SetForegroundWindow(h);
    }
#else
    (void)win; (void)enabled;
#endif
}

/* ---- processes ------------------------------------------------------------ */

/* Spawn `args` (NUL-separated, `count` of them) with stdout piped back to
 * us and stdin/stderr as SDL defaults them (null / inherited). Building
 * the argv here keeps the cstring array out of the Nim side. */
SDL_Process *ellipse_spawn(const char *joined, int count) {
    if (!joined || count <= 0) return NULL;
    const char **argv = (const char **)SDL_calloc((size_t)count + 1, sizeof(char *));
    if (!argv) return NULL;
    const char *p = joined;
    for (int i = 0; i < count; i++) {
        argv[i] = p;
        p += strlen(p) + 1;
    }
    SDL_PropertiesID props = SDL_CreateProperties();
    SDL_SetPointerProperty(props, SDL_PROP_PROCESS_CREATE_ARGS_POINTER, (void *)argv);
    SDL_SetNumberProperty(props, SDL_PROP_PROCESS_CREATE_STDIN_NUMBER, SDL_PROCESS_STDIO_NULL);
    SDL_SetNumberProperty(props, SDL_PROP_PROCESS_CREATE_STDOUT_NUMBER, SDL_PROCESS_STDIO_APP);
    SDL_SetNumberProperty(props, SDL_PROP_PROCESS_CREATE_STDERR_NUMBER, SDL_PROCESS_STDIO_INHERITED);
    SDL_Process *proc = SDL_CreateProcessWithProperties(props);
    SDL_DestroyProperties(props);
    SDL_free(argv);
    return proc;
}

/* Read whatever stdout has ready into `buf` without blocking. Returns the
 * byte count; -1 once the stream is at EOF or broken. */
int ellipse_read_ready(SDL_Process *proc, char *buf, int cap) {
    SDL_IOStream *io = SDL_GetProcessOutput(proc);
    if (!io) return -1;
    size_t n = SDL_ReadIO(io, buf, (size_t)cap);
    if (n > 0) return (int)n;
    SDL_IOStatus st = SDL_GetIOStatus(io);
    if (st == SDL_IO_STATUS_EOF || st == SDL_IO_STATUS_ERROR) return -1;
    return 0;
}
