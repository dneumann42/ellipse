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
## Input reaches the app as widget events: the menu bar (`DuckMenus`)
## catches `MenuPicked`, the document (`DocArea`) the editor's
## `TextChanged`, and each dialog in `duck/session` the `Pressed` /
## `TextChanged` / `Toggled` / `Picked` of its controls. Only the raw
## keyboard chords (`appChords`) are read outside the widget tree.
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

proc editCut() =
  let (lo, hi) = editorSel(editorId, document.text)
  if hi > lo:
    editorCut(editorId, document.text)
    noteEdited()
  else:
    editorCopy(editorId, document.text)   # Notepad: Cut with no selection copies

proc editDelete() =
  let (lo, hi) = editorSel(editorId, document.text)
  if hi > lo:
    editorDelete(editorId, document.text)
    noteEdited()

proc editPaste() =
  let c = getClipboard()
  if c.len > 0:
    editorPaste(editorId, document.text)
    noteEdited()

widget DuckMenus():
  ## The menu bar. Every item reports through `MenuPicked`, which this
  ## widget catches and hands to the session/editor API. The acts that
  ## change the text mark the document dirty by hand: the editor widget's
  ## `TextChanged` only covers keystrokes and pointer edits it sees
  ## itself, while these run between its frames.
  event MenuPicked(e):
    case e.label
    of "New": beginNew()
    of "Open...": beginOpen()
    of "Save": quickSave()
    of "Save As...": beginSave()
    of "Exit": beginExit()
    of "Undo":
      if editorUndo(editorId, document.text): noteEdited()
    of "Redo":
      if editorRedo(editorId, document.text): noteEdited()
    of "Cut": editCut()
    of "Copy": editorCopy(editorId, document.text)
    of "Delete": editDelete()
    of "Paste": editPaste()
    of "Find...": beginFind()
    of "Find Next": doFind()
    of "Replace...": beginReplace()
    of "Go To...": beginGoto()
    of "Select All": editorSelectAll(editorId, document.text)
    of "Time/Date": doStamp()
    of "Word Wrap": wrapOn = not wrapOn
    of "Font...": beginFont()
    of "Zoom In": zoomBy(2)
    of "Zoom Out": zoomBy(-2)
    of "Restore Zoom": zoomSize = baseZoom
    of "Status Bar": statusOn = not statusOn
    of "View Help", "About Duck": beginAbout()
    else: discard
  menu("File") do():
    discard menuItem("New", "Ctrl+N")
    discard menuItem("Open...", "Ctrl+O")
    discard menuItem("Save", "Ctrl+S")
    discard menuItem("Save As...", "Ctrl+Shift+S")
    menuSeparator()
    discard menuItem("Exit", "Alt+F4")
  menu("Edit") do():
    discard menuItem("Undo", "Ctrl+Z")
    discard menuItem("Redo", "Ctrl+Y")
    menuSeparator()
    discard menuItem("Cut", "Ctrl+X")
    discard menuItem("Copy", "Ctrl+C")
    discard menuItem("Delete", "Del")
    discard menuItem("Paste", "Ctrl+V")
    menuSeparator()
    discard menuItem("Find...", "Ctrl+F")
    discard menuItem("Find Next", "F3")
    discard menuItem("Replace...", "Ctrl+H")
    menuSeparator()
    discard menuItem("Go To...", "Ctrl+G")
    discard menuItem("Select All", "Ctrl+A")
    discard menuItem("Time/Date", "F5")
  menu("Format") do():
    discard menuItem("Word Wrap", if wrapOn: "✓" else: "")
    discard menuItem("Font...", "")
  menu("View") do():
    discard menuItem("Zoom In", "Ctrl+Plus")
    discard menuItem("Zoom Out", "Ctrl+Minus")
    discard menuItem("Restore Zoom", "Ctrl+0")
    menuSeparator()
    discard menuItem("Status Bar", if statusOn: "✓" else: "")
  menu("Help") do():
    discard menuItem("View Help", "F1")
    discard menuItem("About Duck", "")

proc menuStrip() =
  if open():
    ghostMenu("File")
    ghostMenu("Edit")
    ghostMenu("Format")
    ghostMenu("View")
    ghostMenu("Help")
  else:
    DuckMenus()

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

widget DocArea():
  ## The document: the editor's `TextChanged` is the edit, so it both
  ## stores the text and marks the document dirty.
  event TextChanged(e):
    if e.id == editorId:
      document.text = e.text
      noteEdited()
  discard editor(editorId, document.text,
    EditorOpts(wrap: wrapOn, fontSize: zoomSize, blocked: open()))

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
      DocArea()
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
