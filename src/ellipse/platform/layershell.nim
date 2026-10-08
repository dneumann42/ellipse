## wlr-layer-shell: dock an ellipse window to a screen edge.
##
## On Wayland compositors that implement `zwlr_layer_shell_v1` (Sway,
## Hyprland, KDE Plasma, niri, river, labwc, COSMIC, most wlroots window
## managers) a window can be a *layer surface*: anchored to screen edges,
## stacked in a layer above or below normal windows, optionally reserving
## an exclusive zone so maximized windows stop at it -- what bars, docks
## and panels are. GNOME's Mutter does not implement the protocol; there
## the platform falls back to an ordinary borderless window.
##
## The platform drives this module (see `WindowConfig.layer`); apps only
## describe the dock they want. The C glue in `wayland/` attaches the role
## to SDL's roleless window surface, so SDL keeps input and rendering.

type
  Edge* = enum
    ## The screen edge a layer surface docks to.
    edgeTop, edgeBottom, edgeLeft, edgeRight

  LayerLevel* = enum
    ## The compositor's stacking layers, bottom to top.
    layerBackground, layerBottom, layerTop, layerOverlay

  KeyboardMode* = enum
    ## Whether the surface takes keyboard focus: never, always (a launcher
    ## or lock screen) or when clicked (protocol v4, else never).
    keyboardNone, keyboardExclusive, keyboardOnDemand

  LayerConfig* = object
    ## A dock request. `thickness` is the size across the edge (a top bar's
    ## height); along the edge the surface spans the output unless `length`
    ## is set. `exclusive` reserves space: -1 = `thickness`, 0 = overlap
    ## other windows, > 0 that many pixels.
    enabled*: bool
    edge*: Edge
    level*: LayerLevel = layerTop
    thickness*: int32 = 32
    length*: int32 = 0
    exclusive*: int32 = -1
    margin*: int32 = 0
    keyboard*: KeyboardMode = keyboardOnDemand
    namespace*: string = "ellipse"

const
  AnchorTop = 1'i32
  AnchorBottom = 2'i32
  AnchorLeft = 4'i32
  AnchorRight = 8'i32

proc anchorFor*(edge: Edge; spanning: bool): int32 =
  ## The protocol anchor mask: the edge itself, plus both perpendicular
  ## edges when the surface spans the output.
  case edge
  of edgeTop:
    result = AnchorTop
    if spanning: result = result or AnchorLeft or AnchorRight
  of edgeBottom:
    result = AnchorBottom
    if spanning: result = result or AnchorLeft or AnchorRight
  of edgeLeft:
    result = AnchorLeft
    if spanning: result = result or AnchorTop or AnchorBottom
  of edgeRight:
    result = AnchorRight
    if spanning: result = result or AnchorTop or AnchorBottom

proc requestSize*(cfg: LayerConfig): tuple[width, height: int32] =
  ## The size to ask for: 0 along a spanning edge lets the compositor fill it.
  let along = if cfg.length > 0: cfg.length else: 0'i32
  case cfg.edge
  of edgeTop, edgeBottom: (along, cfg.thickness)
  of edgeLeft, edgeRight: (cfg.thickness, along)

import ./termmode

when defined(linux) and withSdl:
  {.compile: "wayland/layer_shell.c".}
  {.compile: "wayland/wlr-layer-shell-unstable-v1-protocol.c".}
  {.compile: "wayland/xdg-shell-protocol.c".}
  {.passL: "-lwayland-client".}

  proc ellipse_layer_available(display: pointer): int32 {.
    importc: "ellipse_layer_available".}
  proc ellipse_layer_attach(display, surface: pointer; ns: cstring;
                            layer, anchor, width, height, exclusive,
                            mt, mr, mb, ml, keyboard: int32): int32 {.
    importc: "ellipse_layer_attach".}
  proc ellipse_layer_take_size(w, h: ptr int32): int32 {.
    importc: "ellipse_layer_take_size".}
  proc ellipse_layer_closed(): int32 {.importc: "ellipse_layer_closed".}
  proc ellipse_layer_destroy() {.importc: "ellipse_layer_destroy".}

  proc layerShellAvailable*(display: pointer): bool =
    ## The compositor behind `display` (a `wl_display*`) offers layer shell.
    ellipse_layer_available(display) != 0

  proc attachLayer*(display, surface: pointer; cfg: LayerConfig): bool =
    ## Make `surface` (SDL's roleless `wl_surface*`) a layer surface and
    ## wait for the compositor's first configure.
    let (w, h) = requestSize(cfg)
    let excl = if cfg.exclusive < 0: cfg.thickness else: cfg.exclusive
    var ns = cfg.namespace
    var mt, mr, mb, ml = 0'i32
    case cfg.edge
    of edgeTop: mt = cfg.margin
    of edgeBottom: mb = cfg.margin
    of edgeLeft: ml = cfg.margin
    of edgeRight: mr = cfg.margin
    ellipse_layer_attach(display, surface, ns.toCString, int32(ord(cfg.level)),
      anchorFor(cfg.edge, cfg.length <= 0), w, h, excl, mt, mr, mb, ml,
      int32(ord(cfg.keyboard))) != 0

  proc takeLayerSize*(): tuple[changed: bool, width, height: int32] =
    ## The size the compositor configured; `changed` once per change.
    var w, h = 0'i32
    let c = ellipse_layer_take_size(addr w, addr h)
    (c != 0, w, h)

  proc layerClosed*(): bool = ellipse_layer_closed() != 0

  proc destroyLayer*() = ellipse_layer_destroy()
else:
  proc layerShellAvailable*(display: pointer): bool = false
  proc attachLayer*(display, surface: pointer; cfg: LayerConfig): bool = false
  proc takeLayerSize*(): tuple[changed: bool, width, height: int32] =
    (false, 0'i32, 0'i32)
  proc layerClosed*(): bool = false
  proc destroyLayer*() = discard
