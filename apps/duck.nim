## Duck -- a Windows Notepad clone, drawn with ellipse_ui.
##
## The whole widget set at work: a menu bar of `menu`/`menuItem`, the
## document area from `ellipse_ui/widgets/editor`, floating dialogs of the
## same parts, and a status bar of themed text. The state below is all
## module-owned and every mutation flows through the immediate-mode round
## trips the widget library promises; file behaviour (CRLF, save-before-
## close prompts) mirrors the original app as closely as this platform
## allows.
##
## Run:            make run_duck [path/to/file.txt]
## Chords:         Ctrl+N/O/S, Ctrl+Shift+S, Ctrl+F/H/G, Ctrl+Z/Y,
##                 Ctrl+X/C/V/A, F3/F5, Ctrl+wheel or Ctrl+Plus/Minus/0
##                 to zoom, Emacs bindings inside the document (see
##                 ellipse_ui/widgets/common).

import std/[syncio, strutils, os, envvars, cmdline]

import clay
import ellipse/logger
import ellipse/platform/platform
import ellipse/platform/renderer
import ellipse_ui/ui
import ellipse_ui/widgets

import duck/doc
import duck/session

addHandler initStandardLogger()

let baseZoom = 18.uint16   ## the theme's control size: "100%"

proc zoomBy(delta: int) =
  let v = zoomSize.int + delta
  zoomSize =
    if v < 6: 6.uint16
    elif v > 96: 96.uint16
    else: v.uint16

## --- key routing -----------------------------------------------------------------

proc routeKeys(evs: seq[KeyEvent]): seq[KeyEvent] =
  ## The widgets' view of this frame's keystrokes. A modal dialog takes
  ## Enter and Escape for itself (the app runs `primary`/`dismiss` from
  ## the raw queue), and while it's up the app chords don't reach the
  ## document either way -- `blocked` freezes it. Closed dialogs: Ctrl+N
  ## (new) and Ctrl+H (replace) mean Duck's things, not the engine's
  ## Ctrl-N line-down / Ctrl-H rub-out, so they leave the stream too.
  var outp: seq[KeyEvent] = @[]
  for ev in evs:
    if session.open():
      if ev.kind != kevEnter and ev.kind != kevEscape:
        outp.add ev
    else:
      if ev.kind == kevLetter and ev.ctrl and (ev.ch == 'n' or ev.ch == 'h'):
        discard
      else:
        outp.add ev
  outp

proc appChords() =
  ## App-level keys read from the raw queue: they act whether or not the
  ## document holds focus, exactly like menu items.
  let evs = keyEvents()
  if session.open():
    for ev in evs:
      case ev.kind
      of kevEnter: primary()
      of kevEscape:
        if kind == kAsk:
          askBack()
        else:
          dismiss()
      else:
        discard
    return
  for ev in evs:
    case ev.kind
    of kevLetter:
      if ev.ctrl:
        case ev.ch
        of 'n': beginNew()
        of 'o': beginOpen()
        of 's':
          if ev.shift: beginSave()
          else: quickSave()
        of 'f': beginFind()
        of 'h': beginReplace()
        of 'g': beginGoto()
        of '+': zoomBy(2)
        of '-': zoomBy(-2)
        of '0': zoomSize = baseZoom
        else: discard
    of kevF1: beginAbout()
    of kevF3: doFind(ev.shift)
    of kevF5: doStamp()
    of kevF4:
      if ev.alt: beginExit()
    else: discard

## --- the menu strip ----------------------------------------------------------------

proc ghostMenu(label: string) =
  ## A menu-bar button with the modal up: the shape of a menu, none of
  ## the reach -- Notepad greys these out; the wash does the same job.
  let t = activeTheme
  openElement()
  configureOpenElement(col(width = fit(), height = grow(),
      alignX = centerX, alignY = centerY,
      padding = padAll(t.metrics.padButton))
    .bg(buttonBg)
    .corner(t.radii.button)
    .border(hairline, panelBorder))
  textElement(label, TextConfig(fontSize: t.text.menu,
    color: t.palette.dimColor))
  closeElement()

proc menuActions() =
  ## Every menu item hands its act to the session/editor API. The acts
  ## that change the text mark the document dirty by hand: the editor
  ## widget's `edited` flag only covers keystrokes and pointer edits it
  ## sees itself, while these run between its frames.
  menu("File") do():
    if menuItem("New", "Ctrl+N"): beginNew()
    if menuItem("Open...", "Ctrl+O"): beginOpen()
    if menuItem("Save", "Ctrl+S"): quickSave()
    if menuItem("Save As...", "Ctrl+Shift+S"): beginSave()
    menuSeparator()
    if menuItem("Exit", "Alt+F4"): beginExit()
  menu("Edit") do():
    if menuItem("Undo", "Ctrl+Z"):
      if editorUndo(editorId, document.text): noteEdited()
    if menuItem("Redo", "Ctrl+Y"):
      if editorRedo(editorId, document.text): noteEdited()
    menuSeparator()
    if menuItem("Cut", "Ctrl+X"):
      let (lo, hi) = editorSel(editorId, document.text)
      if hi > lo:
        editorCut(editorId, document.text)
        noteEdited()
      else:
        editorCopy(editorId, document.text)   # Notepad: Cut with no selection copies
    if menuItem("Copy", "Ctrl+C"): editorCopy(editorId, document.text)
    if menuItem("Delete", "Del"):
      let (lo, hi) = editorSel(editorId, document.text)
      if hi > lo:
        editorDelete(editorId, document.text)
        noteEdited()
    if menuItem("Paste", "Ctrl+V"):
      let c = getClipboard()
      if c.len > 0:
        editorPaste(editorId, document.text)
        noteEdited()
    menuSeparator()
    if menuItem("Find...", "Ctrl+F"): beginFind()
    if menuItem("Find Next", "F3"): doFind()
    if menuItem("Replace...", "Ctrl+H"): beginReplace()
    menuSeparator()
    if menuItem("Go To...", "Ctrl+G"): beginGoto()
    if menuItem("Select All", "Ctrl+A"): editorSelectAll(editorId, document.text)
    if menuItem("Time/Date", "F5"): doStamp()
  menu("Format") do():
    if menuItem("Word Wrap", if wrapOn: "✓" else: ""):
      wrapOn = not wrapOn
    if menuItem("Font...", ""): beginFont()
  menu("View") do():
    if menuItem("Zoom In", "Ctrl+Plus"): zoomBy(2)
    if menuItem("Zoom Out", "Ctrl+Minus"): zoomBy(-2)
    if menuItem("Restore Zoom", "Ctrl+0"): zoomSize = baseZoom
    menuSeparator()
    if menuItem("Status Bar", if statusOn: "✓" else: ""):
      statusOn = not statusOn
  menu("Help") do():
    if menuItem("View Help", "F1"): beginAbout()
    if menuItem("About Duck", ""): beginAbout()

proc menuStrip() =
  if open():
    ghostMenu("File")
    ghostMenu("Edit")
    ghostMenu("Format")
    ghostMenu("View")
    ghostMenu("Help")
  else:
    menuActions()

## --- status bar ---------------------------------------------------------------------

proc drawStatus() =
  let t = activeTheme
  let c = editorCaret(editorId, document.text)
  let (lo, hi) = editorSel(editorId, document.text)
  let (ln, col) = lineCol(document.text, c)
  clay "status", row(width = grow(), height = fixedPx(26), gap = 24,
                     padding = padAll(4), alignY = centerY).bg(panelBg):
    var txt = "Ln " & $ln & ", Col " & $col
    if hi > lo:
      txt = txt & "  (" & $(hi - lo) & " selected)"
    text(txt, 13, t.palette.labelColor)
    spacer()
    text($zoomPct() & "%", 13, t.palette.labelColor)
    text($document.text.len & " characters", 13, t.palette.labelColor)
    text(eolTag(document.eol), 13, t.palette.labelColor)
    text(if wrapOn: "Word wrap: on" else: "Word wrap: off", 13,
      t.palette.labelColor)
    text("UTF-8", 13, t.palette.labelColor)

## --- the frame ------------------------------------------------------------------------

proc drawDoc() =
  let opts = EditorOpts(wrap: wrapOn, fontSize: zoomSize,
                        blocked: open())
  let st = editor(editorId, document.text, opts)
  if st.edited:
    noteEdited()
  document.text = st.text

proc update() {.raises.} =
  let mods = keyMods()
  updateUI(skipWheel = mods.ctrl)
  if mods.ctrl:
    let w = wheelDelta()
    if w.y > 0.0: zoomBy(2)
    elif w.y < 0.0: zoomBy(-2)
  appChords()

  layout:
    clay "app", col(width = grow(), height = grow(), gap = 0)
        .bg(bgColor):
      toolBar("bar", menuStrip)
      drawDoc()
      if statusOn:
        drawStatus()
      draw()

  if restore:
    restore = false
    if not open():
      editorRestoreFocus(editorId, document.text)
  syncTitle()

proc render() {.raises.} =
  drawCommands()

## --- screenshot mode -------------------------------------------------------------
##
## `SDL_VIDEODRIVER=offscreen DUCK_SHOT=out.bmp ./bin/duck` drives a fixed
## scripted interaction (type, select, open the find dialog), paints the
## final frame through the real renderer and saves a BMP for inspection.
## Same trick tests/render_shot.nim uses, but through the live app so the
## shot shows what the real menus/editor/dialogs actually compose to.

proc typeForShot(s: string) {.raises.} =
  var i = 0
  while i < s.len:
    var one = ""
    one.add s[i]
    pushKeyEvent KeyEvent(kind: kevText, text: one)
    inc i
  update()

proc saveShot(path: string) {.raises.} =
  ## The platform library's readback (clear, `drawCommands`, BMP save);
  ## black like the live app's clear color.
  discard saveScreenshot(path, bg = rgb(0, 0, 0))

proc shot(path: string) {.raises.} =
  let base =
    if path.endsWith(".bmp"): substr(path, 0, path.len - 5)
    else: path
  update()
  update()
  typeForShot("Duck quacks like Notepad: type, select, undo, find -- all on the ellipse_ui widget set.")
  update()
  update()
  saveShot(base & "-doc.bmp")
  # select a word the drag way? keep it deterministic: Ctrl+A then a word
  pushKeyEvent KeyEvent(kind: kevLetter, ch: 'a', ctrl: true)
  update()
  # find dialog over a lit selection
  pushKeyEvent KeyEvent(kind: kevLetter, ch: 'f', ctrl: true)
  update()
  pushKeyEvent KeyEvent(kind: kevText, text: "quack")
  update()
  update()
  saveShot(path)
  # Escape closes; Ctrl+O opens the file picker over the home directory
  pushKeyEvent KeyEvent(kind: kevEscape)
  update()
  pushKeyEvent KeyEvent(kind: kevLetter, ch: 'o', ctrl: true)
  update()
  update()
  saveShot(base & "-file.bmp")

when isMainModule:
  try:
    bootup()
    installKeyFilter(routeKeys)
    initLists()
    # an initial file rides on the command line like notepad's
    if paramStr(1).len > 0 and fileExists(paramStr(1)):
      discard openPath(paramStr(1))
    editorClearHistory()
    focusAt(editorId, document.text, 0)
    let shotPath = getEnv("DUCK_SHOT")
    if shotPath.len > 0:
      shot(shotPath)
    else:
      start(update, render)
  except ErrorCode:
    discard
