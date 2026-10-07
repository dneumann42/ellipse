/* Wayland half of ellipse's cross-process dialog parenting (see
 * ../transient.c for the whole story).
 *
 * The dialog process imports its opener's toplevel through xdg-foreign v2
 * (SDL exports every toplevel and publishes the handle as a window
 * property; the opener passes it over) and makes its own toplevel a child
 * of it. With `modal` it also marks itself modal through xdg-dialog v1 --
 * GNOME then attaches it to the parent and dims the parent. Our registry
 * and objects live on SDL's display, on the default queue SDL dispatches.
 *
 * Protocol code generated with wayland-scanner (client-header and
 * private-code) from /usr/share/wayland-protocols:
 *   unstable/xdg-foreign/xdg-foreign-unstable-v2.xml
 *   staging/xdg-dialog/xdg-dialog-v1.xml (references xdg_toplevel, whose
 *   interface comes with xdg-shell-protocol.c)
 */

#include <string.h>
#include <stdint.h>
#include <SDL3/SDL.h>
#include <wayland-client.h>

#include "xdg-foreign-unstable-v2-client-protocol.h"
#include "xdg-dialog-v1-client-protocol.h"

static struct {
    struct wl_registry *registry;
    struct zxdg_importer_v2 *importer;
    struct xdg_wm_dialog_v1 *dialogs;
    struct zxdg_imported_v2 *imported;
    struct xdg_dialog_v1 *dialog;
} fw;

static void fw_global(void *data, struct wl_registry *reg, uint32_t name,
                      const char *iface, uint32_t version) {
    (void)data; (void)version;
    if (strcmp(iface, zxdg_importer_v2_interface.name) == 0 && !fw.importer)
        fw.importer = wl_registry_bind(reg, name, &zxdg_importer_v2_interface, 1);
    else if (strcmp(iface, xdg_wm_dialog_v1_interface.name) == 0 && !fw.dialogs)
        fw.dialogs = wl_registry_bind(reg, name, &xdg_wm_dialog_v1_interface, 1);
}

static void fw_global_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg; (void)name;
}

static const struct wl_registry_listener fw_registry_listener = {
    .global = fw_global,
    .global_remove = fw_global_remove,
};

static void fw_imported_destroyed(void *data, struct zxdg_imported_v2 *imp) {
    (void)data;
    /* the parent went away (or the handle was stale): just drop the link */
    zxdg_imported_v2_destroy(imp);
    if (fw.imported == imp) fw.imported = NULL;
}

static const struct zxdg_imported_v2_listener fw_imported_listener = {
    .destroyed = fw_imported_destroyed,
};

int ellipse_wayland_attach(SDL_Window *win, const char *handle, int modal) {
    SDL_PropertiesID props = SDL_GetWindowProperties(win);
    struct wl_display *display =
        SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, NULL);
    struct wl_surface *surface =
        SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, NULL);
    struct xdg_toplevel *toplevel =
        SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_XDG_TOPLEVEL_POINTER, NULL);
    if (!display || !surface) return 0;
    if (!fw.registry) {
        fw.registry = wl_display_get_registry(display);
        wl_registry_add_listener(fw.registry, &fw_registry_listener, NULL);
        wl_display_roundtrip(display);
    }
    int done = 0;
    if (fw.importer && handle && *handle && !fw.imported) {
        fw.imported = zxdg_importer_v2_import_toplevel(fw.importer, handle);
        zxdg_imported_v2_add_listener(fw.imported, &fw_imported_listener, NULL);
        zxdg_imported_v2_set_parent_of(fw.imported, surface);
        done = 1;
    }
    if (modal && fw.dialogs && toplevel && !fw.dialog) {
        fw.dialog = xdg_wm_dialog_v1_get_xdg_dialog(fw.dialogs, toplevel);
        xdg_dialog_v1_set_modal(fw.dialog);
    }
    wl_display_flush(display);
    return done;
}
