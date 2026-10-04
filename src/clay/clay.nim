## Clay -- immediate mode layout for Nimony.
##
## A ground-up Nim port of nicbarker/clay v0.14 (https://github.com/nicbarker/clay),
## the auto-sizing / floating layout engine for UIs. The layout algorithms --
## content folding, per-axis sizing passes with grow/percent/compression,
## word-boundary text wrapping, floating attach-point geometry, clip/scroll
## containers with drag + momentum, hover detection against last-frame boxes,
## and render-command generation -- are ported faithfully (in float32, as the
## C original computes in `float`).
##
## The *interface*, however, is designed for Nim from the start:
##   - No arena, no capacity flags, no error callbacks: `seq`/`Table` handle
##     memory, errors accumulate in `takeErrors`, and the context is a `ref`.
##   - No wrapper structs or designated-initializer macros: declarations are
##     plain objects with defaults, built with `row`/`col`/`grow`/`pct`/...
##     factories and combinators (`withBg`, `withBorder`, `withFloating`).
##   - The C macro layer (CLAY(...){...}, CLAY_ID, ...) is *not* ported as
##     macros. A Nimony template plugin (`clay`) brackets elements and hashes
##     string-literal ids at compile time; see src/clay/deps/mclay.nim.
##   - Clay's v0.14 transition engine (ghost-cloned exiting subtrees) is
##     deliberately absent: in immediate-mode Nim animation state usually
##     lives in the app, so the port ships `lerp`/`easeOut` helpers instead.
##     See docs/clay.org ("Animations").
##
## Frame contract (same shape as Clay's examples):
##   setPointerState / updateScrollContainers   <- reads last frame's boxes
##   beginLayout -> declare -> endLayout        <- produces ctx.commands
##   render the commands
##
## Implementation notes: the parts are `include`d (not imported) into this
## single module on purpose -- Nimony binds an identifier for every imported
## module alias, and names like `types`/`engine`/`measurement` would be
## stolen from the host program. This module is `clay/clay.nim`; `nimony.paths`
## lists `src/clay` so host programs keep importing it as plain `clay`.
## Include order below is dependency order; fragments must not import each
## other or anything outside std.

import std/[tables, algorithm, syncio, assertions]

include [types, hashing, store, measurement, engine, interaction]

## --- the implicit current context -------------------------------------------
##
## Every core routine takes an explicit `Context`; the DSL (and single-window
## apps) use these thin wrappers around an implicit current context.

var currentCtx: nil Context

proc currentContext*(): Context =
  ## The context the DSL operates on. Lazily initialised (640x480) -- call
  ## `initContext` first for real use.
  let existing = currentCtx
  if existing == nil:
    currentCtx = initContext(size(640, 480))
    return currentContext()
  return existing

proc setCurrentContext*(ctx: Context) =
  ## Swap contexts for multi-window use; queries and declarations follow the
  ## current one.
  currentCtx = ctx

proc beginLayout*() = beginLayout(currentContext())
proc endLayout*() = endLayout(currentContext())
proc openElement*() = openElement(currentContext())
proc openElement*(id: ElementId) = openElement(currentContext(), id)
proc openElement*(decl: ElementDeclaration) = openElement(currentContext(), decl)
proc openElement*(id: ElementId, decl: ElementDeclaration) =
  openElement(currentContext(), id, decl)
proc configureOpenElement*(decl: ElementDeclaration) =
  configureOpenElement(currentContext(), decl)
proc textElement*(text: string, cfg: TextConfig = TextConfig()) =
  textElement(currentContext(), text, cfg)
proc closeElement*() = closeElement(currentContext())
proc setPointerState*(position: Vec2, pointerDown: bool) =
  setPointerState(currentContext(), position, pointerDown)
proc updateScrollContainers*(dragScrolling: bool, scrollDelta: Vec2,
                             deltaTime: float32) =
  updateScrollContainers(currentContext(), dragScrolling, scrollDelta, deltaTime)
proc setMeasureText*(fn: MeasureFn) = setMeasureText(currentContext(), fn)
proc setLayoutDimensions*(dims: Size) = setLayoutDimensions(currentContext(), dims)
proc layoutDimensions*(): Size = layoutDimensions(currentContext())
proc takeErrors*(): seq[ErrorData] = takeErrors(currentContext())
proc openElementId*(): uint32 = openElementId(currentContext())
proc currentScrollOffset*(): Vec2 = currentScrollOffset(currentContext())

proc localId*(label: string): ElementId =
  ## `elementId` hashed against the currently open element's id -- Clay's
  ## `CLAY_ID_LOCAL` for dynamic strings.
  localId(label, openElementId())

proc localIdWithIndex*(label: string; index: uint32): ElementId =
  localIdWithIndex(label, index, openElementId())

proc hovered*(): bool = hovered(currentContext())
proc pointerOver*(id: ElementId): bool = pointerOver(currentContext(), id)
proc onHover*(cb: HoverCallback) = onHover(currentContext(), cb)
proc elementData*(id: ElementId): ElementData = elementData(currentContext(), id)
proc scrollContainerData*(id: ElementId): ScrollContainerData =
  scrollContainerData(currentContext(), id)
proc setScrollPosition*(id: ElementId, position: Vec2) =
  setScrollPosition(currentContext(), id, position)
proc lineText*(cmd: RenderCommand): string = lineText(currentContext(), cmd)

proc renderCommands*(): seq[RenderCommand] =
  ## The current context's render commands from the last `endLayout`.
  renderCommands(currentContext())

iterator commands*(ctx: Context): RenderCommand =
  ## Iterate the render commands produced by `ctx`'s last layout pass.
  for cmd in ctx.commands:
    yield cmd

## --- Nimony plugin DSL --------------------------------------------------------
##
## The replacement for Clay's C macro layer. Both `clay` forms are bodiless
## templates rewritten at each call site by `deps/mclay` (a Nimony template
## plugin compiled by the build graph):
##
##   clay "header", row(gap = 8, padding = padAll(16)):
##     textElement("Hello", TextConfig(fontSize: 24))
##     clay col(width = grow()):
##       ...
##
## expands to balanced open/configure/close calls, and the string-literal id
## is hashed to a uint32 at compile time (Clay's `CLAY_ID` equivalent). The
## one-argument form `clay row(...): ...` gets an auto-generated sibling id
## (Clay's `CLAY_AUTO_ID`). `hashId("...")` computes a standalone id constant
## at compile time for use with `pointerOver`/`elementData`/`scrollContainerData`.

template clay*(label: string, decl: untyped, body: untyped) {.
  plugin: "clay/deps/mclay".}

template clay*(decl: untyped, body: untyped) {.
  plugin: "clay/deps/mclay".}

template hashId*(label: string): ElementId {.
  plugin: "clay/deps/midhash".}
