## Widget events: typed, payload-carrying messages that bubble up the live
## widget nesting until something catches them. See
## `documentation/nim-tutorial.md` §9 (Events) and
## `documentation/owl-tutorial.md` §6.

import std/syncio

import clay

type
  EventKind* = distinct uint32
    ## A per-event-type id: FNV-1a of the type's qualified name.
  WidgetKey* = distinct uint64
    ## Stable identity of one widget invocation (see the module header).
  EventFlow* = enum
    efConsumed  ## the handler caught the event: stop bubbling
    efReemit    ## the handler ran and passed the event on
    efPass      ## no handler for this kind in this frame
  EventHandler* = proc (kind: EventKind, payload: pointer): EventFlow {.closure.}

  EventFrame = object
    key: WidgetKey
    name: string
    handler: EventHandler
    handles: seq[EventKind]
    children: uint32          ## widget children pushed so far this frame

  EventRecord* = object
    ## One `emit`: what was emitted, from where, and who handled it.
    kind*: EventKind
    name*: string
    source*: WidgetKey            ## innermost frame at the emit, 0 = none
    path*: seq[WidgetKey]         ## frames the event visited, innermost first
    handledBy*: seq[WidgetKey]    ## frames whose handler ran for it
    consumed*: bool               ## some handler stopped it

  KindEntry = object
    kind: EventKind
    name: string

proc `==`*(a, b: EventKind): bool {.borrow.}
proc `==`*(a, b: WidgetKey): bool {.borrow.}
proc `$`*(k: EventKind): string = $uint32(k)
proc `$`*(k: WidgetKey): string = $uint64(k)

proc `==`*(a, b: ElementId): bool =
  ## Element ids are equal when their hashes are: what a handler means by
  ## `if e.id == saveId`. (The debug `label` may differ between an id
  ## built by `hashId` and one rebuilt from its hash.)
  a.id == b.id

proc noHandler(kind: EventKind, payload: pointer): EventFlow = efPass

var
  frames: seq[EventFrame] = @[]
  rootChildren = 0'u32       ## root-level widget frames pushed this frame
  rootGen = 0'u32            ## clay generation `rootChildren` counts for
  dispatchDepth = 0          ## nested `dispatchEvent` calls in flight
  dispatchStart = -1         ## while a handler runs: the frame to start at
  reemitRequested = false
  logNow: seq[EventRecord] = @[]
  logNowGen = 0'u32
  logLast: seq[EventRecord] = @[]
  logLastGen = 0'u32
  kinds: seq[KindEntry] = @[]

# --- kinds ---------------------------------------------------------------------

proc registerEventKind*(kind: EventKind, name: string) =
  ## Record a declared event type (the generated code calls this at module
  ## init). Two distinct names hashing to one kind abort start-up: their
  ## handlers would catch each other's events.
  for e in kinds:
    if e.kind == kind:
      if e.name != name:
        echo "ellipse_ui/events: event kind collision between `", e.name,
          "` and `", name, "` -- rename one of them"
        quit 1
      return
  kinds.add KindEntry(kind: kind, name: name)

proc eventKindName*(kind: EventKind): string =
  ## The qualified name a kind was registered with, "" when unknown.
  for e in kinds:
    if e.kind == kind:
      return e.name
  return ""

# --- frames --------------------------------------------------------------------

proc mixKey(a: uint64, b: uint64): uint64 =
  ## One splitmix64 round over `a xor b`.
  var z = (a xor b) + 0x9E3779B97F4A7C15'u64
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  result = z xor (z shr 31)

## --- widget trace ------------------------------------------------------------
##
## Off by default; the debug overlay (`ellipse_ui/debug`) switches it on to
## learn, per frame, every widget invocation and the clay elements its body
## declared -- enough to box it on screen and attribute render commands.

type
  WidgetTrace* = object
    key*: WidgetKey
    name*: string
    parent*: int              ## index of the enclosing widget, -1 at the root
    elemStart*, elemEnd*: int ## its body's range in the clay element pool

var
  traceOn = false
  traceNow: seq[WidgetTrace] = @[]
  traceGen = 0'u32
  traceStack: seq[int] = @[]

proc setWidgetTrace*(on: bool) =
  traceOn = on
  traceNow.setLen(0)
  traceStack.setLen(0)

proc widgetTrace*(): seq[WidgetTrace] =
  ## The widgets of the current (or, between frames, the last) layout pass,
  ## in call order. Empty unless `setWidgetTrace(true)`.
  traceNow

proc tracePush(key: WidgetKey, name: string) =
  let ctx = currentContext()
  if ctx.generation != traceGen:
    traceGen = ctx.generation
    traceNow.setLen(0)
    traceStack.setLen(0)
  let parent = if traceStack.len > 0: traceStack[^1] else: -1
  traceStack.add traceNow.len
  traceNow.add WidgetTrace(key: key, name: name, parent: parent,
    elemStart: ctx.elements.len, elemEnd: ctx.elements.len)

proc tracePop() =
  if traceStack.len > 0:
    let i = traceStack[^1]
    traceStack.setLen(traceStack.len - 1)
    if i < traceNow.len:
      traceNow[i].elemEnd = currentContext().elements.len

proc pushEventFrame*(name: string, nameHash: uint32, id: uint32,
                     handler: EventHandler, handles: seq[EventKind]) =
  ## Open the event frame of one widget invocation (generated code). `id`
  ## is the widget's element id when it has one, else 0 -- then the frame
  ## is keyed by its position among its parent's widget children.
  var parent = 0'u64
  var index = 0'u32
  if frames.len > 0:
    parent = uint64(frames[^1].key)
    index = frames[^1].children
    frames[^1].children += 1'u32
  else:
    let ctx = currentContext()
    let gen = ctx.generation
    if gen != rootGen:
      rootGen = gen
      rootChildren = 0'u32
    index = rootChildren
    rootChildren += 1'u32
  var key = mixKey(parent, uint64(nameHash))
  if id != 0'u32:
    key = mixKey(key, 0x1_0000_0000'u64 or uint64(id))
  else:
    key = mixKey(key, uint64(index))
  frames.add EventFrame(key: WidgetKey(key), name: name, handler: handler,
                        handles: handles, children: 0'u32)
  if traceOn:
    tracePush(WidgetKey(key), name)

proc pushEventFrame*(name: string, nameHash: uint32, id: uint32) =
  ## A frame with no handlers: it still has a key and shows up in paths.
  pushEventFrame(name, nameHash, id, noHandler, @[])

proc popEventFrame*() =
  ## Close the innermost frame (generated code, from a `finally`).
  if frames.len > 0:
    frames.setLen(frames.len - 1)
    if traceOn:
      tracePop()

proc eventDepth*(): int =
  ## Frames open right now: 0 outside every widget and `handleEvents`.
  frames.len

proc currentWidgetKey*(): WidgetKey =
  ## The key of the innermost open frame, 0 outside every widget.
  if frames.len == 0:
    return WidgetKey(0'u64)
  return frames[^1].key

# --- dispatch ------------------------------------------------------------------

proc handles(f: EventFrame, kind: EventKind): bool =
  for k in f.handles:
    if k == kind:
      return true
  return false

proc reemit*() =
  ## Inside an `event` handler: pass the event on to the next frame up once
  ## the handler returns, instead of consuming it. Changes the handler made
  ## to the payload travel with it.
  reemitRequested = true

proc noteRecord(rec: EventRecord) =
  let ctx = currentContext()
  let gen = ctx.generation
  if gen != logNowGen:
    logLast = logNow
    logLastGen = logNowGen
    logNow = @[]
    logNowGen = gen
  logNow.add rec

proc dispatchEvent*(kind: EventKind, name: string, payload: pointer): bool =
  ## Bubble one event (generated `emit` overloads call this): run the
  ## handlers for `kind` from the innermost frame outwards until one
  ## consumes it. Returns true when some handler consumed it.
  var at = frames.len - 1
  if dispatchDepth > 0:
    at = min(dispatchStart, frames.len - 1)
  var rec = EventRecord(kind: kind, name: name, path: @[], handledBy: @[],
                        consumed: false)
  if at >= 0:
    rec.source = frames[at].key
  let savedStart = dispatchStart
  let savedReemit = reemitRequested
  inc dispatchDepth
  try:
    while at >= 0:
      rec.path.add frames[at].key
      if handles(frames[at], kind):
        rec.handledBy.add frames[at].key
        reemitRequested = false
        dispatchStart = at - 1
        let handler = frames[at].handler
        let flow = handler(kind, payload)
        if flow == efConsumed and not reemitRequested:
          rec.consumed = true
          break
      dec at
  finally:
    dec dispatchDepth
    dispatchStart = savedStart
    reemitRequested = savedReemit
  result = rec.consumed
  noteRecord(rec)

# --- the log -------------------------------------------------------------------

proc eventLog*(): seq[EventRecord] =
  ## The emits of the last complete frame, in emit order. Mid-layout that
  ## is the previous generation's log, between frames the one just laid
  ## out -- the same rotation as the focus chain.
  let ctx = currentContext()
  var complete = ctx.generation
  if ctx.openStack.len > 1:     # mid-layout: root + its scope are open
    complete -= 1'u32
  if logNowGen == complete:
    return logNow
  if logLastGen == complete:
    return logLast
  return @[]

proc currentEventLog*(): seq[EventRecord] =
  ## The emits of the frame in progress so far (or of the latest frame).
  let ctx = currentContext()
  if logNowGen == ctx.generation:
    return logNow
  return @[]

# --- the DSL -------------------------------------------------------------------
#
# `handleEvents` and `defineEvent` are macros (ported from the nimony
# template plugin; the code generation is in `deps/mevents` +
# `deps/meventgen`), included here so they export with this module.

include ./deps/mevents
