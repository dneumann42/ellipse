## SDL3 renderer for clay's render commands.
##
## Draws the commands produced by a clay layout pass using SDL3's 2D
## renderer: filled rectangles (rounded corners as triangle fans through
## `SDL_RenderGeometry`), borders as rounded contour rings (with cheap
## feathered edge smoothing), clip regions via
## `SDL_SetRenderClipRect`, and text through the SDL3_ttf renderer text
## engine (glyph atlas drawn on the same renderer). `measureText` feeds the
## very same fonts to clay's layout, so text boxes and glyphs agree.
##
## Primitives the built-in UI does not use yet -- images, custom commands,
## overlays, `letterSpacing` -- are skipped.
##
## Requires `initialize()` (the platform window/renderer) to have run first;
## links against SDL3_ttf, which is part of the SDL3 ecosystem setup.

{.passL: "-lSDL3_ttf".}

import std/[math, tables, strutils]

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

## --- rounded-rectangle geometry -------------------------------------------------
##
## Fills and borders share one contour generator, `roundedContour`: the clockwise
## boundary of a rounded rectangle as 4 quarter arcs of `seg` chords each plus the
## straight edges between them (radius 0 => the arc collapses to the corner point).
## Outer/inner/expanded contours of one shape use the same `seg`, so their points
## pair up by index -- which is what lets a border triangulate as a ring between
## two contours and lets the smoothing bands tile without overlapping.
##
## SDL3's 2D geometry has no antialiasing, so rounded shapes get two thin
## translucent outline bands hugging their edges (and, for border rings, hugging
## the hole) as cheap coverage smoothing: the 0..0.5px band carries 3/4 of the
## colour's alpha, the 0.5..1px band 1/4, approximating the ideal coverage ramp.

func arcSegments(radius: float32): int =
  ## Chords of the quarter arc deviate from the true circle by
  ## `radius * (1 - cos(pi/2 / seg))`; solve for the smallest `seg` keeping that
  ## under ~0.08px (sub-pixel, so large radii stop looking like polygons),
  ## clamped to 1..20.
  if radius <= 0.0:
    return 1
  let keep = 1.0 - 0.08 / radius
  if keep < 0.36:   # arccos(1 - 0.08/r) below pi/8: just use the cap
    return 20
  result = ceil((PI / 2.0) / arccos(keep)).int
  if result < 1:
    result = 1
  elif result > 20:
    result = 20

func clampCorners(r: Rect; c: CornerRadius): CornerRadius =
  ## Radii clamped into the shape: non-negative, never past half the box's
  ## smaller side (two opposite corners can meet, never cross).
  let lim = min(r.width, r.height) / 2.0
  CornerRadius(
    topLeft: min(max(c.topLeft, 0.0), lim),
    topRight: min(max(c.topRight, 0.0), lim),
    bottomLeft: min(max(c.bottomLeft, 0.0), lim),
    bottomRight: min(max(c.bottomRight, 0.0), lim))

func cornerSize(c: CornerRadius): float32 =
  max(max(c.topLeft, c.topRight), max(c.bottomLeft, c.bottomRight))

func isRounded(c: CornerRadius): bool =
  c.topLeft > 0.0 or c.topRight > 0.0 or c.bottomLeft > 0.0 or c.bottomRight > 0.0

func grow(r: Rect; d: float32): Rect =
  ## Expand (`d` > 0) or shrink (`d` < 0) a rounded rectangle's straight edges.
  ## The outward parallel curve of a rounded rect is exactly the rounded rect
  ## grown by `d` with its radii grown too -- see the `grow` for CornerRadius.
  Rect(x: r.x - d, y: r.y - d, width: r.width + 2.0 * d, height: r.height + 2.0 * d)

func grow(c: CornerRadius; d: float32): CornerRadius =
  CornerRadius(topLeft: c.topLeft + d, topRight: c.topRight + d,
               bottomLeft: c.bottomLeft + d, bottomRight: c.bottomRight + d)

const
  QuarterTurn = float32(PI / 2.0)
  BandInner = 0.75'f32   # alpha of the edge-adjacent smoothing band
  BandOuter = 0.25'f32   # ... and of the far half-pixel band

proc addArc(pts: var seq[SDL_FPoint]; cx, cy, rad, startAngle, step: float32;
            seg: int) =
  ## `seg` + 1 points sweeping a quarter turn around `(cx, cy)` from
  ## `startAngle` (radians, screen space: x right, y down, angles clockwise).
  var k = 0
  while k <= seg:
    let a = startAngle + step * float32(k)
    pts.add(SDL_FPoint(x: cx + rad * cos(a), y: cy + rad * sin(a)))
    inc k

proc roundedContour(r: Rect; c: CornerRadius; seg: int): seq[SDL_FPoint] =
  ## Clockwise boundary starting on the left end of the top edge. Each corner
  ## contributes `seg` + 1 points; a 0-radius corner collapses to its tip.
  let step = QuarterTurn / float32(seg)
  var pts: seq[SDL_FPoint] = @[]
  addArc(pts, r.x + c.topLeft, r.y + c.topLeft, c.topLeft,
         2.0'f32 * QuarterTurn, step, seg)   # left edge -> top edge (180..270)
  addArc(pts, r.x + r.width - c.topRight, r.y + c.topRight, c.topRight,
         3.0'f32 * QuarterTurn, step, seg)   # top edge -> right edge (270..360)
  addArc(pts, r.x + r.width - c.bottomRight, r.y + r.height - c.bottomRight,
         c.bottomRight, 4.0'f32 * QuarterTurn, step, seg)  # right -> bottom
  addArc(pts, r.x + c.bottomLeft, r.y + r.height - c.bottomLeft, c.bottomLeft,
         5.0'f32 * QuarterTurn, step, seg)   # bottom -> left (90..180)
  return pts

## A band is a ring of quads between two same-length contours. All triangles of
## one shape (core fan, ring, smoothing bands) accumulate into a single vertex
## list so the whole element ships in one `SDL_RenderGeometry` call.

proc addBand(verts: var seq[SDL_Vertex]; a, b: seq[SDL_FPoint];
             col: Color; alpha: float32) =
  ## Ring between contours `a` and `b` (paired by index, same winding).
  let vc = SDL_FColor(r: col.r / 255.0, g: col.g / 255.0, b: col.b / 255.0,
                      a: col.a / 255.0 * alpha)
  var i = 0
  while i < a.len:
    let j = (i + 1) mod a.len
    verts.add(SDL_Vertex(position: a[i], color: vc, tex_coord: SDL_FPoint()))
    verts.add(SDL_Vertex(position: a[j], color: vc, tex_coord: SDL_FPoint()))
    verts.add(SDL_Vertex(position: b[j], color: vc, tex_coord: SDL_FPoint()))
    verts.add(SDL_Vertex(position: a[i], color: vc, tex_coord: SDL_FPoint()))
    verts.add(SDL_Vertex(position: b[j], color: vc, tex_coord: SDL_FPoint()))
    verts.add(SDL_Vertex(position: b[i], color: vc, tex_coord: SDL_FPoint()))
    inc i

func insetRect(r: Rect; d: float32): Rect =
  Rect(x: r.x + d, y: r.y + d, width: r.width - 2.0 * d, height: r.height - 2.0 * d)

func insetCorners(c: CornerRadius; d: float32): CornerRadius =
  CornerRadius(topLeft: max(0.0, c.topLeft - d), topRight: max(0.0, c.topRight - d),
               bottomLeft: max(0.0, c.bottomLeft - d),
               bottomRight: max(0.0, c.bottomRight - d))

proc featherContour(r: Rect; c: CornerRadius; seg: int; d: float32;
                    inside: bool): seq[SDL_FPoint] =
  ## The contour offset `d` from `r`/`c`: growing outward, or shrinking into
  ## the hole when `inside` marks a hole rim.
  if inside:
    let rr = insetRect(r, d)
    roundedContour(rr, clampCorners(rr, insetCorners(c, d)), seg)
  else:
    roundedContour(grow(r, d), grow(c, d), seg)

proc addFeathering(verts: var seq[SDL_Vertex]; r: Rect; c: CornerRadius;
                   seg: int; col: Color; inside: bool) =
  ## Two half-pixel smoothing bands hugging the contour: with `inside` false
  ## they grow outward from the shape's edge; with `inside` true the contour
  ## is a hole's rim and the bands shrink into the hole. The inward offset of
  ## a rounded rect keeps straight edges exact and only loses a sub-pixel
  ## sliver near corners whose radius is under the band width -- slivers blend
  ## nothing twice, unlike the overlap the naive version would produce.
  let base = featherContour(r, c, seg, 0.0, inside)
  let mid = featherContour(r, c, seg, 0.5, inside)
  let far = featherContour(r, c, seg, 1.0, inside)
  addBand(verts, base, mid, col, BandInner)
  addBand(verts, mid, far, col, BandOuter)

proc fillRounded(ren: ptr SDL_Renderer; r: Rect; corner: CornerRadius; col: Color) =
  ## Rounded rectangle as a center fan (the clamped shape is convex) plus two
  ## outward smoothing bands.
  let c = clampCorners(r, corner)
  let seg = arcSegments(cornerSize(c))
  let pts = roundedContour(r, c, seg)
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
  addFeathering(verts, r, c, seg, col, inside = false)
  if verts.len > 0:
    discard SDL_RenderGeometry(ren, nil, addr verts[0], int32(verts.len), nil, 0)

proc strokeRounded(ren: ptr SDL_Renderer; r: Rect; bw: BorderWidth;
                   corner: CornerRadius; col: Color) =
  ## A border with rounded corners: the ring between the outer rounded rect and
  ## its inner offset -- the per-side border widths inset the inner edge, and
  ## each inner corner keeps `outerRadius - adjacentBorderWidth` so the band
  ## stays visually uniform through the curve. Smoothing bands hug both edges.
  let c = clampCorners(r, corner)
  let l = float32(bw.left)
  let t = float32(bw.top)
  let rt = float32(bw.right)
  let b = float32(bw.bottom)
  let iw = r.width - l - rt
  let ih = r.height - t - b
  let seg = arcSegments(cornerSize(c))
  if iw <= 0.0 or ih <= 0.0:
    fillRounded(ren, r, c, col)
    return
  let inner = Rect(x: r.x + l, y: r.y + t, width: iw, height: ih)
  let ci = clampCorners(inner, CornerRadius(
    topLeft: max(0.0, c.topLeft - min(l, t)),
    topRight: max(0.0, c.topRight - min(t, rt)),
    bottomLeft: max(0.0, c.bottomLeft - min(l, b)),
    bottomRight: max(0.0, c.bottomRight - min(rt, b))))
  var verts: seq[SDL_Vertex] = @[]
  addBand(verts, roundedContour(r, c, seg), roundedContour(inner, ci, seg),
          col, 1.0)
  addFeathering(verts, r, c, seg, col, inside = false)
  if iw >= 2.0 and ih >= 2.0:
    addFeathering(verts, inner, ci, seg, col, inside = true)
  if verts.len > 0:
    discard SDL_RenderGeometry(ren, nil, addr verts[0], int32(verts.len), nil, 0)

proc fillStrip(ren: ptr SDL_Renderer; x, y, w, h: float32; col: Color) =
  if w <= 0.0 or h <= 0.0:
    return
  fillRect(ren, rect(x, y, w, h), col)

func packColor(col: Color): uint64 =
  (uint64(col.r.toU8) or uint64(col.g.toU8) shl 8 or
   uint64(col.b.toU8) shl 16 or uint64(col.a.toU8) shl 24)

proc textFor(key: TextKey, col: Color): nil ptr TTF_Text =
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
      if cmd.borderCorner.isRounded:
        strokeRounded(ren, cmd.box, cmd.borderWidth, cmd.borderCorner,
                      cmd.borderColor)
      else:
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
