## Dialogs, form dialogs and quick popups -- in the app's window, or in a
## window of their own. See `documentation/nim-tutorial.md` §13 (Dialogs), its
## §13.3 for the forms helpers below, and `documentation/owl-tutorial.md`
## §9 (App, dialogs and popups).

{.push gcsafe.}


import std/[strutils, syncio, os, cmdline, envvars]

import clay
import ellipse/logger
import ellipse/platform/platform
import ellipse/platform/transient
import ellipse/platform/process
import ./ui
import ./keys
import ./widgets
import ./dialogs/fields

export fields

type
  DialogMode* = enum
    dmInline   ## a modal overlay in the app's window
    dmWindow   ## a window of its own, run by a child process

  DialogStatus* = enum
    dsOpen       ## still up (never delivered to `onDone`)
    dsAccepted   ## closed through `accept` (an OK-type answer)
    dsCancelled  ## Escape, Cancel, the backdrop, the window's close box
    dsFailed     ## the dialog process died or answered nonsense

  DialogResult* = object
    status*: DialogStatus
    answer*: string      ## which button closed it ("ok", "Save", ...)
    fields*: Fields      ## what the dialog handed back

  DialogFn* = proc () {.closure.}
  DialogDone* = proc (r: DialogResult) {.closure.}

  DialogHeader* = object
    ## An inline dialog's title bar: the title, and optionally a drag
    ## handle, a fullscreen toggle and a close button. Off by default (the
    ## title is then a plain heading). A dialog in its own window never
    ## draws it -- the window's own title bar does that job.
    enabled*: bool
    draggable*: bool = true    ## drag the header to move the dialog
    fullscreen*: bool          ## a fill-the-window toggle (or double-click)
    closeButton*: bool = true  ## cancels, like Escape (`dismissable` aside)

  DialogSpec* = object
    ## How a dialog looks and behaves; `body` is required.
    title*: string             ## the panel heading / the window title
    header*: DialogHeader      ## inline only: a title bar instead
    width*: float32 = 420      ## max panel width, the window's width
    maxHeight*: float32 = 640  ## inline cap; a `scroll` window's height
    scroll*: bool              ## the body scrolls between title and footer
    dismissable*: bool = true  ## Escape and the backdrop cancel it
    body*: DialogFn
    footer*: DialogFn      ## a right-aligned row under the body

  Dialog* = object
    ## A defined dialog, by name: `defineDialog`'s handle for `open`.
    name*: string

  DialogHandle* = int
    ## One opening of a dialog (`lastOpened()` right after the `open`):
    ## `dialogIsOpen(h)`, `closeDialog(h, ...)`. The openers return
    ## nothing on purpose -- a discardable result plus a closure argument
    ## as the last statement of an `if` branch crashes the compiler.

  Instance = object
    handle: int
    spec: int
    title: string      ## the opener's title, over the spec's
    mode: DialogMode
    args: Fields
    onDone: DialogDone
    status: DialogStatus
    answer: string
    result: Fields
    fresh: bool        ## first frame: `dialogOpened`
    enter: bool        ## Enter was caught this frame
    passEnter: bool    ## the body passed Enter through (last frame)
    child: ChildProcess
    modal: bool
    dx, dy: float32    ## dragged away from the centre (layout pixels)
    full: bool         ## fills the window (the header's toggle)
    wasFull: bool      ## last frame's layout was the full-window one
    dragging: bool
    grabX, grabY: float32
    grabDx, grabDy: float32

  Toast = object
    message: string
    until: int64

const
  DialogFlag* = "--ellipse-dialog="
    ## The command-line flag that makes an ellipse app a dialog process.
  ResultMarker = "\x1Eellipse-dialog-result:"
  PollNs = 40_000_000'i64   ## how often a window dialog is checked on
  ZBase = 30000             ## overlays sit over menus and scrollbars

var
  specNames {.threadvar.}: seq[string]
  specs {.threadvar.}: seq[DialogSpec]
  stack {.threadvar.}: seq[Instance]
  windows {.threadvar.}: seq[Instance]
  toasts {.threadvar.}: seq[Toast]
  nextHandle = 1
  lastHandle = 0
  cur = -1                       ## the instance whose body is running
  keysInstalled = false

  # the child-process side
  childParsed = false
  childReq {.threadvar.}: Fields
  childEmitted = false
  childShown = false
  childFrames = 0
specNames = @[]
specs = @[]
stack = @[]     ## inline dialogs, bottom to top
windows = @[]   ## dialogs out in child processes
toasts = @[]

proc findSpec(name: string): int =
  var i = 0
  while i < specNames.len:
    if specNames[i] == name:
      return i
    inc i
  -1

proc defineDialog*(name: string; spec: DialogSpec): Dialog {.discardable.} =
  ## Register (or replace) the dialog `name`. Must run in every process
  ## that may show it -- module level or the app's `prepare` hook.
  let i = findSpec(name)
  if i >= 0:
    specs[i] = spec
  else:
    specNames.add name
    specs.add spec
  Dialog(name: name)

proc accepted*(r: DialogResult): bool = r.status == dsAccepted

## --- the dialog keymap ----------------------------------------------------------------

proc anyModal(): bool =
  if stack.len > 0:
    return true
  for w in windows:
    if w.modal:
      return true
  false

proc topWantsEnter(): bool =
  stack.len > 0 and not stack[^1].passEnter

proc topEscape() =
  if stack.len == 0:
    return
  let top = stack.len - 1
  if specs[stack[top].spec].dismissable and stack[top].status == dsOpen:
    stack[top].status = dsCancelled
    closeDropdown()

proc topEnter() =
  if stack.len > 0:
    stack[^1].enter = true

proc installDialogKeys() =
  ## Two maps, re-installed on every open so they sit above whatever the
  ## app installed since: a modal one (Escape; mutes the app's chords) and
  ## above it Enter, active while the top dialog takes it.
  if keysInstalled:
    uninstallKeymap("ellipse.dialogs")
    uninstallKeymap("ellipse.dialogs.enter")
  keysInstalled = true
  var m = Keymap(name: "ellipse.dialogs", modal: true,
                 active: proc (): bool {.closure.} = anyModal())
  m.bindKey("Escape", topEscape)
  installKeymap(m)
  var e = Keymap(name: "ellipse.dialogs.enter",
                 active: proc (): bool {.closure.} = topWantsEnter())
  e.bindKey("Enter", topEnter)
  installKeymap(e)

## --- inside a body ----------------------------------------------------------------------

proc inBody(): bool = cur >= 0 and cur < stack.len

proc dialogArgs*(): Fields =
  ## What the opener passed to the running dialog.
  if inBody(): stack[cur].args else: Fields()

proc dialogOpened*(): bool =
  ## True on the dialog's first frame: seed the body's state here.
  inBody() and stack[cur].fresh

proc dialogEnter*(): bool =
  ## Enter was pressed this frame (and not passed on, see `passEnter`).
  inBody() and stack[cur].enter

proc passEnter*() =
  ## Let Enter reach the focused widget from the next frame on, instead
  ## of `dialogEnter` -- call it every frame a multiline field has focus.
  if inBody():
    stack[cur].passEnter = true

proc dialogInWindow*(): bool =
  ## The running dialog is the root of a dialog process (its own window).
  childParsed and inBody() and cur == 0 and stack[0].mode == dmWindow

proc dialogHandle*(): DialogHandle =
  if inBody(): stack[cur].handle else: 0

proc closeDialog*(status: DialogStatus; answer = ""; values = Fields()) =
  ## End the running dialog with this result. The rest of the frame still
  ## draws it; `onDone` runs once the frame's dialogs are drawn.
  if not inBody():
    return
  stack[cur].status = status
  stack[cur].answer = answer
  stack[cur].result = values
  closeDropdown()

proc dialogFullscreen*(): bool =
  ## The running inline dialog fills the window.
  inBody() and stack[cur].full

proc setDialogFullscreen*(on: bool) =
  ## Fill the window with the running inline dialog, or put it back.
  if inBody():
    stack[cur].full = on
    stack[cur].dragging = false

proc accept*(values = Fields(); answer = "ok") =
  closeDialog(dsAccepted, answer, values)

proc cancel*() =
  closeDialog(dsCancelled, "cancel")

## --- forms ------------------------------------------------------------------------
##
## The shape nearly every form dialog repeats, taken apart: a record edited as a
## draft, fields identified by short names under the dialog's own namespace
## instead of spelled-out `hashId` constants, validation lines that stay hidden
## until the first submit attempt, Enter as Submit except inside a multiline,
## and standard-sized footer buttons. See `documentation/nim-tutorial.md` §13.3
## (Form dialogs).

var formTried* = false   ## a submit was attempted: the field errors show

proc dialogName*(): string =
  ## The running dialog body's spec name, "" outside a body.
  if inBody(): specNames[stack[cur].spec] else: ""

proc fieldId*(name: string): ElementId =
  ## A form field's id: `name` under the running dialog's namespace, so the
  ## same field name in two dialogs is two widgets -- and no `hashId`
  ## constants to declare.
  ##
  ##   draft.title = textField(fieldId("title"), draft.title, "What is it?")
  let n = dialogName()
  elementId(if n.len > 0: n & "." & name else: name)

proc errorText*(msg: string) =
  ## A field's or footer's red one-line complaint.
  text(msg, activeTheme.text.caption, rgb(232, 96, 96))

proc fieldError*(msg: string) =
  ## A field's validation error -- drawn once a submit has been attempted
  ## (see `formSubmit`), so the form starts out quiet.
  if formTried and msg.len > 0:
    errorText(msg)

proc formArgs*[T: tuple|object](x: T; key = "form"): Fields =
  ## Arguments for `open`: the record `x` under `key`, to `beginForm`.
  result = Fields()
  result.putFields(key, fieldsOf(x))

proc beginForm*[T: tuple|object](draft: var T; key = "form") =
  ## Call at the top of a form body. On the dialog's first frame: fill
  ## `draft` from the opener's record (`fillFrom` -- keys the bag lacks
  ## keep the draft's own defaults) and forget a previous submit attempt.
  if dialogOpened():
    draft.fillFrom(dialogArgs().getFields(key))
    formTried = false

proc focusField*(name, text: string) =
  ## Put the caret at the end of the named field's text, before the form
  ## draws it -- at the top of the body, on the first frame.
  focusAt(fieldId(name), text, text.len)

proc enterThrough*(names: varargs[string]) =
  ## Let this frame's Enter reach the named multiline fields (where it
  ## breaks a line) instead of the `formEnter` action.
  for n in names:
    if focusIdOf() == fieldId(n).id:
      passEnter()

template formEnter*(multiline: untyped, body: untyped) =
  ## Enter runs `body` -- except while the caret sits in a named multiline
  ## field, where the newline wins:
  ##
  ##   formEnter "notes":
  ##     submit()
  enterThrough(multiline)
  if dialogEnter():
    body

template formEnter*(body: untyped) =
  ## Enter runs `body`; the form has no multiline to make room for.
  if dialogEnter():
    body

proc formErrors*(errs: varargs[string]): seq[string] =
  ## Collect field complaints into a validation list -- the shape the
  ## `formDialog` macro feeds to `formValid` and `formSubmit`.
  result = @[]
  for e in errs:
    result.add e

proc formValid*(errors: openArray[string]): bool =
  ## Nothing to complain about?
  result = true
  for e in errors:
    if e.len > 0:
      return false

proc formSubmit*[T: tuple|object](draft: T; answer = "ok";
                                  errors: openArray[string]): bool
    {.discardable.} =
  ## A submit was attempted: from now on the field errors show; when all
  ## are empty the dialog closes accepted with `draft` as its record.
  formTried = true
  result = formValid(errors)
  if result:
    accept(fieldsOf(draft), answer)

proc formButton*(label: string; name = ""; width: float32 = 110.0'f32): bool  =
  ## A footer button of the standard dialog size, at `fieldId`
  ## `"btn." & name` (or the label, unnamed).
  button(fieldId("btn." & (if name.len > 0: name else: label)), label,
         width = fixedPx(width), height = fixedPx(38),
         fontSize = activeTheme.text.control)

proc formLink*(text: string; name = ""): bool  =
  ## A footer `textLink` at `fieldId("btn." & name)`.
  textLink(fieldId("btn." & (if name.len > 0: name else: text)), text)

## --- dialog definitions ---------------------------------------------------------------
##
## `dialog` and `formDialog` are definition macros in the style of `widget`
## (ported from the nimony template plugin to `ellipse_ui/deps/mdialog`).
## See `documentation/nim-tutorial.md` §13.4 (Defining dialogs).

include ./deps/mdialog

## --- opening -------------------------------------------------------------------------------

proc request(inst: Instance; name: string): Fields =
  ## What a dialog process needs: which dialog, its arguments, and the
  ## parent window to attach to (and centre over, where allowed).
  result = Fields()
  result.put("name", name)
  result.putFields("args", inst.args)
  result.put("parent", parentToken())
  let b = windowBounds()
  result.put("px", int(b.x))
  result.put("py", int(b.y))
  result.put("pw", int(b.width))
  result.put("ph", int(b.height))
  result.put("modal", inst.modal)
  result.put("title", inst.title)

var dialogLauncher* {.threadvar.}: seq[string]
  ## The command a window dialog's process starts with, before its
  ## `--ellipse-dialog=` argument; empty means this executable alone. A
  ## host that runs programs (an interpreter) puts its own command here,
  ## so the child runs the same program.
dialogLauncher = @[]

proc open*(d: Dialog; args = Fields(); mode = dmInline;
           onDone: DialogDone = nil; title = "";
           modal = true) =
  ## Show the dialog. `args` reach the body through `dialogArgs`, the
  ## result reaches `onDone`; `title` overrides the spec's. `modal` only
  ## matters for `dmWindow`: off, the app stays usable while the dialog
  ## window is up.
  let si = findSpec(d.name)
  if si < 0:
    warn "dialog not defined: ", d.name
    let cb = onDone
    if cb != nil:
      cb(DialogResult(status: dsFailed, answer: "undefined"))
    return
  let shown = if title.len > 0: title else: specs[si].title
  var inst = Instance(handle: nextHandle, spec: si, title: shown, mode: mode,
                      args: args, onDone: onDone, status: dsOpen,
                      fresh: true, modal: modal)
  inc nextHandle
  lastHandle = inst.handle
  installDialogKeys()
  requestFrame()
  if mode == dmWindow and terminalMode():
    inst.mode = dmInline   # a terminal has no second window to give it
  if inst.mode == dmWindow:
    let req = request(inst, d.name)
    var cmd = dialogLauncher
    if cmd.len == 0:
      cmd = @[getAppFilename()]
    cmd.add DialogFlag & encode(req)
    var child = spawnProcess(cmd)
    if child.running:
      inst.child = child
      if modal:
        setWindowEnabled(false)
      windows.add inst
      requestFrameIn(PollNs)
      return
    warn "could not start a dialog process for ", d.name, "; showing it inline"
    inst.mode = dmInline
  stack.add inst

proc openDialog*(name: string; args = Fields(); mode = dmInline;
                 onDone: DialogDone = nil;
                 title = "") =
  ## `open` by name.
  open(Dialog(name: name), args, mode, onDone, title)

proc lastOpened*(): DialogHandle =
  ## The handle of the most recent `open` (or popup): for `dialogIsOpen`
  ## and `closeDialog(h)`. 0 when that open failed.
  lastHandle

proc dialogIsOpen*(h: DialogHandle): bool =
  for s in stack:
    if s.handle == h and s.status == dsOpen:
      return true
  for w in windows:
    if w.handle == h:
      return true
  false

proc anyDialogOpen*(): bool =
  ## Something modal is up: an inline dialog or a modal dialog window.
  anyModal()

proc closeDialog*(h: DialogHandle; status = dsCancelled; answer = "") =
  ## Close an open dialog from outside its body (a window dialog's process
  ## is asked to stop; its `onDone` sees `status`).
  var i = 0
  while i < stack.len:
    if stack[i].handle == h and stack[i].status == dsOpen:
      stack[i].status = status
      stack[i].answer = answer
    inc i
  i = 0
  while i < windows.len:
    if windows[i].handle == h:
      windows[i].status = status
      windows[i].answer = answer
      windows[i].child.kill()
    inc i

## --- window dialogs, the opener's side -------------------------------------------------

proc lastIndexOf(s, sub: string): int =
  result = -1
  var at = s.find(sub)
  while at >= 0:
    result = at
    at = s.find(sub, at + 1)

proc parseResult(output: string; found: var bool): DialogResult =
  ## The last result line a dialog process wrote; `found` says whether
  ## there was one.
  found = false
  result = DialogResult(status: dsFailed)
  let at = lastIndexOf(output, ResultMarker)
  if at < 0:
    return
  found = true
  let start = at + ResultMarker.len
  var stop = output.find('\n', start)
  if stop < 0:
    stop = output.len
  let f = decode(output.substr(start, stop - 1))
  let word = f.get("status")
  if word == "accepted":
    result.status = dsAccepted
  elif word == "cancelled":
    result.status = dsCancelled
  result.answer = f.get("answer")
  result.fields = f.getFields("fields")

proc deliver(x: var Instance) =
  ## A window dialog's process has finished: read its answer, release
  ## the process, run `onDone`.
  var ok = false
  var r = parseResult(x.child.output, ok)
  if x.status != dsOpen:
    # closed from our side (`closeDialog(h)`): our verdict stands
    r = DialogResult(status: x.status, answer: x.answer)
  elif not ok:
    # (a log call can't end a branch: hexer chokes on the discardable)
    warn "dialog process ended without a result (exit code ",
      $int(x.child.exitCode), ")"
    discard
  x.child.close()
  let cb = x.onDone
  if cb != nil:
    cb(r)

proc pollWindows() =
  var finished: seq[Instance] = @[]
  var keep: seq[Instance] = @[]
  var i = 0
  while i < windows.len:
    if windows[i].child.poll():
      finished.add windows[i]
    else:
      keep.add windows[i]
    inc i
  if finished.len == 0:
    return
  windows = keep
  var stillModal = false
  i = 0
  while i < windows.len:
    if windows[i].modal:
      stillModal = true
    inc i
  if not stillModal:
    setWindowEnabled(true)
    raiseWindow()
  i = 0
  while i < finished.len:
    deliver(finished[i])
    inc i
  requestFrame()

proc expireToasts() =
  if toasts.len == 0:
    return
  let now = monoNow()
  var live: seq[Toast] = @[]
  var i = 0
  while i < toasts.len:
    if toasts[i].until > now:
      live.add toasts[i]
    inc i
  if live.len != toasts.len:
    toasts = live
    requestFrame()
  if toasts.len > 0:
    requestFrameAt(toasts[0].until)

proc updateDialogs*() =
  ## Once a frame, before layout: collect window dialogs whose process has
  ## finished (running their `onDone`), and expire toasts.
  pollWindows()
  if windows.len > 0:
    requestFrameIn(PollNs)
  expireToasts()

proc shutdownDialogs*() =
  ## Ask every dialog process to stop -- the app is exiting.
  var i = 0
  while i < windows.len:
    windows[i].child.kill()
    windows[i].child.close()
    inc i
  windows = @[]

## --- drawing --------------------------------------------------------------------------------

proc footerRow(spec: DialogSpec)  =
  let footer = spec.footer
  if footer == nil:
    return
  clay row(width = grow(), height = fit(), gap = 10, alignX = right,
           alignY = centerY):
    footer()

proc bodyArea(spec: DialogSpec; i: int; fill: bool)  =
  ## The body, plain or in a scroll panel that takes the free height.
  let body = spec.body
  if body == nil:
    return
  let t = activeTheme
  if spec.scroll:
    scrollPanel "dlg.body." & $i, col(width = grow(), height = grow(),
        gap = t.metrics.gapTight,
        padding = Padding(right: t.scrollbar.width.int + 6))
        .clip(horizontal = false, vertical = true,
              childOffset = currentScrollOffset()):
      body()
  else:
    clay col(width = grow(), height = (if fill: grow() else: fit()),
             gap = t.metrics.gapTight):
      body()

proc beginBody(i: int): int =
  ## Make instance `i` the current dialog while its body runs; returns
  ## the one to restore (`endBody`).
  result = cur
  cur = i
  stack[i].passEnter = false

proc endBody(i, saved: int) =
  stack[i].fresh = false
  stack[i].enter = false
  cur = saved

proc headerButton(id: ElementId; glyph: int): bool  =
  ## A borderless square button of the header: 0 close (a `×`), 1 enter
  ## fullscreen (a hollow square), 2 leave it (two stacked squares).
  ## Rectangles and the UI font only, like the rest of the widget set.
  let t = activeTheme
  let over = pointerOver(id)
  let press = pressing(id)
  openElement(id)
  configureOpenElement(col(width = fixedPx(28), height = fixedPx(28),
      alignX = centerX, alignY = centerY)
    .bg(if over or press: shade(over, press) else: rgb(0, 0, 0, 0))
    .corner(t.radii.button))
  let ink = if over: t.palette.textColor else: t.palette.dimColor
  if glyph == 0:
    textElement("×", TextConfig(fontSize: t.text.control + 2, color: ink))
  elif glyph == 1:
    clay col(width = fixedPx(12), height = fixedPx(12)).border(2, ink):
      discard
  else:
    # the back square floats up-right of the front one, on this layer
    let z = min(enclosingZIndex(), 32764'i16) + 1'i16
    clay col(width = fixedPx(13), height = fixedPx(13), alignX = left,
             alignY = bottom):
      clay col(width = fixedPx(9), height = fixedPx(9)).border(1, ink)
          .floating(attachParent, offset = vec2(4.0, -4.0), zIndex = z,
                    points = AttachPoints(element: pointLeftBottom,
                                          parent: pointLeftBottom),
                    capture = passThroughPointer):
        discard
      # the front one covers the back one's corner: a layer above it
      clay col(width = fixedPx(9), height = fixedPx(9)).border(2, ink)
          .bg(buttonBg)
          .floating(attachParent, zIndex = z + 1'i16,
                    points = AttachPoints(element: pointLeftBottom,
                                          parent: pointLeftBottom),
                    capture = passThroughPointer):
        discard
  closeElement()
  clickedIn(id)

proc dragStep(i: int; headerId, fsId, closeId: ElementId) =
  ## Start, follow or end a header drag of instance `i`.
  let pd = currentContext().pointerData()
  let down = pd.state == pressed or pd.state == pressedThisFrame
  if stack[i].dragging:
    if not down:
      stack[i].dragging = false
      return
    stack[i].dx = stack[i].grabDx + pd.position.x - stack[i].grabX
    stack[i].dy = stack[i].grabDy + pd.position.y - stack[i].grabY
    trackPointer()
    requestFrame()
  elif pressedNow() and pointerOver(headerId) and not pointerOver(fsId) and
       not pointerOver(closeId):
    stack[i].dragging = true
    stack[i].grabX = pd.position.x
    stack[i].grabY = pd.position.y
    stack[i].grabDx = stack[i].dx
    stack[i].grabDy = stack[i].dy
    trackPointer()

proc clampOffset(i: int; panelId: ElementId) =
  ## Keep a dragged dialog inside the window's 24px margin: the centre may
  ## move by half the slack the panel leaves on each axis.
  let box = elementData(panelId).box
  let (ww, wh) = windowPixelSize()
  let mx = max(0.0'f32, (ww - 48.0'f32 - box.width) / 2.0'f32)
  let my = max(0.0'f32, (wh - 48.0'f32 - box.height) / 2.0'f32)
  stack[i].dx = max(-mx, min(mx, stack[i].dx))
  stack[i].dy = max(-my, min(my, stack[i].dy))

proc drawHeader(i: int; spec: DialogSpec; full: bool)  =
  let t = activeTheme
  let h = spec.header
  let headerId = elementIdWithIndex("dlg.head", uint32(i))
  let fsId = elementIdWithIndex("dlg.head.fs", uint32(i))
  let closeId = elementIdWithIndex("dlg.head.close", uint32(i))
  let r = if full: 0.0'f32 else: t.radii.panel
  openElement(headerId)
  configureOpenElement(row(width = grow(), height = fixedPx(42), gap = 4,
      padding = Padding(left: 16, right: 7), alignY = centerY)
    .bg(buttonBg)
    .corner(r, r, 0.0, 0.0))
  textElement(stack[i].title, TextConfig(fontSize: t.text.control,
    color: t.palette.textColor))
  spacer()
  var toggle = false
  if h.fullscreen:
    toggle = headerButton(fsId, if full: 2 else: 1)
  if h.closeButton:
    if headerButton(closeId, 0):
      stack[i].status = dsCancelled
      stack[i].answer = "close"
      closeDropdown()
  closeElement()
  # the hairline under the bar
  clay row(width = grow(), height = fixedPx(1)).bg(panelBorder):
    discard
  if h.fullscreen and pressedNow() and doubleClick() and
     pointerOver(headerId) and not pointerOver(fsId) and
     not pointerOver(closeId):
    toggle = true
  if toggle:
    stack[i].full = not full
    stack[i].dragging = false
  elif h.draggable and not full and i == stack.len - 1:
    dragStep(i, headerId, fsId, closeId)

proc drawInline(i: int)  =
  ## One inline dialog: a backdrop over the window and a panel, centred
  ## -- or moved by a header drag, or filling the window.
  let t = activeTheme
  let spec = specs[stack[i].spec]
  let z = int16(ZBase + 2 * i)
  let backId = elementIdWithIndex("dlg.back", uint32(i))
  let panelId = elementIdWithIndex("dlg.panel", uint32(i))
  let header = spec.header.enabled
  let full = header and stack[i].full
  # (the clamp reads last frame's box: not the full-window one)
  if not full and not stack[i].wasFull:
    clampOffset(i, panelId)
  stack[i].wasFull = full
  # A drag shifts the centring: the padding on the side moved away from
  # grows by twice the offset.
  var pad = padAll(if full: 0 else: 24)
  if not full:
    let dx = int(stack[i].dx * 2.0'f32)
    let dy = int(stack[i].dy * 2.0'f32)
    pad.left += max(0, dx)
    pad.right += max(0, -dx)
    pad.top += max(0, dy)
    pad.bottom += max(0, -dy)
  openElement(backId)
  configureOpenElement(row(width = grow(), height = grow(),
      padding = pad, alignX = centerX, alignY = centerY)
    .bg(rgb(0, 0, 0, 100))
    .floating(attachRoot, zIndex = z,
              points = AttachPoints(element: pointLeftTop,
                                    parent: pointLeftTop)))
  if i == stack.len - 1 and spec.dismissable and clickedIn(backId) and
     not pointerOver(panelId):
    stack[i].status = dsCancelled
    closeDropdown()
  openElement(panelId)
  configureOpenElement(col(
      width = (if full: grow() else: grow(max = spec.width)),
      height = (if full: grow() else: fit(max = spec.maxHeight)))
    .bg(panelBg)
    .border(hairline, panelBorder)
    .corner(if full: 0.0'f32 else: t.radii.panel))
  if header:
    drawHeader(i, spec, full)
  clay col(width = grow(), height = (if full or spec.scroll: grow() else: fit()),
           gap = t.metrics.gapCard,
           padding = Padding(left: 18, right: 18, bottom: 18,
                             top: (if header: 14 else: 18))):
    if not header and stack[i].title.len > 0:
      heading(stack[i].title, 3)
    bodyArea(spec, i, full)
    footerRow(spec)
  closeElement()   # panel
  closeElement()   # backdrop

proc drawWaiting(w: Instance; k: int)  =
  ## The opener's window while a modal dialog window is up: dimmed, deaf
  ## to the pointer, with a way to give up on the dialog.
  let t = activeTheme
  let backId = elementIdWithIndex("dlg.wait", uint32(k))
  openElement(backId)
  configureOpenElement(row(width = grow(), height = grow(),
      padding = padAll(24), alignX = centerX, alignY = centerY)
    .bg(rgb(0, 0, 0, 100))
    .floating(attachRoot, zIndex = int16(ZBase - 2),
              points = AttachPoints(element: pointLeftTop,
                                    parent: pointLeftTop)))
  clay col(width = fit(), height = fit(), gap = 8, padding = padAll(14),
           alignX = centerX)
      .bg(panelBg).border(hairline, panelBorder).corner(panelRadius):
    let name = if w.title.len > 0: "\"" & w.title & "\"" else: "A dialog"
    text(name & " is open in its own window", t.text.control,
         t.palette.textColor)
    if textLink(elementIdWithIndex("dlg.wait.close", uint32(k)),
                "Close it"):
      closeDialog(w.handle, dsCancelled, "cancel")
  closeElement()

proc drawToasts()  =
  if toasts.len == 0:
    return
  let t = activeTheme
  openElement(elementId("dlg.toasts"))
  configureOpenElement(col(width = fit(), height = fit(), gap = 8,
      alignX = centerX)
    .floating(attachRoot, offset = vec2(0.0, -28.0), zIndex = int16(ZBase + 500),
              points = AttachPoints(element: pointCenterBottom,
                                    parent: pointCenterBottom),
              capture = passThroughPointer))
  for m in toasts:
    clay row(width = fit(max = 520), height = fit(), padding = padAll(12))
        .bg(panelBg).border(hairline, panelBorder).corner(panelRadius):
      text(m.message, t.text.control, t.palette.textColor)
  closeElement()

proc finishInline(first: int) =
  ## Hand the closed inline dialogs (from `first` up) to their `onDone`.
  var done: seq[Instance] = @[]
  var keep: seq[Instance] = @[]
  var i = 0
  while i < stack.len:
    if i >= first and stack[i].status != dsOpen:
      done.add stack[i]
    else:
      keep.add stack[i]
    inc i
  if done.len == 0:
    return
  stack = keep
  requestFrame()
  for d in done:
    let cb = d.onDone
    if cb != nil:
      cb(DialogResult(status: d.status, answer: d.answer, fields: d.result))

proc drawDialogs*()  =
  ## Draw the open dialogs over the view, top-most last. Call inside
  ## `layout`, after everything else, once a frame.
  var k = 0
  while k < windows.len:
    if windows[k].modal:
      drawWaiting(windows[k], k)
    inc k
  # a dialog process draws its own root dialog full-window (see below)
  let first = if childParsed: 1 else: 0
  var i = first
  while i < stack.len:
    let saved = beginBody(i)
    drawInline(i)
    endBody(i, saved)
    inc i
  drawToasts()
  finishInline(first)

## --- toasts --------------------------------------------------------------------------------

proc toast*(message: string; seconds = 2.5) =
  ## A transient note at the bottom of the window: no buttons, no focus,
  ## gone after `seconds`. Always inline.
  toasts.add Toast(message: message,
                   until: monoNow() + int64(seconds * 1_000_000_000.0))
  requestFrame()

## --- the quick popups ----------------------------------------------------------------------
##
## One built-in dialog, "ellipse.message", draws them all: a message, an
## optional text field, and a row of buttons. Its result's `answer` is the
## button's label, `fields` carry "index" (the button) and "text".

var
  msgText {.threadvar.}: string
  msgButtons {.threadvar.}: seq[string]
  msgDefault = 0
msgButtons = @[]

proc msgField(): ElementId = elementId("dlg.msg.field")

proc msgFinish(index: int) =
  var r = Fields()
  r.put("index", index)
  r.put("text", msgText)
  let a = dialogArgs()
  if index == a.getInt("cancelIndex", -1):
    closeDialog(dsCancelled, msgButtons[index], r)
  else:
    closeDialog(dsAccepted, msgButtons[index], r)

proc msgBody()  =
  let a = dialogArgs()
  if dialogOpened():
    msgText = a.get("text")
    msgButtons = a.getList("buttons")
    if msgButtons.len == 0:
      msgButtons.add "OK"
    msgDefault = a.getInt("default", 0)
  bodyText(a.get("message"))
  let detail = a.get("detail")
  if detail.len > 0:
    caption(detail)
  if a.getBool("input"):
    msgText = textField(msgField(), msgText, a.get("placeholder"))
    if dialogOpened():
      focusAt(msgField(), msgText, msgText.len)
  if dialogEnter() and msgDefault >= 0 and msgDefault < msgButtons.len:
    msgFinish(msgDefault)

proc msgFooter()  =
  var i = 0
  while i < msgButtons.len:
    if button(elementIdWithIndex("dlg.msg.btn", uint32(i)), msgButtons[i],
              width = fit(min = 90), height = fixedPx(38),
              fontSize = activeTheme.text.control):
      msgFinish(i)
    inc i

var messageDialog* {.threadvar.}: Dialog
messageDialog = defineDialog("ellipse.message", DialogSpec(
  width: 440, body: msgBody, footer: msgFooter))

proc messageBox*(message: string; buttons: openArray[string]; title = "";
              detail = ""; default = 0; cancelIndex = -1; input = false;
              text = ""; placeholder = ""; mode = dmInline;
              onDone: DialogDone = nil) =
  ## The general popup behind `alert`/`confirm`/`ask`/`prompt`: Enter
  ## presses button `default`; button `cancelIndex` (and Escape) cancel.
  var a = Fields()
  a.put("message", message)
  a.put("detail", detail)
  a.putList("buttons", buttons)
  a.put("default", default)
  a.put("cancelIndex", cancelIndex)
  a.put("input", input)
  a.put("text", text)
  a.put("placeholder", placeholder)
  messageDialog.open(a, mode, onDone, title)

proc alert*(message: string; title = ""; detail = ""; mode = dmInline;
            onDone: DialogDone = nil) =
  ## A message and an OK button.
  messageBox(message, ["OK"], title, detail, mode = mode, onDone = onDone)

proc confirm*(message: string; onAnswer: proc (yes: bool) {.closure.};
              title = ""; yes = "OK"; no = "Cancel"; detail = "";
              mode = dmInline) =
  ## A yes/no question; Escape or the backdrop answer no.
  let cb = onAnswer
  messageBox(message, [no, yes], title, detail, default = 1, cancelIndex = 0,
    mode = mode, onDone = proc (r: DialogResult) {.closure.} =
      cb(r.accepted))

proc ask*(message: string; buttons: openArray[string];
          onAnswer: proc (index: int) {.closure.}; title = ""; detail = "";
          default = 0; cancelIndex = -1;
          mode = dmInline) =
  ## A choice between `buttons`; `onAnswer` gets the chosen index, or -1
  ## when the dialog was dismissed without one (Escape, the close box).
  let cb = onAnswer
  messageBox(message, buttons, title, detail, default, cancelIndex,
    mode = mode, onDone = proc (r: DialogResult) {.closure.} =
      cb(r.fields.getInt("index", -1)))

proc prompt*(message: string; onText: proc (text: string) {.closure.};
             title = ""; text = ""; placeholder = ""; ok = "OK";
             cancelLabel = "Cancel";
             mode = dmInline) =
  ## A one-line text question; `onText` runs only on OK (or Enter).
  let cb = onText
  messageBox(message, [cancelLabel, ok], title, default = 1, cancelIndex = 0,
    input = true, text = text, placeholder = placeholder, mode = mode,
    onDone = proc (r: DialogResult) {.closure.} =
      if r.accepted:
        cb(r.fields.get("text")))

## --- window dialogs, the dialog process's side ---------------------------------------
##
## `run` asks `isDialogProcess()` first; when it is one, the app's view is
## replaced by `dialogProcessView`, the window comes from
## `dialogProcessWindow`, and `dialogProcessAfter` / `endDialogProcess`
## do the rest.

proc parseChild() =
  if childParsed:
    return
  let params = commandLineParams()
  var i = 0
  while i < params.len:
    let p = params[i]
    if p.startsWith(DialogFlag):
      childReq = decode(p.substr(DialogFlag.len))
      childParsed = true
      return
    inc i

proc isDialogProcess*(): bool =
  ## This process was started to show one dialog (`--ellipse-dialog=`).
  parseChild()
  childParsed

proc dialogProcessWindow*(): WindowConfig =
  ## The dialog process's window: the dialog's width, a provisional
  ## height (fitted to the content after the first layout), unmapped
  ## until then.
  parseChild()
  let si = findSpec(childReq.get("name"))
  var w = 420'f32
  var h = 240'f32
  var title = childReq.get("title")
  if si >= 0:
    w = specs[si].width
    if specs[si].scroll:
      h = specs[si].maxHeight
    if title.len == 0:
      title = specs[si].title
  if title.len == 0:
    title = "Dialog"
  WindowConfig(title: title, width: int32(w), height: int32(h),
               resizable: si >= 0 and specs[si].scroll, hidden: true)

proc emitResult(status: DialogStatus; answer: string; values: Fields) =
  if childEmitted:
    return
  childEmitted = true
  var word = "failed"
  if status == dsAccepted:
    word = "accepted"
  elif status == dsCancelled:
    word = "cancelled"
  var f = Fields()
  f.put("status", word)
  f.put("answer", answer)
  f.putFields("fields", values)
  stdout.write "\n" & ResultMarker & encode(f) & "\n"
  flushFile(stdout)

proc startDialogProcess*(): bool =
  ## After the window is up: queue the requested dialog as the root of
  ## the stack. False (and a failed result written) when this program
  ## does not define it.
  parseChild()
  let si = findSpec(childReq.get("name"))
  if si < 0:
    error "dialog process: no dialog named \"", childReq.get("name"), "\""
    emitResult(dsFailed, "undefined", Fields())
    return false
  stack.setLen(0)
  stack.add Instance(handle: nextHandle, spec: si, mode: dmWindow,
                     args: childReq.getFields("args"), status: dsOpen,
                     fresh: true, modal: childReq.getBool("modal", true))
  inc nextHandle
  installDialogKeys()
  true

proc drawRoot(i: int)  =
  let t = activeTheme
  let spec = specs[stack[i].spec]
  let fill = spec.scroll
  clay "dlg.root", col(width = grow(), height = grow()).bg(panelBg):
    clay "dlg.content", col(width = grow(),
        height = (if fill: grow() else: fit()),
        gap = t.metrics.gapCard, padding = padAll(18)):
      bodyArea(spec, i, fill)
      footerRow(spec)

proc dialogProcessView*()  =
  ## The dialog process's whole view: its dialog filling the window, then
  ## anything it opened on top.
  if stack.len == 0:
    return
  let saved = beginBody(0)
  drawRoot(0)
  endBody(0, saved)
  drawDialogs()

proc dialogProcessAfter*()  =
  ## After each layout: fit, place, show and parent the window once the
  ## first layout measured the content; quit once the dialog closed.
  if stack.len == 0:
    platform.quit()
    return
  inc childFrames
  if not childShown:
    let si = stack[0].spec
    let data = elementData(hashId("dlg.content"))
    if data.found and data.box.height > 0.0 and not specs[si].scroll:
      let scale = windowPixelScale()
      let b = windowBounds()
      setWindowSize(b.width, int32(data.box.height / scale + 0.5))
    centerOver(int32(childReq.getInt("px")), int32(childReq.getInt("py")),
               int32(childReq.getInt("pw")), int32(childReq.getInt("ph")))
    showWindow()
    let parent = childReq.get("parent")
    let linked = attachToParent(parent, childReq.getBool("modal", true))
    debug "dialog process: parent \"", parent, "\" linked: ", $linked
    raiseWindow()
    childShown = true
    requestFrame()
  if stack[0].status != dsOpen:
    emitResult(stack[0].status, stack[0].answer, stack[0].result)
    platform.quit()
  elif getEnv("ELLIPSE_DIALOG_AUTOCLOSE").len > 0 and childFrames >= 2:
    # test hook: answer at once with the dialog's arguments
    emitResult(dsAccepted, getEnv("ELLIPSE_DIALOG_AUTOCLOSE"),
               stack[0].args)
    platform.quit()

proc endDialogProcess*() =
  ## The loop ended: if the dialog never answered (the window's close
  ## box), that is a cancel.
  emitResult(dsCancelled, "close", Fields())
