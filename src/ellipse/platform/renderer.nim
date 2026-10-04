## SDL3 renderer for clay's render commands.
##
## Draws the commands produced by a clay layout pass using SDL3's 2D
## renderer: filled rectangles (rounded corners as triangle fans through
## `SDL_RenderGeometry`), borders as fill strips, clip regions via
## `SDL_SetRenderClipRect`, and text through the SDL3_ttf renderer text
## engine (glyph atlas drawn on the same renderer). `measureText` feeds the
## very same fonts to clay's layout, so text boxes and glyphs agree.
##
## Primitives the built-in UI does not use yet -- images, custom commands,
## overlays, border corner radii, `letterSpacing` -- are skipped.
##
## Requires `initialize()` (the platform window/renderer) to have run first;
## links against SDL3_ttf, which is part of the SDL3 ecosystem setup.

{.passL: "-lSDL3_ttf".}

import std/[tables, strutils]

import clay
import ./platform

## --- SDL3 / SDL3_ttf bindings ---------------------------------------------------

type
  SDL_FPoint {.importc: "SDL_FPoint", header: "<SDL3/SDL.h>".} = object
    x, y: float32

  SDL_FRect {.importc: "SDL_FRect", header: "<SDL3/SDL.h>".} = object
    x, y, w, h: float32

  SDL_Rect {.importc: "SDL_Rect", header: "<SDL3/SDL.h>".} = object
    x, y, w, h: int32

  SDL_FColor {.importc: "SDL_FColor", header: "<SDL3/SDL.h>".} = object
    r, g, b, a: float32

  SDL_Vertex {.importc: "SDL_Vertex", header: "<SDL3/SDL.h>".} = object
    position: SDL_FPoint
    color: SDL_FColor          # normalized 0-1 channels in SDL3
    tex_coord: SDL_FPoint

  TTF_Font {.importc: "TTF_Font", header: "<SDL3_ttf/SDL_ttf.h>".} = object
  TTF_TextEngine {.importc: "TTF_TextEngine", header: "<SDL3_ttf/SDL_ttf.h>".} = object
  TTF_Text {.importc: "TTF_Text", header: "<SDL3_ttf/SDL_ttf.h>".} = object

const
  BlendModeBlend = 1'i32   # SDL_BLENDMODE_BLEND

proc SDL_SetRenderDrawColor(ren: ptr SDL_Renderer; r, g, b, a: uint8): bool {.
  importc: "SDL_SetRenderDrawColor", header: "<SDL3/SDL.h>".}
proc SDL_SetRenderDrawBlendMode(ren: ptr SDL_Renderer; mode: int32): bool {.
  importc: "SDL_SetRenderDrawBlendMode", header: "<SDL3/SDL.h>".}
proc SDL_RenderFillRect(ren: ptr SDL_Renderer; rect: ptr SDL_FRect): bool {.
  importc: "SDL_RenderFillRect", header: "<SDL3/SDL.h>".}
proc SDL_RenderGeometry(ren: ptr SDL_Renderer; texture: nil pointer;
                        verts: ptr SDL_Vertex; numVerts: int32;
                        indices: nil ptr int32; numIndices: int32): bool {.
  importc: "SDL_RenderGeometry", header: "<SDL3/SDL.h>".}
proc SDL_SetRenderClipRect(ren: ptr SDL_Renderer; rect: nil ptr SDL_Rect): bool {.
  importc: "SDL_SetRenderClipRect", header: "<SDL3/SDL.h>".}

proc TTF_Init(): bool {.importc: "TTF_Init", header: "<SDL3_ttf/SDL_ttf.h>".}
proc TTF_OpenFont(file: cstring; ptsize: float32): nil ptr TTF_Font {.
  importc: "TTF_OpenFont", header: "<SDL3_ttf/SDL_ttf.h>".}
proc TTF_CreateRendererTextEngine(ren: ptr SDL_Renderer): nil ptr TTF_TextEngine {.
  importc: "TTF_CreateRendererTextEngine", header: "<SDL3_ttf/SDL_ttf.h>".}
proc TTF_CreateText(engine: nil ptr TTF_TextEngine; font: nil ptr TTF_Font;
                    text: nil cstring; length: int): nil ptr TTF_Text {.
  importc: "TTF_CreateText", header: "<SDL3_ttf/SDL_ttf.h>".}
proc TTF_SetTextColorFloat(text: nil ptr TTF_Text; r, g, b, a: float32): bool {.
  importc: "TTF_SetTextColorFloat", header: "<SDL3_ttf/SDL_ttf.h>".}
proc TTF_DrawRendererText(text: nil ptr TTF_Text; x, y: float32): bool {.
  importc: "TTF_DrawRendererText", header: "<SDL3_ttf/SDL_ttf.h>".}
proc TTF_GetStringSize(font: nil ptr TTF_Font; text: cstring; length: int;
                       w, h: ptr int32): bool {.
  importc: "TTF_GetStringSize", header: "<SDL3_ttf/SDL_ttf.h>".}

## --- state -----------------------------------------------------------------------

var
  fontPath*: string = "assets/fonts/inter/Inter-Regular.ttf"
    ## UI font, resolved relative to the working directory (the repo root
    ## when run via `make run`). Set before `initializeRenderer` to override;
    ## `fontFallbackPath` is tried if this one cannot be opened.

  fontFallbackPath = "/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf"
    ## System fallback so text still renders if the vendored font is missing.

type
  TextKey = tuple
    ## Cache key for an immutable rendered string: `col` packs rgba as one
    ## uint64 so the tuple stays within the 3-component hashable limit.
    text: string
    size: int
    col: uint64

var
  fonts: Table[int, nil ptr TTF_Font]
  texts: Table[TextKey, nil ptr TTF_Text]
  textEngine: nil ptr TTF_TextEngine
  clipStack: seq[SDL_Rect] = @[]

proc fontFor(size: int): nil ptr TTF_Font =
  ## One opened TTF font per pixel size (TTF point size == pixel size at
  ## the renderer's default 72 dpi). Returns nil when no font could be
  ## opened (the measure/draw paths then fall back / skip).
  let cached = fonts.getOrDefault(size)
  if cached != nil:
    return cached
  var path = fontPath
  var font = TTF_OpenFont(path.toCString, float32(size))
  if font == nil:
    var fallback = fontFallbackPath
    font = TTF_OpenFont(fallback.toCString, float32(size))
  if font == nil:
    return font
  fonts[size] = font
  return font

## --- small helpers ----------------------------------------------------------------

func toU8(v: float32): uint8 =
  uint8(clamp(v, 0.0, 255.0).int)

func roundPx(v: float32): int =
  ## Nearest-pixel rounding for glyph origins (int truncation is toward 0,
  ## and layout coords are non-negative).
  int(v + 0.5)

proc setColor(ren: ptr SDL_Renderer; col: Color) =
  discard SDL_SetRenderDrawColor(ren, col.r.toU8, col.g.toU8, col.b.toU8, col.a.toU8)

proc fillRect(ren: ptr SDL_Renderer; r: Rect; col: Color) =
  var fr = SDL_FRect(x: r.x, y: r.y, w: r.width, h: r.height)
  setColor(ren, col)
  discard SDL_RenderFillRect(ren, addr fr)

# Unit circle sampled every 22.5 degrees (16 steps), so rounded corners need
# no float math module: index = round(angle / 22.5) mod 16.
const
  CosSteps = [1.0'f32, 0.9238795'f32, 0.7071068'f32, 0.3826834'f32, 0.0'f32,
              -0.3826834'f32, -0.7071068'f32, -0.9238795'f32, -1.0'f32,
              -0.9238795'f32, -0.7071068'f32, -0.3826834'f32, 0.0'f32,
              0.3826834'f32, 0.7071068'f32, 0.9238795'f32]
  SinSteps = [0.0'f32, 0.3826834'f32, 0.7071068'f32, 0.9238795'f32, 1.0'f32,
              0.9238795'f32, 0.7071068'f32, 0.3826834'f32, 0.0'f32,
              -0.3826834'f32, -0.7071068'f32, -0.9238795'f32, -1.0'f32,
              -0.9238795'f32, -0.7071068'f32, -0.3826834'f32]

proc addArc(pts: var seq[SDL_FPoint]; cx, cy, rad: float32; base: int) =
  ## Five points (both endpoints inclusive) around the corner center
  ## `(cx, cy)`, starting at circle step `base` and sweeping a quarter turn.
  var k = 0
  while k <= 4:
    let idx = (base + k) mod 16
    pts.add(SDL_FPoint(x: cx + rad * CosSteps[idx], y: cy + rad * SinSteps[idx]))
    inc k

proc fillRounded(ren: ptr SDL_Renderer; r: Rect; corner: CornerRadius; col: Color) =
  ## Rounded rectangle as a center fan: one triangle per consecutive pair of
  ## boundary points (arcs at each corner, straight edges in between).
  let lim = min(r.width, r.height) / 2.0
  let tl = min(max(corner.topLeft, 0.0), lim)
  let tr = min(max(corner.topRight, 0.0), lim)
  let br = min(max(corner.bottomRight, 0.0), lim)
  let bl = min(max(corner.bottomLeft, 0.0), lim)

  var pts: seq[SDL_FPoint] = @[]
  addArc(pts, r.x + tl, r.y + tl, tl, 8)                        # top-left
  addArc(pts, r.x + r.width - tr, r.y + tr, tr, 12)             # top-right
  addArc(pts, r.x + r.width - br, r.y + r.height - br, br, 16)  # bottom-right
  addArc(pts, r.x + bl, r.y + r.height - bl, bl, 20)            # bottom-left

  let vc = SDL_FColor(r: col.r / 255.0, g: col.g / 255.0, b: col.b / 255.0,
                      a: col.a / 255.0)
  let center = SDL_FPoint(x: r.x + r.width / 2.0, y: r.y + r.height / 2.0)
  var verts: seq[SDL_Vertex] = @[]
  var i = 0
  while i < pts.len:
    let j = (i + 1) mod pts.len
    verts.add(SDL_Vertex(position: center, color: vc, tex_coord: SDL_FPoint()))
    verts.add(SDL_Vertex(position: pts[i], color: vc, tex_coord: SDL_FPoint()))
    verts.add(SDL_Vertex(position: pts[j], color: vc, tex_coord: SDL_FPoint()))
    inc i
  discard SDL_RenderGeometry(ren, nil, addr verts[0], int32(verts.len), nil, 0)

proc fillStrip(ren: ptr SDL_Renderer; x, y, w, h: float32; col: Color) =
  if w <= 0.0 or h <= 0.0:
    return
  fillRect(ren, rect(x, y, w, h), col)

func packColor(col: Color): uint64 =
  (uint64(col.r.toU8) or uint64(col.g.toU8) shl 8 or
   uint64(col.b.toU8) shl 16 or uint64(col.a.toU8) shl 24)

proc textFor(key: TextKey, col: Color): nil ptr TTF_Text =
  ## One immutable `TTF_Text` per (string, size, color): the SDL3_ttf
  ## renderer text engine caches glyph atlas refs inside the text's layout,
  ## and mutating a text after it has been drawn (string/font swaps on a
  ## shared object) leaves stale quads -- artifact slivers of other glyphs.
  ## Creating texts once and never touching them again is the supported
  ## immediate-mode pattern. Entries live for the process lifetime (they are
  ## few for a menu-driven UI); a text-heavy app would want an LRU with
  ## TTF_DestroyText eviction.
  let cached = texts.getOrDefault(key)
  if cached != nil:
    return cached
  let font = fontFor(key.size)
  if font == nil:
    return nil
  var t = key.text
  let text = TTF_CreateText(textEngine, font, t.toCString, t.len)
  if text == nil:
    return nil
  discard TTF_SetTextColorFloat(text, col.r / 255.0, col.g / 255.0,
                                col.b / 255.0, col.a / 255.0)
  texts[key] = text
  return text

proc drawTextCmd(text: string; x, y: float32; col: Color; size: int) =
  ## Draw at (x, y) = top-left of the text box, rounding to the pixel grid:
  ## fractional origins make the engine resample glyph edges and smear.
  let item = textFor((text: text, size: size, col: packColor(col)), col)
  if item == nil:
    return
  discard TTF_DrawRendererText(item, float32(roundPx(x)), float32(roundPx(y)))

## --- public API ----------------------------------------------------------------------

proc initializeRenderer*() {.raises.} =
  ## Prepare fonts + text engine on the platform's renderer. Call after
  ## `platform.initialize()` and before the first frame.
  if not TTF_Init():
    raise Failure
  textEngine = TTF_CreateRendererTextEngine(sdlRenderer())
  if textEngine == nil:
    raise Failure
  # alpha-enabled fills for translucent backgrounds and glyph edges
  discard SDL_SetRenderDrawBlendMode(sdlRenderer(), BlendModeBlend)

proc measureText*(text: string; cfg: TextConfig): Size =
  ## clay `MeasureFn`: real metrics from the font at `cfg.fontSize`.
  ## Fallback: the uniform-cell estimate, on measurement failure.
  let font = fontFor(cfg.fontSize.int)
  if font != nil:
    var w = 0'i32
    var h = 0'i32
    var t = text
    if TTF_GetStringSize(font, t.toCString, t.len, addr w, addr h):
      return Size(width: float32(w), height: float32(h))
  return Size(width: float32(text.len) * float32(cfg.fontSize),
              height: float32(cfg.fontSize))

proc drawCommands*() {.raises.} =
  ## Paint the current context's commands from the last `endLayout`, in
  ## order. Call once per frame from the app's render hook (after the
  ## platform cleared and before it presents).
  let ren = sdlRenderer()
  let cmds = renderCommands()
  for cmd in cmds:
    case cmd.kind
    of renderRectangle:
      if cmd.rectCorner.topLeft > 0.0 or cmd.rectCorner.topRight > 0.0 or
          cmd.rectCorner.bottomLeft > 0.0 or cmd.rectCorner.bottomRight > 0.0:
        fillRounded(ren, cmd.box, cmd.rectCorner, cmd.fill)
      else:
        fillRect(ren, cmd.box, cmd.fill)
    of renderBorder:
      let bw = cmd.borderWidth
      fillStrip(ren, cmd.box.x, cmd.box.y, cmd.box.width, float32(bw.top),
                cmd.borderColor)
      fillStrip(ren, cmd.box.x, cmd.box.y + cmd.box.height - float32(bw.bottom),
                cmd.box.width, float32(bw.bottom), cmd.borderColor)
      fillStrip(ren, cmd.box.x, cmd.box.y + float32(bw.top), float32(bw.left),
                cmd.box.height - float32(bw.top) - float32(bw.bottom),
                cmd.borderColor)
      fillStrip(ren, cmd.box.x + cmd.box.width - float32(bw.right),
                cmd.box.y + float32(bw.top), float32(bw.right),
                cmd.box.height - float32(bw.top) - float32(bw.bottom),
                cmd.borderColor)
    of renderText:
      drawTextCmd(lineText(cmd), cmd.box.x, cmd.box.y, cmd.textColor,
                  cmd.fontSize.int)
    of renderClipStart:
      var cr = SDL_Rect(x: cmd.box.x.int32, y: cmd.box.y.int32,
                        w: cmd.box.width.int32, h: cmd.box.height.int32)
      discard SDL_SetRenderClipRect(ren, addr cr)
      clipStack.add cr
    of renderClipEnd:
      if clipStack.len > 0:
        clipStack.setLen(clipStack.len - 1)
        if clipStack.len > 0:
          discard SDL_SetRenderClipRect(ren, addr clipStack[^1])
        else:
          discard SDL_SetRenderClipRect(ren, nil)
    of renderImage, renderCustom, renderOverlayStart, renderOverlayEnd:
      discard   # not produced by the built-in UI (yet)
