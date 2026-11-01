#include <SDL3/SDL.h>

typedef void (*EllipseFileDone)(int, const char *, const char *);
typedef struct {
    int id;
    EllipseFileDone done;
    char *path;
    char *error;
} EllipseFileRequest;

static void ellipse_file_deliver(void *userdata) {
    EllipseFileRequest *r = userdata;
    r->done(r->id, r->path, r->error);
    SDL_free(r->path);
    SDL_free(r->error);
    SDL_free(r);
}

void *ellipse_file_request(int id, EllipseFileDone done) {
    EllipseFileRequest *r = SDL_calloc(1, sizeof(*r));
    if (r) { r->id = id; r->done = done; }
    return r;
}

void ellipse_file_callback(void *userdata, const char * const *files, int filter) {
    EllipseFileRequest *r = userdata;
    (void)filter;
    if (!files) r->error = SDL_strdup(SDL_GetError());
    else if (files[0]) r->path = SDL_strdup(files[0]);
    /* SDL owns files; copy them before leaving its callback. Never call Nim
       on SDL's worker thread. Waiting also keeps r alive until delivery. */
    SDL_RunOnMainThread(ellipse_file_deliver, r, true);
}
