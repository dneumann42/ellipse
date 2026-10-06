## Duck's modal session: the dialogs, the display preferences and the
## actions behind them.
##
## Notepad's dialogs -- Find, Replace, Go To, Font, the file Open/Save
## pickers, the "Save changes?" prompt and the about box -- are floating
## overlays built from the same widget set as the rest of the app. The
## session owns their state and their verbs; the main module draws the
## overlay (this module's `draw`) when `open()` is true and routes
## Enter/Escape through `primary` / `dismiss`.
##
## One dialog at a time (like the one dropdown the widget set allows):
## opening a second replaces the first, and `restore` tells the app when
## the document editor wants its keyboard back.

import std/[syncio, strutils, os]

import clay
import ellipse_ui/ui
import ellipse_ui/widgets

import ellipse/clock
import ellipse/platform/platform

import ./doc
import ./filelist
import ./search

type
  Kind* = enum kNone, kOpen, kSave, kFind, kReplace, kGoto, kFont, kAbout,
    kAsk, kInfo
  Ask* = enum askNone, askNew, askOpen, askSaveOver, askExit

var
  kind*: Kind = kNone
  fresh = false           ## a dialog just opened (auto-focus its field)
  restore* = false        ## the editor wants the keyboard back

  # display preferences (View / Format menus, the status bar reads them)
  wrapOn* = true
  statusOn* = true
  zoomSize*: uint16 = 18

  # search state
  editorId*: ElementId = elementId("duck.editor")
  query* = ""
  replText* = ""
  matchCase* = false
  findStatus* = ""

  # go to
  gotoText* = ""
  gotoStatus* = ""

  # font dialog
  fontFams: seq[string] = @[]
  fontSz: seq[string] = @[]
  famIdx* = 0
  szIdx* = 7      ## "18" -- the default size

  # ask / info
  askKind*: Ask = askNone
  askTitle* = ""
  askMsg* = ""
  askPath* = ""
  askReturn: Kind = kNone
  pendKind: Ask = askNone     ## "save first, then..." continuation
  pendPath = ""
  infoMsg* = ""

  # file dialog
  fdDir* = ""
  fdLoaded* = ""
  fdName* = ""
  fdError* = ""
  fdSel = -1
  fdEntries: seq[FEntry] = @[]

proc open*(): bool = kind != kNone

proc initLists*() =
  fontFams.add "Inter"
  let want = [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72]
  for w in want:
    fontSz.add $w

proc zoomPct*(): int =
  zoomSize.int * 100 div 18

proc fontPx*(): uint16 =
  if szIdx < 0 or szIdx >= fontSz.len:
    return 18.uint16
  var v = 18
  try:
    v = parseInt(fontSz[szIdx])
  except:
    v = 18
  v.uint16

## --- open / close -------------------------------------------------------------

proc show(k: Kind) =
  kind = k
  fresh = true

proc dismiss*() =
  if kind == kNone:
    return
  kind = kNone
  askKind = askNone
  askReturn = kNone
  pendKind = askNone
  pendPath = ""
  restore = true

## --- find / replace -------------------------------------------------------------

proc doFind*(backwards = false) =
  if query.len == 0 or document.text.len == 0:
    return
  let (lo, hi) = editorSel(editorId, document.text)
  let start = if backwards: lo else: hi
  let caseless = not matchCase
  let hit =
    if backwards: findBack(document.text, query, start, caseless, true)
    else: findFrom(document.text, query, start, caseless, true)
  if hit.found:
    editorSelect(editorId, document.text, hit.lo, hit.hi)
    findStatus = ""
  else:
    findStatus = "Cannot find \"" & query & "\""

proc doReplace*() =
  ## Replace the current selection when it equals the query, then find
  ## the next occurrence -- Notepad's Replace button, key for key.
  let (lo, hi) = editorSel(editorId, document.text)
  if hi > lo and matchesAt(document.text, lo, query, not matchCase):
    discard editorReplaceRange(editorId, document.text, lo, hi, replText)
    noteEdited()
  doFind()

proc doReplaceAll*() =
  if query.len == 0:
    return
  var outp = ""
  var n = 0
  replaceAll(document.text, query, replText, not matchCase, outp, n)
  if n > 0:
    editorSetAll(editorId, document.text, outp, 0)
    noteEdited()
  findStatus = $n & " replacement" & (if n == 1: "" else: "s") & " made"

## --- go to ---------------------------------------------------------------------

proc doGoto*() =
  var n = 0
  try:
    n = parseInt(gotoText)
  except:
    n = 0
  if n < 1:
    gotoStatus = "Enter a line number"
    return
  var line = 1
  var i = 0
  while i < document.text.len and line < n:
    if document.text[i] == '\n':
      inc line
    inc i
  editorPlaceCaret(editorId, document.text, i)
  gotoStatus = ""

## --- stamp ---------------------------------------------------------------------

func pad2(n: int): string =
  if n < 10: "0" & $n else: $n

proc stamp*(): string =
  ## The F5 time/date, in Notepad's shape: MM/DD/YYYY HH:MM. The broken-down
  ## wall clock itself comes from `ellipse/clock`.
  let t = clock.now()
  if t.year == 0:
    return ""
  result = pad2(t.month) & "/" & pad2(t.day) & "/" & $t.year & " " &
    pad2(t.hour) & ":" & pad2(t.minute)

proc doStamp*() =
  editorInsert(editorId, document.text, stamp())
  noteEdited()

## --- document swaps -------------------------------------------------------------

proc freshDoc() =
  ## A brand-new empty document: history and caret go with the old text.
  editorClearHistory()
  newDoc()
  editorPlaceCaret(editorId, document.text, 0)

proc loadNow*(path: string): bool =
  let res = openPath(path)
  editorClearHistory()
  editorPlaceCaret(editorId, document.text, 0)
  if not res.ok:
    infoMsg = res.msg
    askKind = askNone
    show(kInfo)
  res.ok

proc saveNow*(path: string): bool =
  let res = savePath(path)
  if not res.ok:
    infoMsg = res.msg
    askKind = askNone
    show(kInfo)
  res.ok

## --- file dialogs -----------------------------------------------------------------

proc refreshList*() =
  fdLoaded = fdDir
  fdEntries = listDir(fdDir)
  fdSel = -1

proc startDir(): string =
  if document.path.len > 0:
    let d = dirOf(document.path)
    if d.len > 0:
      return d
  if fdDir.len > 0:
    return fdDir
  homeString()

proc beginOpen*() =
  fdDir = startDir()
  refreshList()
  fdName = nameOf(document.path)
  if fdName == "Untitled":
    fdName = ""
  fdError = ""
  show(kOpen)

proc beginSave*() =
  fdDir = startDir()
  refreshList()
  fdName = nameOf(document.path)
  if fdName == "Untitled":
    fdName = ""
  fdError = ""
  show(kSave)

proc quickSave*() =
  if document.path.len == 0:
    beginSave()
  else:
    discard saveNow(document.path)

proc finalizeAfterSave() =
  ## The save dialog closed with a written file: run whatever the "save
  ## changes first?" answer had queued -- new, open, or exit -- then
  ## close. dismiss() clears the queue, so grab it first.
  let follow = pendKind
  let target = pendPath
  dismiss()
  case follow
  of askNew:
    freshDoc()
  of askOpen:
    discard loadNow(target)
  of askExit:
    quit()
  of askSaveOver, askNone:
    discard

proc fdConfirm(i: int) =
  ## The dirty-file prompt in front of the picker: Yes loads anyway (the
  ## Yes handler also saves first when chosen so from the Open path --
  ## here the answer arrives through `askReturn`/askOpen).
  askKind = askOpen
  askTitle = "Open"
  askMsg = "Do you want to save changes to " & nameOf(document.path) &
    " before opening " & fdEntries[i].name & "?"
  askPath = joinDir(fdDir, fdEntries[i].name)
  askReturn = kOpen
  show(kAsk)

proc fdActivate(i: int) =
  if i < 0 or i >= fdEntries.len:
    return
  let e = fdEntries[i]
  let path = joinDir(fdDir, e.name)
  if e.isDir:
    fdDir = path
    refreshList()
    return
  if kind == kOpen:
    fdName = e.name
    if document.dirty:
      fdConfirm(i)
    else:
      if loadNow(path):
        dismiss()
  else:
    fdName = e.name
    if fileExists(path):
      askKind = askSaveOver
      askTitle = "Save As"
      askMsg = "Replace " & e.name & " with the existing file?"
      askPath = path
      askReturn = kSave
      show(kAsk)

proc fdAccept*() =
  if fdName.len == 0:
    fdError = "Enter a file name"
    return
  let path = joinDir(fdDir, fdName)
  if kind == kOpen:
    if dirExists(path):
      fdDir = path
      refreshList()
      return
    if not fileExists(path):
      fdError = "Cannot find \"" & fdName & "\""
      return
    if document.dirty:
      askKind = askOpen
      askTitle = "Open"
      askMsg = "Do you want to save changes to " & nameOf(document.path) &
        " before opening " & fdName & "?"
      askPath = path
      askReturn = kOpen
      show(kAsk)
    else:
      if loadNow(path):
        dismiss()
  else:
    if dirExists(path):
      fdDir = path
      refreshList()
      return
    if fileExists(path):
      askKind = askSaveOver
      askTitle = "Save As"
      askMsg = "Replace " & fdName & " with the existing file?"
      askPath = path
      askReturn = kSave
      show(kAsk)
    else:
      if saveNow(path):
        finalizeAfterSave()

## --- document-level asks -------------------------------------------------------------

proc beginNew*() =
  if document.dirty:
    askKind = askNew
    askTitle = "New"
    askMsg = "Do you want to save changes to " & nameOf(document.path) &
      " before creating a new file?"
    askPath = ""
    askReturn = kNone
    show(kAsk)
  else:
    freshDoc()
    restore = true

proc beginExit*() =
  if document.dirty:
    askKind = askExit
    askTitle = "Quit"
    askMsg = "Do you want to save changes to " & nameOf(document.path) & "?"
    askPath = ""
    askReturn = kNone
    show(kAsk)
  else:
    quit()

proc askBack*() =
  ## No / Cancel on the overwrite & open confirmations: go back to the
  ## picker the question interrupted. For the New / Exit asks there is
  ## nothing underneath -- just close.
  if askReturn != kNone:
    kind = askReturn
    askKind = askNone
    fresh = true
  else:
    dismiss()

proc doAskYes*() =
  case askKind
  of askNew:
    if document.path.len == 0:
      # Untitled & dirty: "Yes" has to ask where to save -- the New
      # resumes through the save dialog's finalize step.
      askKind = askNone
      pendKind = askNew
      pendPath = ""
      beginSave()
      return
    if saveNow(document.path):
      freshDoc()
      dismiss()
  of askOpen:
    if document.path.len == 0:
      askKind = askNone
      pendKind = askOpen
      pendPath = askPath
      beginSave()
      return
    if saveNow(document.path):
      if loadNow(askPath):
        dismiss()
  of askSaveOver:
    if saveNow(askPath):
      dismiss()
  of askExit:
    if document.path.len == 0:
      askKind = askNone
      pendKind = askExit
      pendPath = ""
      beginSave()
      return
    if saveNow(document.path):
      quit()
  of askNone:
    discard

proc doAskNo*() =
  case askKind
  of askNew:
    freshDoc()
    dismiss()
  of askExit:
    quit()
  of askOpen:
    if loadNow(askPath):
      dismiss()
  of askSaveOver:
    askBack()
  of askNone:
    discard

## --- the dialog's Enter key ------------------------------------------------------------

proc primary*() =
  case kind
  of kFind: doFind()
  of kReplace:
    # Enter in "Replace with" replaces; anywhere else it finds next.
    if focusIdOf() == hashId("s.repl").id:
      doReplace()
    else:
      doFind()
  of kGoto: doGoto()
  of kFont:
    zoomSize = fontPx()
    dismiss()
  of kAbout, kInfo:
    dismiss()
  of kAsk: doAskYes()
  of kOpen, kSave: fdAccept()
  of kNone: discard

## --- begin each dialog (menus & chords) -------------------------------------------------

proc beginFind*() =
  findStatus = ""
  show(kFind)

proc beginReplace*() =
  findStatus = ""
  show(kReplace)

proc beginGoto*() =
  gotoStatus = ""
  gotoText = ""
  show(kGoto)

proc beginFont*() =
  # line the combo up with the live zoom
  var want = $(zoomSize.int)
  var idx = 7
  var i = 0
  while i < fontSz.len:
    if fontSz[i] == want:
      idx = i
      break
    inc i
  szIdx = idx
  show(kFont)

proc beginAbout*() =
  show(kAbout)

## --- drawing ---------------------------------------------------------------------------

proc fieldRow(id: ElementId, labelText, value: string): string =
  ## One dialog form row: right-labelled text field; returns the edited
  ## value (the immediate-mode round trip on `value`). Auto-id brackets
  ## (`container`), because a dialog declares several of these in one
  ## parent -- fixed labels would collide.
  let t = activeTheme
  var outp = value
  container(row(width = grow(), height = fit(),
                gap = t.metrics.gapProse, alignY = centerY)):
    container(col(width = fixedPx(110), height = fit(), alignX = right,
                  alignY = centerY)):
      text(labelText, t.text.label, t.palette.labelColor)
    outp = textField(id, value, "")
  result = outp

proc footerButton(id: ElementId, label: string, width = 120.0'f32): bool =
  button(id, label, width = fixedPx(width), height = fixedPx(38),
    fontSize = activeTheme.text.control)

proc drawFind(replacing: bool) =
  let t = activeTheme
  label(if replacing: "Find and Replace" else: "Find")
  query = fieldRow(hashId("s.query"), "Find what:", query)
  if replacing:
    replText = fieldRow(hashId("s.repl"), "Replace with:", replText)
  clay "fopts", row(width = grow(), height = fit(), gap = 24,
                    alignY = centerY):
    matchCase = checkbox(hashId("s.case"), "Match case", matchCase)
    if findStatus.len > 0:
      clay "fst", row(width = grow(), height = fit(), alignY = centerY):
        caption(findStatus)
  clay "fbtns", row(width = grow(), height = fit(), gap = 10,
                    alignY = centerY):
    spacer()
    if footerButton(hashId("s.next"), "Find Next"):
      doFind()
    if replacing:
      if footerButton(hashId("s.replb"), "Replace"):
        doReplace()
      if footerButton(hashId("s.allb"), "Replace All"):
        doReplaceAll()
    if footerButton(hashId("s.cancel"), "Cancel"):
      dismiss()

proc drawGoto() =
  label("Go To Line")
  gotoText = fieldRow(hashId("s.goto"), "Line number:", gotoText)
  if gotoStatus.len > 0:
    caption(gotoStatus)
  clay "gbtns", row(width = grow(), height = fit(), gap = 10,
                    alignY = centerY):
    spacer()
    if footerButton(hashId("s.gotob"), "Go To"):
      doGoto()
    if footerButton(hashId("s.goc"), "Cancel"):
      dismiss()

proc drawFont() =
  label("Choose Font")
  clay "frow1", row(width = grow(), height = fit(), gap = 10,
                    alignY = centerY):
    famIdx = comboBox(hashId("s.fam"), fontFams, famIdx, "Family")
    szIdx = comboBox(hashId("s.sz"), fontSz, szIdx, "Size")
  clay "fprev", col(width = grow(), height = fixedPx(76), gap = 4,
      padding = padAll(10), alignY = centerY)
      .bg(fieldBg).border(hairline, panelBorder).corner(panelRadius):
    bodyText("The quick brown fox jumps over the lazy dog", fontPx())
  clay "fbtns2", row(width = grow(), height = fit(), gap = 10,
                     alignY = centerY):
    spacer()
    if footerButton(hashId("s.fok"), "OK"):
      zoomSize = fontPx()
      dismiss()
    if footerButton(hashId("s.fc"), "Cancel"):
      dismiss()

proc drawAbout() =
  heading("Duck", 3)
  bodyText("A Notepad clone built on ellipse_ui: clay layout, the standard widget set, SDL3. Every menu item, chord and dialog here really works -- find, replace, wrap, zoom, undo, the file pickers.")
  caption("Documents keep the line endings they came in with; new files write CRLF like the original.")
  clay "abtns", row(width = grow(), height = fit(), alignX = right,
                    alignY = centerY):
    if footerButton(hashId("s.aboutok"), "OK"):
      dismiss()

proc drawAsk() =
  label(askMsg)
  clay "abtns2", row(width = grow(), height = fit(), gap = 10,
                     alignY = centerY):
    spacer()
    if footerButton(hashId("s.askyes"), "Yes", 90):
      doAskYes()
    if footerButton(hashId("s.askno"), "No", 90):
      doAskNo()
    if footerButton(hashId("s.askcancel"), "Cancel", 90):
      askBack()

proc drawInfo() =
  label(infoMsg)
  clay "ibtns", row(width = grow(), height = fit(), alignX = right,
                    alignY = centerY):
    if footerButton(hashId("s.iok"), "OK"):
      dismiss()

proc drawFile(isOpen: bool) =
  label(if isOpen: "Open" else: "Save As")
  let editedDir = fieldRow(hashId("s.dir"), "Directory:", fdDir)
  if editedDir != fdDir:
    fdDir = editedDir
  if fdDir != fdLoaded:
    refreshList()
  fdName = fieldRow(hashId("s.name"), "File name:", fdName)
  if fdError.len > 0:
    caption(fdError)
  scrollPanel "fd.list", col(width = grow(), height = fixedPx(200), gap = 2,
      padding = padAll(4))
      .bg(fieldBg).border(hairline, panelBorder).corner(panelRadius)
      .clip(horizontal = false, vertical = true,
            childOffset = currentScrollOffset()):
    if not isRoot(fdDir):
      item("fd.up", 0, optionRowDecl(hovered(), false, pressing())):
        text("..", activeTheme.text.option)
      if clickedIn(localIdWithIndex("fd.up", 0'u32)):
        fdDir = parentOf(fdDir)
        refreshList()
    var i = 0
    while i < fdEntries.len:
      let e = fdEntries[i]
      item("fd.row", i, optionRowDecl(hovered(), i == fdSel, pressing())):
        text((if e.isDir: "[ ]  " else: "     ") & e.name,
             activeTheme.text.option)
      if clickedIn(localIdWithIndex("fd.row", uint32(i))):
        fdSel = i
        if isOpen:
          fdName = e.name
        if doubleClick():
          fdActivate(i)
      inc i
  clay "fdbtns", row(width = grow(), height = fit(), gap = 10,
                     alignY = centerY):
    spacer()
    if footerButton(hashId("s.fdok"), if isOpen: "Open" else: "Save", 110):
      fdAccept()
    if footerButton(hashId("s.fdc"), "Cancel"):
      dismiss()

proc draw*() =
  ## The modal overlay: a floating panel centred across the window, with
  ## a click-anywhere-else dismiss. Draw after everything else so its
  ## floating boxes sit on top (zIndex 30000 -- above scrollbars and
  ## menus, below dialog-field carets and dropdowns that live inside it).
  if kind == kNone:
    return
  let t = activeTheme
  let backId = elementId("modal.back")
  let centerId = elementId("modal.center")
  let panelId = elementId("modal.panel")
  openElement(backId)
  configureOpenElement(row(width = grow(), height = grow())
    .bg(rgb(0, 0, 0, 90))
    .floating(attachRoot, zIndex = 30000,
              points = AttachPoints(element: pointLeftTop,
                                    parent: pointLeftTop)))
  if clickedIn(backId) and not pointerOver(panelId):
    if kind == kAsk:
      askBack()
    else:
      dismiss()
  openElement(centerId)
  configureOpenElement(row(width = grow(), height = grow(),
    alignX = centerX, alignY = centerY))
  openElement(panelId)
  var mw = 360.0'f32
  if kind == kOpen or kind == kSave:
    mw = 560.0'f32
  elif kind == kFind or kind == kReplace:
    mw = 430.0'f32
  elif kind == kFont:
    mw = 380.0'f32
  configureOpenElement(col(width = fit(max = mw), height = fit(),
    gap = t.metrics.gapTight,
    padding = padAll(t.metrics.padPanel), alignX = left)
    .bg(panelBg)
    .border(hairline, panelBorder)
    .corner(panelRadius))
  case kind
  of kFind: drawFind(false)
  of kReplace: drawFind(true)
  of kGoto: drawGoto()
  of kFont: drawFont()
  of kAbout: drawAbout()
  of kAsk: drawAsk()
  of kInfo: drawInfo()
  of kOpen: drawFile(true)
  of kSave: drawFile(false)
  of kNone: discard
  if fresh:
    fresh = false
    # Notepad drops the caret in the first field on opening.
    if kind == kFind or kind == kReplace:
      focusAt(hashId("s.query"), query, query.len)
    elif kind == kGoto:
      focusAt(hashId("s.goto"), gotoText, gotoText.len)
    elif kind == kOpen or kind == kSave:
      focusAt(hashId("s.name"), fdName, fdName.len)
  closeElement()   # panel
  closeElement()   # center
  closeElement()   # backdrop
