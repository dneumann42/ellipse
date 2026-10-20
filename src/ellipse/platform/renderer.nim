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

import ./termmode

when withSdl:
  {.passL: "-lSDL3_ttf".}

import std/[math, os, tables, strutils, envvars, syncio]

import clay
import ./platform
import ../failure
import ./damage
import ../terminal/cellbuf
# `as` alias: standard nim would otherwise read the module symbol
# `cellwidth` as a redefinition of termmode's `cellWidth`.
import ../terminal/cellwidth as termcellwidth
export cellbuf

when withSdl:
  ## --- SDL3 / SDL3_ttf bindings ---------------------------------------------------

  type
    SDL_FPoint {.importc: "SDL_FPoint", header: "<SDL3/SDL.h>".} = object
      x, y: float32

    SDL_FRect {.importc: "SDL_FRect", header: "<SDL3/SDL.h>".} = object
      x, y, w, h: float32

    SDL_Rect {.importc: "SDL_Rect", header: "<SDL3/SDL.h>".} = object
      x, y, w, h: int32

    SDL_Surface {.importc: "SDL_Surface", header: "<SDL3/SDL.h>".} = object
      w, h, pitch: int32
      pixels: pointer

    SDL_FColor {.importc: "SDL_FColor", header: "<SDL3/SDL.h>".} = object
      r, g, b, a: float32

    SDL_Vertex {.importc: "SDL_Vertex", header: "<SDL3/SDL.h>".} = object
      position: SDL_FPoint
      color: SDL_FColor          # normalized 0-1 channels in SDL3
      tex_coord: SDL_FPoint

    SDL_Texture {.importc: "SDL_Texture", header: "<SDL3/SDL.h>".} = object

    TTF_Font {.importc: "TTF_Font", header: "<SDL3_ttf/SDL_ttf.h>".} = object
    TTF_TextEngine {.importc: "TTF_TextEngine", header: "<SDL3_ttf/SDL_ttf.h>".} = object
    TTF_Text {.importc: "TTF_Text", header: "<SDL3_ttf/SDL_ttf.h>".} = object

  const
    BlendModeNone = 0'i32    # SDL_BLENDMODE_NONE
    BlendModeBlend = 1'i32   # SDL_BLENDMODE_BLEND
    PixelFormatARGB8888 = 0x16362004'u32
    TextureAccessTarget = 2'i32
    ScaleModeNearest = 0'i32

  proc SDL_SetRenderDrawColor(ren: ptr SDL_Renderer; r, g, b, a: uint8): bool {.
    importc: "SDL_SetRenderDrawColor", header: "<SDL3/SDL.h>".}
  proc SDL_SetRenderDrawBlendMode(ren: ptr SDL_Renderer; mode: int32): bool {.
    importc: "SDL_SetRenderDrawBlendMode", header: "<SDL3/SDL.h>".}
  proc SDL_RenderFillRect(ren: ptr SDL_Renderer; rect: ptr SDL_FRect): bool {.
    importc: "SDL_RenderFillRect", header: "<SDL3/SDL.h>".}
  proc SDL_RenderGeometry(ren: ptr SDL_Renderer; texture: nil pointer;
                          verts: ptr SDL_Vertex; numVerts: int32;
                          indices: ptr int32; numIndices: int32): bool {.
    importc: "SDL_RenderGeometry", header: "<SDL3/SDL.h>".}
  proc SDL_SetRenderClipRect(ren: ptr SDL_Renderer; rect: ptr SDL_Rect): bool {.
    importc: "SDL_SetRenderClipRect", header: "<SDL3/SDL.h>".}
  proc SDL_RenderClear(ren: ptr SDL_Renderer): bool {.
    importc: "SDL_RenderClear", header: "<SDL3/SDL.h>".}
  proc SDL_RenderReadPixels(ren: ptr SDL_Renderer; rect: ptr SDL_Rect):
      ptr SDL_Surface {.
    importc: "SDL_RenderReadPixels", header: "<SDL3/SDL.h>".}
  proc SDL_SaveBMP(surf: ptr SDL_Surface; file: cstring): bool {.
    importc: "SDL_SaveBMP", header: "<SDL3/SDL.h>".}
  proc SDL_DestroySurface(surf: ptr SDL_Surface) {.
    importc: "SDL_DestroySurface", header: "<SDL3/SDL.h>".}

  proc SDL_CreateTexture(ren: ptr SDL_Renderer; format: uint32; access: int32;
                         w, h: int32): ptr SDL_Texture {.
    importc: "SDL_CreateTexture", header: "<SDL3/SDL.h>".}
  proc SDL_DestroyTexture(tex: ptr SDL_Texture) {.
    importc: "SDL_DestroyTexture", header: "<SDL3/SDL.h>".}
  proc SDL_SetRenderTarget(ren: ptr SDL_Renderer; tex: ptr SDL_Texture): bool {.
    importc: "SDL_SetRenderTarget", header: "<SDL3/SDL.h>".}
  proc SDL_RenderTexture(ren: ptr SDL_Renderer; tex: ptr SDL_Texture;
                         src, dst: ptr SDL_FRect): bool {.
    importc: "SDL_RenderTexture", header: "<SDL3/SDL.h>".}
  proc SDL_SetTextureBlendMode(tex: ptr SDL_Texture; mode: int32): bool {.
    importc: "SDL_SetTextureBlendMode", header: "<SDL3/SDL.h>".}
  proc SDL_SetTextureScaleMode(tex: ptr SDL_Texture; mode: int32): bool {.
    importc: "SDL_SetTextureScaleMode", header: "<SDL3/SDL.h>".}
  proc SDL_GetRenderOutputSize(ren: ptr SDL_Renderer; w, h: ptr int32): bool {.
    importc: "SDL_GetRenderOutputSize", header: "<SDL3/SDL.h>".}
  proc SDL_FlushRenderer(ren: ptr SDL_Renderer): bool {.
    importc: "SDL_FlushRenderer", header: "<SDL3/SDL.h>".}

  proc TTF_Init(): bool {.importc: "TTF_Init", header: "<SDL3_ttf/SDL_ttf.h>".}
  proc TTF_OpenFont(file: cstring; ptsize: float32): ptr TTF_Font {.
    importc: "TTF_OpenFont", header: "<SDL3_ttf/SDL_ttf.h>".}
  proc TTF_CreateRendererTextEngine(ren: ptr SDL_Renderer): ptr TTF_TextEngine {.
    importc: "TTF_CreateRendererTextEngine", header: "<SDL3_ttf/SDL_ttf.h>".}
  proc TTF_DestroyRendererTextEngine(engine: ptr TTF_TextEngine) {.
    importc: "TTF_DestroyRendererTextEngine", header: "<SDL3_ttf/SDL_ttf.h>".}
  proc TTF_CreateText(engine: ptr TTF_TextEngine; font: ptr TTF_Font;
                      text: nil cstring; length: int): ptr TTF_Text {.
    importc: "TTF_CreateText", header: "<SDL3_ttf/SDL_ttf.h>".}
  proc TTF_SetTextColorFloat(text: ptr TTF_Text; r, g, b, a: float32): bool {.
    importc: "TTF_SetTextColorFloat", header: "<SDL3_ttf/SDL_ttf.h>".}
  proc TTF_DrawRendererText(text: ptr TTF_Text; x, y: float32): bool {.
    importc: "TTF_DrawRendererText", header: "<SDL3_ttf/SDL_ttf.h>".}
  proc TTF_DestroyText(text: ptr TTF_Text) {.
    importc: "TTF_DestroyText", header: "<SDL3_ttf/SDL_ttf.h>".}
  proc TTF_GetStringSize(font: ptr TTF_Font; text: cstring; length: int;
                         w, h: ptr int32): bool {.
    importc: "TTF_GetStringSize", header: "<SDL3_ttf/SDL_ttf.h>".}

## --- state -----------------------------------------------------------------------

var
  fontPath*: string = "assets/fonts/inter/Inter-Regular.ttf"
    ## UI font, resolved relative to the working directory (the repo root
    ## when run via `make run`). Set before `initializeRenderer` to override;
    ## `vendoredFontPath` and then `fontFallbackPaths` are tried if this one
    ## cannot be opened.

  fontFallbackPaths = @[
    "/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf",
    "/usr/share/fonts/adwaita-sans-fonts/AdwaitaSans-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]
    ## System fallbacks (Arch, Fedora, Debian layouts) so text still renders
    ## if the vendored font is missing.

  monoFontPaths*: seq[string] = @[
    "/usr/share/fonts/adwaita-mono-fonts/AdwaitaMono-Regular.ttf",
    "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf",
    "/usr/share/fonts/liberation-mono-fonts/LiberationMono-Regular.ttf",
    "/usr/share/fonts/liberation-mono/LiberationMono-Regular.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/System/Library/Fonts/Menlo.ttc",
    "C:/Windows/Fonts/consola.ttf"]
    ## Candidates for `MonoFont` text (code), the first that opens wins;
    ## the UI font stands in when none does. A terminal is monospaced
    ## anyway.

const
  vendoredFontPath = currentSourcePath().parentDir.parentDir.parentDir.parentDir /
    "assets/fonts/inter/Inter-Regular.ttf"
    ## The Inter this checkout ships, found from the source tree at compile
    ## time: a project built against ellipse (whose working directory has no
    ## `assets/`) still gets the UI font, whichever mount the tree was
    ## compiled from.

  MonoFont* = 1'u16
    ## `TextConfig.fontId` of the monospaced font.

when withSdl:
  type
    TextKey = tuple
      ## Cache key for an immutable rendered string: `col` packs rgba as one
      ## uint64 so the tuple stays within the 3-component hashable limit.
      text: string
      size: int
      col: uint64

  type
    CachedText = object
      text: ptr TTF_Text
      used: int64         ## paint serial that last drew it

  var
    fonts: Table[int, ptr TTF_Font]
    texts: Table[TextKey, CachedText]
    textEngine: ptr TTF_TextEngine
    clipStack: seq[SDL_Rect] = @[]
    cullBox: Rect             ## where painting can land now: the SDL clip
    culling = false           ## ... when one is set
    paintSerial = 0'i64
    lastEvict = 0'i64

  const
    TextKeepPaints = 120
      ## A cached string not drawn for this many repaints is released: a clock
      ## or a window title makes a new string every tick, and a bar runs for
      ## days.

  proc openUiFont(size: int): ptr TTF_Font =
    for p in @[fontPath, vendoredFontPath] & fontFallbackPaths:
      var path = p
      result = TTF_OpenFont(path.cstring, float32(size))
      if result != nil:
        return

  proc fontFor(size: int; id = 0'u16): ptr TTF_Font =
    ## One opened TTF font per pixel size and font (TTF point size == pixel
    ## size at the renderer's default 72 dpi): the UI font, or `MonoFont`.
    ## Returns nil when no font could be opened (the measure/draw paths
    ## then fall back / skip).
    let key = size * 8 + int(id)
    let cached = fonts.getOrDefault(key)
    if cached != nil:
      return cached
    var font: ptr TTF_Font = nil
    if id == MonoFont:
      for p in monoFontPaths:
        if font == nil:
          var path = p
          font = TTF_OpenFont(path.cstring, float32(size))
    if font == nil:
      font = openUiFont(size)
    if font == nil:
      return font
    fonts[key] = font
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

  proc storeOpaque(ren: ptr SDL_Renderer; col: Color): bool =
    ## An opaque fill needs no blend: switch to a straight store, which the
    ## software renderer fills many times faster than its per-pixel blend.
    ## True when it did -- `blendAgain` puts the blend back.
    if col.a >= 255.0:
      discard SDL_SetRenderDrawBlendMode(ren, BlendModeNone)
      return true

  proc blendAgain(ren: ptr SDL_Renderer) =
    discard SDL_SetRenderDrawBlendMode(ren, BlendModeBlend)

  proc fillRect(ren: ptr SDL_Renderer; r: Rect; col: Color) =
    var fr = SDL_FRect(x: r.x, y: r.y, w: r.width, h: r.height)
    setColor(ren, col)
    let stored = storeOpaque(ren, col)
    discard SDL_RenderFillRect(ren, addr fr)
    if stored:
      blendAgain(ren)

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

  proc addSector(verts: var seq[SDL_Vertex]; cx, cy, rad, startAngle: float32;
                 seg: int; vc: SDL_FColor) =
    ## A quarter disc around `(cx, cy)` as a fan from its centre: one rounded
    ## corner's inside, its triangles no larger than the corner.
    if rad <= 0.0:
      return
    var pts: seq[SDL_FPoint] = @[]
    addArc(pts, cx, cy, rad, startAngle, QuarterTurn / float32(seg), seg)
    let centre = SDL_FPoint(x: cx, y: cy)
    var i = 0
    while i + 1 < pts.len:
      verts.add(SDL_Vertex(position: centre, color: vc, tex_coord: SDL_FPoint()))
      verts.add(SDL_Vertex(position: pts[i], color: vc, tex_coord: SDL_FPoint()))
      verts.add(SDL_Vertex(position: pts[i + 1], color: vc, tex_coord: SDL_FPoint()))
      inc i

  proc submitGeometry(ren: ptr SDL_Renderer; verts: var seq[SDL_Vertex]) =
    ## Hand a shape's triangles to SDL, less those wholly outside the clip:
    ## a damaged sliver of a large rounded box needs only the few that
    ## reach it, and SDL's software path costs per triangle even when it
    ## clips one away. Triangles that can touch the clip go unchanged, so
    ## the pixels are the same either way.
    if culling:
      let
        cx0 = cullBox.x - 1.0
        cy0 = cullBox.y - 1.0
        cx1 = cullBox.x + cullBox.width + 1.0
        cy1 = cullBox.y + cullBox.height + 1.0
      var kept = 0
      var t = 0
      while t + 2 < verts.len:
        let a = verts[t].position
        let b = verts[t + 1].position
        let c = verts[t + 2].position
        if max(a.x, max(b.x, c.x)) >= cx0 and min(a.x, min(b.x, c.x)) <= cx1 and
            max(a.y, max(b.y, c.y)) >= cy0 and min(a.y, min(b.y, c.y)) <= cy1:
          if kept != t:
            verts[kept] = verts[t]
            verts[kept + 1] = verts[t + 1]
            verts[kept + 2] = verts[t + 2]
          kept += 3
        t += 3
      verts.setLen(kept)
    if verts.len > 0:
      discard SDL_RenderGeometry(ren, nil, addr verts[0], int32(verts.len), nil, 0)

  proc outsideCull(r: Rect): bool =
    ## `r`, with its smoothing bands, lands nowhere the clip lets through.
    culling and not overlaps(rect(r.x - 2.0, r.y - 2.0, r.width + 4.0,
                                  r.height + 4.0), cullBox)

  proc fillSpan(ren: ptr SDL_Renderer; x0, y0, x1, y1: float32) =
    ## A plain rectangle in the draw colour already set; empty spans skip.
    if x1 > x0 and y1 > y0:
      var fr = SDL_FRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
      discard SDL_RenderFillRect(ren, addr fr)

  proc fillRounded(ren: ptr SDL_Renderer; r: Rect; corner: CornerRadius; col: Color) =
    ## Rounded rectangle on whole pixels: every straight-sided part -- the
    ## middle band and the runs between corners -- is a plain rectangle fill,
    ## only the four corner sectors are triangles, plus two outward smoothing
    ## bands. The software rasterizer walks each triangle's bounding box, so
    ## a fan from the middle would cost it the box's area once per chord.
    let x0 = round(r.x)
    let y0 = round(r.y)
    let x1 = round(r.x + r.width)
    let y1 = round(r.y + r.height)
    if x1 <= x0 or y1 <= y0 or outsideCull(r):
      return
    let box = Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    var c = clampCorners(box, corner)
    c = CornerRadius(topLeft: floor(c.topLeft), topRight: floor(c.topRight),
                     bottomLeft: floor(c.bottomLeft),
                     bottomRight: floor(c.bottomRight))
    let seg = arcSegments(cornerSize(c))
    let top = max(c.topLeft, c.topRight)
    let bottom = max(c.bottomLeft, c.bottomRight)
    setColor(ren, col)
    let stored = storeOpaque(ren, col)
    fillSpan(ren, x0, y0 + top, x1, y1 - bottom)
    fillSpan(ren, x0 + c.topLeft, y0, x1 - c.topRight, y0 + top)
    fillSpan(ren, x0, y0 + c.topLeft, x0 + c.topLeft, y0 + top)
    fillSpan(ren, x1 - c.topRight, y0 + c.topRight, x1, y0 + top)
    fillSpan(ren, x0 + c.bottomLeft, y1 - bottom, x1 - c.bottomRight, y1)
    fillSpan(ren, x0, y1 - bottom, x0 + c.bottomLeft, y1 - c.bottomLeft)
    fillSpan(ren, x1 - c.bottomRight, y1 - bottom, x1, y1 - c.bottomRight)
    if stored:
      blendAgain(ren)
    let vc = SDL_FColor(r: col.r / 255.0, g: col.g / 255.0, b: col.b / 255.0,
                        a: col.a / 255.0)
    var verts: seq[SDL_Vertex] = @[]
    addSector(verts, x0 + c.topLeft, y0 + c.topLeft, c.topLeft,
              2.0'f32 * QuarterTurn, seg, vc)
    addSector(verts, x1 - c.topRight, y0 + c.topRight, c.topRight,
              3.0'f32 * QuarterTurn, seg, vc)
    addSector(verts, x1 - c.bottomRight, y1 - c.bottomRight, c.bottomRight,
              4.0'f32 * QuarterTurn, seg, vc)
    addSector(verts, x0 + c.bottomLeft, y1 - c.bottomLeft, c.bottomLeft,
              5.0'f32 * QuarterTurn, seg, vc)
    addFeathering(verts, box, c, seg, col, inside = false)
    submitGeometry(ren, verts)

  proc strokeRounded(ren: ptr SDL_Renderer; r: Rect; bw: BorderWidth;
                     corner: CornerRadius; col: Color) =
    ## A border with rounded corners: the ring between the outer rounded rect and
    ## its inner offset -- the per-side border widths inset the inner edge, and
    ## each inner corner keeps `outerRadius - adjacentBorderWidth` so the band
    ## stays visually uniform through the curve. Smoothing bands hug both edges.
    if outsideCull(r):
      return
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
    submitGeometry(ren, verts)

  proc fillStrip(ren: ptr SDL_Renderer; x, y, w, h: float32; col: Color) =
    if w <= 0.0 or h <= 0.0:
      return
    fillRect(ren, rect(x, y, w, h), col)

  func packColor(col: Color): uint64 =
    (uint64(col.r.toU8) or uint64(col.g.toU8) shl 8 or
     uint64(col.b.toU8) shl 16 or uint64(col.a.toU8) shl 24)

  proc textFor(key: TextKey, col: Color): ptr TTF_Text =
    ## `key.size` packs the font: size * 8 + fontId.
    let cached = texts.getOrDefault(key)
    if cached.text != nil:
      texts[key] = CachedText(text: cached.text, used: paintSerial)
      return cached.text
    let font = fontFor(key.size div 8, uint16(key.size mod 8))
    if font == nil:
      return nil
    var t = key.text
    let text = TTF_CreateText(textEngine, font, t.cstring, t.len)
    if text == nil:
      return nil
    discard TTF_SetTextColorFloat(text, col.r / 255.0, col.g / 255.0,
                                  col.b / 255.0, col.a / 255.0)
    texts[key] = CachedText(text: text, used: paintSerial)
    return text

  proc evictTexts() =
    ## Release cached strings that have not been drawn for a while.
    if paintSerial - lastEvict < TextKeepPaints:
      return
    lastEvict = paintSerial
    var dead: seq[TextKey] = @[]
    for k, v in texts:
      if paintSerial - v.used > TextKeepPaints:
        dead.add k
    for k in dead:
      let t = texts.getOrDefault(k).text
      if t != nil:
        TTF_DestroyText(t)
      texts.del k

  proc drawTextCmd(text: string; x, y: float32; col: Color; size: int;
                   font = 0'u16) =
    ## Draw at (x, y) = top-left of the text box, rounding to the pixel grid:
    ## fractional origins make the engine resample glyph edges and smear.
    let item = textFor((text: text, size: size * 8 + int(font and 7'u16),
                        col: packColor(col)), col)
    if item == nil:
      return
    discard TTF_DrawRendererText(item, float32(roundPx(x)), float32(roundPx(y)))

## --- public API ----------------------------------------------------------------------

proc initializeRenderer*()  =
  ## Prepare fonts + text engine on the platform's renderer. Call after
  ## `platform.initialize()` and before the first frame. Nothing to do in
  ## a build without SDL. Re-running rebinds to the live renderer: the
  ## engine's cached texts belong to the old one and go with it (see
  ## `resizeOffscreen`).
  when withSdl:
    if not TTF_Init():
      raise Failure()
    if not textEngine.isNil:
      TTF_DestroyRendererTextEngine(textEngine)
      for _, cached in texts:
        if cached.text != nil:
          TTF_DestroyText(cached.text)
      texts.clear()
    textEngine = TTF_CreateRendererTextEngine(sdlRenderer())
    if textEngine == nil:
      raise Failure()
    # alpha-enabled fills for translucent backgrounds and glyph edges
    discard SDL_SetRenderDrawBlendMode(sdlRenderer(), BlendModeBlend)

proc measureText*(text: string; cfg: TextConfig): Size =
  if terminalMode():
    # One cell per column the text takes, one row high, whatever its size.
    return Size(width: float32(displayWidth(text)) * cellWidth,
                height: cellHeight)
  ## clay `MeasureFn`: real metrics from the font at `cfg.fontSize`.
  ## Fallback: the uniform-cell estimate, on measurement failure.
  when withSdl:
    let font = fontFor(cfg.fontSize.int, cfg.fontId)
    if font != nil:
      var w = 0'i32
      var h = 0'i32
      var t = text
      if TTF_GetStringSize(font, t.cstring, t.len, addr w, addr h):
        return Size(width: float32(w), height: float32(h))
  return Size(width: float32(text.len) * float32(cfg.fontSize),
              height: float32(cfg.fontSize))

proc bootContext(width, height: float32)  =
  if not terminalMode():
    initializeRenderer()
  var w = width
  var h = height
  if w <= 0.0 or h <= 0.0:
    let (winW, winH) = windowPixelSize()
    w = winW
    h = winH
  setCurrentContext(initContext(size(w, h)))
  setMeasureText(measureText)
  if terminalMode():
    setGrid(size(cellWidth, cellHeight))

proc bootup*(width, height: float32 = 0.0)  =
  ## The whole GUI startup dance in one call: platform window + renderer,
  ## a clay context at `width`x`height` (0 takes the live window size) and
  ## this renderer's `measureText` wired into clay's layout. The one
  ## sequence every ellipse app's `main` repeats.
  initialize()
  bootContext(width, height)

proc bootup*(cfg: WindowConfig)  =
  ## `bootup` with a window description -- a title, a size, or a docked
  ## layer-shell bar (`cfg.layer`).
  initialize(cfg)
  bootContext(0.0, 0.0)

when withSdl:
  func toSdlRect(r: Rect): SDL_Rect =
    SDL_Rect(x: r.x.int32, y: r.y.int32, w: r.width.int32, h: r.height.int32)

  func toRect(r: SDL_Rect): Rect =
    rect(float32(r.x), float32(r.y), float32(r.w), float32(r.h))

  proc applyClip(ren: ptr SDL_Renderer; area: Rect; limited: bool) =
    ## Set the SDL clip to the innermost clip command, narrowed to `area`
    ## when repainting a damaged region.
    if clipStack.len > 0:
      var cr = clipStack[^1]
      if limited:
        cr = toSdlRect(intersect(toRect(cr), area))
        if cr.w <= 0 or cr.h <= 0:
          cr = SDL_Rect(x: 0, y: 0, w: 0, h: 0)
      discard SDL_SetRenderClipRect(ren, addr cr)
      cullBox = toRect(cr)
      culling = true
    elif limited:
      var cr = toSdlRect(area)
      discard SDL_SetRenderClipRect(ren, addr cr)
      cullBox = toRect(cr)
      culling = true
    else:
      discard SDL_SetRenderClipRect(ren, nil)
      culling = false

  proc paintCommands(cmds: seq[RenderCommand]; area: Rect; limited: bool) =
    ## Paint `cmds` in order. `limited`: only into `area` -- commands entirely
    ## outside it are skipped, the rest are clipped to it.
    let ren = sdlRenderer()
    inc paintSerial
    clipStack.setLen(0)
    applyClip(ren, area, limited)
    for cmd in cmds:
      if limited and cmd.kind != renderClipStart and cmd.kind != renderClipEnd and
          not overlaps(rect(cmd.box.x - 2.0, cmd.box.y - 2.0,
                            cmd.box.width + 4.0, cmd.box.height + 4.0), area):
        continue
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
                    cmd.fontSize.int, cmd.fontId)
      of renderClipStart:
        # Clips nest: a clip inside a clip draws only where both allow -- a
        # list scrolled half out of its page must not paint over the toolbar.
        var r = cmd.box
        if clipStack.len > 0:
          r = intersect(r, toRect(clipStack[^1]))
        var cr = toSdlRect(r)
        if cr.w <= 0 or cr.h <= 0:
          cr = SDL_Rect(x: 0, y: 0, w: 0, h: 0)
        clipStack.add cr
        applyClip(ren, area, limited)
      of renderClipEnd:
        if clipStack.len > 0:
          clipStack.setLen(clipStack.len - 1)
          applyClip(ren, area, limited)
      of renderImage, renderCustom, renderOverlayStart, renderOverlayEnd:
        discard   # not produced by the built-in UI (yet)
    discard SDL_SetRenderClipRect(ren, nil)
    culling = false
    evictTexts()

## --- retained frame ------------------------------------------------------------
##
## The picture lives in a target texture between frames. `drawCommands`
## diffs this frame's commands against the last painted ones (see
## `ellipse/platform/damage`), repaints only the damaged rectangles into the
## texture, copies it to the backbuffer and asks the platform to present. An
## unchanged frame paints and presents nothing. During a live resize the
## texture would be reallocated every frame, so the renderer paints straight
## to the backbuffer until the gesture settles, then rebuilds it.

var
  clearColor* = rgb(0, 0, 0)
    ## What the window shows where no command paints.
  lastSigs: seq[CmdSig] = @[]
  lastValid = false          ## `retained` holds `lastSigs`' picture
  termValid = false          ## the terminal shows `termFront`

when withSdl:
  var
    retained: ptr SDL_Texture
    retainedW = 0'i32
    retainedH = 0'i32
    retainedOk = true          ## false once target textures proved unsupported

  proc dropRetained() =
    let tex = retained
    if tex != nil:
      SDL_DestroyTexture(tex)
      retained = nil
    lastValid = false

  proc ensureRetained(w, h: int32): bool =
    if not retainedOk:
      return false
    if retained != nil and retainedW == w and retainedH == h:
      return true
    dropRetained()
    let tex = SDL_CreateTexture(sdlRenderer(), PixelFormatARGB8888,
                                TextureAccessTarget, w, h)
    if tex == nil:
      retainedOk = false
      return false
    discard SDL_SetTextureBlendMode(tex, BlendModeNone)
    discard SDL_SetTextureScaleMode(tex, ScaleModeNearest)
    retained = tex
    retainedW = w
    retainedH = h
    return true

proc invalidateFrame*() =
  ## Forget the retained picture: the next `drawCommands` repaints it all.
  lastValid = false
  termValid = false

proc bootupOffscreen*(width, height: int32)  =
  ## The windowless bootup, for a host that owns its own window and present
  ## path (see `platform.initializeOffscreen`): the UI paints commands into
  ## an offscreen surface, `drawCommands` works unchanged, and the host
  ## copies the picture out with `readPicture` each frame something
  ## painted. The clear colour starts fully transparent: whatever the
  ## widgets leave unpainted stays the host's scene underneath.
  when withSdl:
    initializeOffscreen(width, height)
    clearColor = rgb(0, 0, 0, 0)
    bootContext(width.float32, height.float32)

proc resizeOffscreen*(width, height: int32) =
  ## After the host's window changes shape: new surface, new text engine
  ## bound to it, and a full repaint demanded so the next `readPicture`
  ## sees nothing stale.
  when withSdl:
    platform.resizeOffscreen(width, height)
    initializeRenderer()
    dropRetained()
    invalidateFrame()
    requestFullRedraw()

proc readPicture*(bytes: var seq[uint8]): tuple[width, height: int32] =
  ## Copy the offscreen picture into `bytes`: ARGB8888 (memory B, G, R, A;
  ## alpha as blended -- effectively premultiplied over a transparent
  ## clear), row 0 the window's top. Returns the size, 0x0 when the read
  ## failed. Call after `drawCommands` when `contentPainted` says true;
  ## upload it with `gpu.uploadPicture` and blend with premultiplied
  ## factors (`gpu.PipelineDesc.premultiplied`).
  result = (0'i32, 0'i32)
  when withSdl:
    let ren = sdlRenderer()
    if ren == nil:
      return
    let surf = SDL_RenderReadPixels(ren, nil)
    if surf == nil:
      return
    let
      w = surf[].w
      h = surf[].h
    if w <= 0 or h <= 0:
      SDL_DestroySurface(surf)
      return
    result = (w, h)
    bytes.setLen(w * h * 4)
    let
      src = cast[uint](surf[].pixels)
      dst = cast[uint](addr bytes[0])
    var y = 0'i32
    while y < h:
      copyMem(cast[pointer](dst + uint(y) * uint(w * 4)),
              cast[pointer](src + uint(y) * uint(surf[].pitch)), w * 4)
      inc y
    SDL_DestroySurface(surf)

proc frameSignatures(cmds: seq[RenderCommand]): seq[CmdSig] =
  var b = SigBuilder()
  for cmd in cmds:
    b.add(cmd, if cmd.kind == renderText: lineText(cmd) else: "")
  result = b.sigs

type
  PixelArea* = object
    ## A whole-pixel rectangle of the picture: `x0 ..< x1` by `y0 ..< y1`.
    x0*, y0*, x1*, y1*: int32

proc isEmpty*(a: PixelArea): bool = a.x1 <= a.x0 or a.y1 <= a.y0

proc merge*(a, b: PixelArea): PixelArea =
  ## The smallest area holding both; an empty side adds nothing.
  if a.isEmpty: return b
  if b.isEmpty: return a
  PixelArea(x0: min(a.x0, b.x0), y0: min(a.y0, b.y0),
            x1: max(a.x1, b.x1), y1: max(a.y1, b.y1))

var paintedArea: PixelArea
  ## What the last `drawCommands` repainted, for `readPainted`.

proc notePainted(r: Rect; w, h: int32) =
  ## Widen `painted` by `r`, out to whole pixels and in to the picture.
  paintedArea = paintedArea.merge(PixelArea(
    x0: clamp(int32(floor(r.x)), 0'i32, w),
    y0: clamp(int32(floor(r.y)), 0'i32, h),
    x1: clamp(int32(ceil(r.x + r.width)), 0'i32, w),
    y1: clamp(int32(ceil(r.y + r.height)), 0'i32, h)))

when withSdl:
  proc paintDirect(cmds: seq[RenderCommand]; w, h: int32) =
    let ren = sdlRenderer()
    setColor(ren, clearColor)
    discard SDL_RenderClear(ren)
    paintCommands(cmds, rect(0, 0, float32(w), float32(h)), false)
    noteDamage(int64(w) * int64(h))
    notePainted(rect(0, 0, float32(w), float32(h)), w, h)

proc readPainted*(bytes: var seq[uint8]):
    tuple[width, height: int32; area: PixelArea] =
  ## `readPicture` for a host that keeps its copy: only the pixels the last
  ## `drawCommands` repainted are copied into `bytes` -- which holds the
  ## whole picture, row 0 the window's top -- and `area` says which. A
  ## copy of another size is taken whole. Offscreen the pixels come
  ## straight from the surface the renderer paints into; otherwise this
  ## reads back the whole picture.
  result = (0'i32, 0'i32, PixelArea())
  when withSdl:
    let surf = cast[ptr SDL_Surface](offscreenSurface())
    if surf == nil:
      let (w, h) = readPicture(bytes)
      return (w, h, PixelArea(x1: w, y1: h))
    discard SDL_FlushRenderer(sdlRenderer())
    let
      w = surf[].w
      h = surf[].h
    if w <= 0 or h <= 0:
      return
    var area = paintedArea
    if bytes.len != w * h * 4:
      bytes.setLen(w * h * 4)
      area = PixelArea(x1: w, y1: h)
    result = (w, h, area)
    if area.isEmpty:
      return
    let
      src = cast[uint](surf[].pixels)
      dst = cast[uint](addr bytes[0])
      span = int(area.x1 - area.x0) * 4
    var y = area.y0
    while y < area.y1:
      copyMem(cast[pointer](dst + uint(y) * uint(w * 4) + uint(area.x0 * 4)),
              cast[pointer](src + uint(y) * uint(surf[].pitch) +
                            uint(area.x0 * 4)), span)
      inc y

type
  OverlayFn* = proc () {.closure.}

var
  overlayHook: OverlayFn
  contentPaintedFlag = false

proc setOverlay*(f: OverlayFn) =
  ## Paint `f` over every presented picture (debug overlays). It draws with
  ## the `overlay*` primitives straight onto the backbuffer, after the app's
  ## commands and outside the retained picture and its damage tracking --
  ## so it never makes the app repaint or run. While one is set every render
  ## presents.
  overlayHook = f
  invalidateFrame()

proc contentPainted*(): bool =
  ## The last `drawCommands` repainted app pixels (its commands changed).
  contentPaintedFlag

when withSdl:
  proc shiftRows(scroll: Scroll) =
    ## Move the offscreen surface's rows inside `scroll.area` by
    ## `scroll.dy`: what scrolled keeps its pixels, and the rows it leaves
    ## behind are damage the diff already named.
    let surf = cast[ptr SDL_Surface](offscreenSurface())
    if surf == nil:
      return
    discard SDL_FlushRenderer(sdlRenderer()) # paint queued before the move
    let
      x0 = clamp(int32(scroll.area.x), 0'i32, surf[].w)
      x1 = clamp(int32(scroll.area.x + scroll.area.width), 0'i32, surf[].w)
      y0 = clamp(int32(scroll.area.y), 0'i32, surf[].h)
      y1 = clamp(int32(scroll.area.y + scroll.area.height), 0'i32, surf[].h)
      dy = int32(scroll.dy)
    if x1 <= x0 or y1 - y0 <= abs(dy):
      return
    let
      base = cast[uint](surf[].pixels)
      pitch = uint(surf[].pitch)
      span = int(x1 - x0) * 4
    proc row(y: int32): pointer =
      cast[pointer](base + uint(y) * pitch + uint(x0) * 4)
    if dy < 0:
      # Up: walk down, each row taking the one `-dy` below it.
      var y = y0
      while y < y1 + dy:
        moveMem(row(y), row(y - dy), span)
        inc y
    else:
      var y = y1 - 1
      while y >= y0 + dy:
        moveMem(row(y), row(y - dy), span)
        dec y

  proc paintContent(): tuple[painted, ready: bool]  =
    ## Bring the picture up to date. `painted`: app pixels changed; `ready`:
    ## the backbuffer already holds the picture.
    let ren = sdlRenderer()
    let cmds = renderCommands()
    let sigs = frameSignatures(cmds)
    paintedArea = PixelArea()
    var w = 0'i32
    var h = 0'i32
    discard SDL_GetRenderOutputSize(ren, addr w, addr h)
    if w <= 0 or h <= 0:
      return (false, false)
    let full = takeFullRedraw()

    if resizing():
      # Live resize: straight to the backbuffer, every frame.
      dropRetained()
      paintDirect(cmds, w, h)
      lastSigs = sigs
      return (true, true)

    if offscreenSurface() == nil and not ensureRetained(w, h):
      # No target textures: the plain paint-everything path, still skipping
      # frames whose commands did not change.
      let unchanged = lastValid and not full and
        diffDamage(lastSigs, sigs, rect(0, 0, float32(w), float32(h))).kind == dmgNone
      lastSigs = sigs
      lastValid = true
      if unchanged:
        return (false, false)
      paintDirect(cmds, w, h)
      return (true, true)

    # Offscreen the surface itself keeps the picture between frames: the
    # damage is painted straight into it, with no texture to copy across,
    # and a scrolled region is shifted in place rather than painted anew.
    let direct = offscreenSurface() != nil
    let viewport = rect(0, 0, float32(w), float32(h))
    var dmg = Damage(kind: dmgFull)
    if lastValid and not full:
      dmg = diffDamage(lastSigs, sigs, viewport, shift = direct)
    lastSigs = sigs
    lastValid = true
    if dmg.kind == dmgNone:
      return (false, false)

    if not direct:
      discard SDL_SetRenderTarget(ren, retained)
    elif dmg.kind == dmgRects and dmg.scroll.dy != 0.0:
      shiftRows(dmg.scroll)
      notePainted(dmg.scroll.area, w, h)
    if dmg.kind == dmgFull:
      setColor(ren, clearColor)
      discard SDL_RenderClear(ren)
      paintCommands(cmds, viewport, false)
      noteDamage(int64(w) * int64(h))
      notePainted(viewport, w, h)
    else:
      for r in dmg.rects:
        var cr = toSdlRect(r)
        discard SDL_SetRenderClipRect(ren, addr cr)
        discard SDL_SetRenderDrawBlendMode(ren, BlendModeNone)
        fillRect(ren, r, clearColor)
        discard SDL_SetRenderDrawBlendMode(ren, BlendModeBlend)
        paintCommands(cmds, r, true)
        noteDamage(int64(r.width) * int64(r.height))
        notePainted(r, w, h)
    discard SDL_SetRenderClipRect(ren, nil)
    if direct:
      return (true, true)
    discard SDL_SetRenderTarget(ren, nil)
    let tex = retained
    if tex != nil:
      discard SDL_RenderTexture(ren, tex, nil, nil)
    return (true, true)

## --- the terminal picture ---------------------------------------------------------
##
## In `terminalMode()` the commands paint a cell buffer (`ellipse/terminal/
## cells`) instead of pixels. The buffer the terminal shows is kept, and a
## frame writes only the cells that differ from it -- the terminal's damage
## tracking -- inside a synchronized-output bracket so a half-written frame
## is never seen. Colours go out as 24-bit, or the nearest of 256 / 16 when
## the terminal says it has no more (`COLORTERM`, `TERM`;
## `ELLIPSE_TUI_COLORS=true|256|16` overrides).

var
  termFront: CellBuffer      ## what the terminal shows
  termColors = cmTrue
  termColorsKnown = false
  textColorDefault = rgb(230, 232, 238)

proc terminalColorMode*(): ColorMode =
  if not termColorsKnown:
    termColorsKnown = true
    let force = getEnv("ELLIPSE_TUI_COLORS")
    let colorterm = getEnv("COLORTERM")
    let term = getEnv("TERM")
    termColors =
      if force == "16": cm16
      elif force == "256": cm256
      elif force.len > 0: cmTrue
      elif colorterm == "truecolor" or colorterm == "24bit": cmTrue
      elif term.contains("256color") or term.contains("kitty") or
          term.contains("ghostty") or term.contains("wezterm"): cm256
      elif term == "linux" or term.len == 0: cm16
      else: cm256
  termColors

proc terminalPicture*(): CellBuffer =
  ## The last layout pass painted into a fresh cell buffer the size of the
  ## layout.
  let dims = layoutDimensions()
  let cols = max(int(dims.width / cellWidth + 0.5), 1)
  let rows = max(int(dims.height / cellHeight + 0.5), 1)
  result = initCellBuffer(cols, rows, cellWidth, cellHeight,
                          toRgb(clearColor), toRgb(textColorDefault))
  result.paint(renderCommands())

var termCursor = ""   ## the cursor state last sent (see `cursorSeq`)

proc cursorSeq(): string =
  ## Where the terminal's cursor goes after this frame: at the caret a
  ## focused field asked for (a blinking bar), else hidden.
  let (shown, x, y) = takeTerminalCaret()
  if not shown:
    return "\e[?25l"
  let col = int(floor(x / cellWidth + 0.5)) + 1
  let row = int(floor(y / cellHeight + 0.5)) + 1
  "\e[" & $row & ";" & $col & "H\e[5 q\e[?25h"

proc drawTerminal() =
  let back = terminalPicture()
  let full = takeFullRedraw() or not termValid
  var frame = toAnsi(back, termFront, terminalColorMode(), full)
  let cursor = cursorSeq()
  if frame.len > 0 or full or cursor != termCursor:
    if full:
      frame = "\e[0m\e[2J" & frame
    # Hide the cursor while cells are written; put it back last.
    terminalWrite("\e[?2026h\e[?25l" & frame & cursor & "\e[?2026l")
    termCursor = cursor
    noteDamage(int64(frame.len))
    contentPaintedFlag = true
    requestSettleFrame()
    requestPresent()
  else:
    contentPaintedFlag = false
  termFront = back
  termValid = true

proc drawCommands*()  =
  ## Paint the current context's commands from the last `endLayout`. Call
  ## once per frame from the app's render hook; it repaints only what
  ## changed since the last call and requests a present only when anything
  ## did (see `pacing.requestPresent`). A frame whose output changed also
  ## asks for one more frame: immediate-mode widgets read last frame's
  ## geometry, so a change settles over two frames.
  if terminalMode():
    drawTerminal()
    return
  when withSdl:
    let (painted, ready) = paintContent()
    contentPaintedFlag = painted
    if painted:
      requestSettleFrame()
      requestPresent()
    let hook = overlayHook
    if hook == nil or offscreenSurface() != nil:
      return   # offscreen there is no backbuffer to lay it over
    if not ready:
      # Unchanged picture: put it back on the backbuffer under the overlay.
      let ren = sdlRenderer()
      discard SDL_SetRenderClipRect(ren, nil)
      let tex = retained
      if tex != nil and lastValid:
        discard SDL_RenderTexture(ren, tex, nil, nil)
      else:
        var w = 0'i32
        var h = 0'i32
        discard SDL_GetRenderOutputSize(ren, addr w, addr h)
        setColor(ren, clearColor)
        discard SDL_RenderClear(ren)
        paintCommands(renderCommands(), rect(0, 0, float32(w), float32(h)), false)
    inc paintSerial
    hook()
    discard SDL_SetRenderClipRect(sdlRenderer(), nil)
    evictTexts()
    requestPresent()

## --- overlay primitives ----------------------------------------------------------

proc overlayRect*(r: Rect; col: Color) =
  ## A filled rectangle (alpha-blended) for an overlay hook.
  if terminalMode(): return
  when withSdl:
    fillRect(sdlRenderer(), r, col)

proc overlayFrame*(r: Rect; width: float32; col: Color) =
  ## A rectangle outline `width` thick, inside `r`.
  if terminalMode(): return
  when withSdl:
    let ren = sdlRenderer()
    fillStrip(ren, r.x, r.y, r.width, width, col)
    fillStrip(ren, r.x, r.y + r.height - width, r.width, width, col)
    fillStrip(ren, r.x, r.y + width, width, r.height - 2.0 * width, col)
    fillStrip(ren, r.x + r.width - width, r.y + width, width,
              r.height - 2.0 * width, col)

proc overlayText*(text: string; x, y: float32; size: int; col: Color) =
  ## One line of text with its top-left at (x, y).
  if terminalMode(): return
  when withSdl:
    if text.len > 0:
      drawTextCmd(text, x, y, col, size)

proc overlayTextWidth*(text: string; size: int): float32 =
  measureText(text, TextConfig(fontSize: uint16(size))).width

proc overlayClip*(r: Rect) =
  ## Clip overlay painting to `r` until `overlayUnclip`.
  if terminalMode(): return
  when withSdl:
    var cr = toSdlRect(r)
    discard SDL_SetRenderClipRect(sdlRenderer(), addr cr)

proc overlayUnclip*() =
  if terminalMode(): return
  when withSdl:
    discard SDL_SetRenderClipRect(sdlRenderer(), nil)

proc frameChecksum*(): uint64  =
  ## FNV-1a over the backbuffer's pixels: what the next present would show.
  ## The seam the damage tests compare a partial repaint against a full one
  ## with; 0 when the readback failed. In the terminal: over the cells.
  if terminalMode():
    result = 0xCBF29CE484222325'u64
    for ch in toAnsiFrame(terminalPicture(), cmTrue):
      result = (result xor uint64(ord(ch))) * 0x100000001B3'u64
    return
  result = 0
  when withSdl:
    let surf = SDL_RenderReadPixels(sdlRenderer(), nil)
    if surf == nil:
      return 0
    result = 0xCBF29CE484222325'u64
    let base = cast[uint](surf[].pixels)
    var y = 0'i32
    while y < surf[].h:
      let row = cast[ptr UncheckedArray[uint8]](base + uint(y) * uint(surf[].pitch))
      var x = 0'i32
      while x < surf[].w * 4:
        result = (result xor uint64(row[x])) * 0x100000001B3'u64
        inc x
      inc y
    SDL_DestroySurface(surf)

proc saveTerminalShot(path: string): bool  =
  ## The terminal picture as text: plain, or with its colours as ANSI
  ## escapes when `path` ends in `.ans` (`cat` it to look).
  let pic = terminalPicture()
  let body = if path.endsWith(".ans"): toAnsiFrame(pic, terminalColorMode())
             else: toPlain(pic)
  try:
    writeFile(path, body)
    result = true
  except:
    result = false

proc saveBackbuffer*(path: string): bool  =
  ## Write what the next present would show -- app picture and any overlay
  ## -- as a BMP. Call from the render hook after `drawCommands`. In the
  ## terminal: as text (see `saveScreenshot`).
  if terminalMode():
    return saveTerminalShot(path)
  result = false
  when withSdl:
    let surf = SDL_RenderReadPixels(sdlRenderer(), nil)
    if surf == nil:
      return false
    var p = path
    result = SDL_SaveBMP(surf, p.cstring)
    SDL_DestroySurface(surf)

proc saveScreenshot*(path: string; width, height: int32 = 0;
                     bg: Color = rgb(12, 12, 16)): bool  =
  ## Headless inspection shot: clear the platform renderer with `bg`, paint
  ## the last layout pass with `drawCommands`, read the framebuffer back and
  ## write `path` as a BMP. `width`/`height` of 0 grab the whole render
  ## target. Returns false when the readback or the write failed -- the
  ## offscreen-driver idiom every shot harness in this repo used to
  ## hand-bind against SDL for. In the terminal the shot is text (see
  ## `saveTerminalShot`); `bg` is ignored -- the app paints its own.
  if terminalMode():
    return saveTerminalShot(path)
  result = false
  when withSdl:
    let ren = sdlRenderer()
    setColor(ren, bg)
    discard SDL_RenderClear(ren)
    var ow = 0'i32
    var oh = 0'i32
    discard SDL_GetRenderOutputSize(ren, addr ow, addr oh)
    paintCommands(renderCommands(), rect(0, 0, float32(ow), float32(oh)), false)
    var full = SDL_Rect(x: 0, y: 0, w: width, h: height)
    let surf = if width > 0 and height > 0: SDL_RenderReadPixels(ren, addr full)
               else: SDL_RenderReadPixels(ren, nil)
    if surf == nil:
      return false
    var p = path
    result = SDL_SaveBMP(surf, p.cstring)
    SDL_DestroySurface(surf)

