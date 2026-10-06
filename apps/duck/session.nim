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

# the dialogs' controls, by id: their events are told apart by these
let
  queryId = hashId("s.query")
  replId = hashId("s.repl")
  caseId = hashId("s.case")
  nextId = hashId("s.next")
  replBtnId = hashId("s.replb")
  allId = hashId("s.allb")
  findCancelId = hashId("s.cancel")
  gotoId = hashId("s.goto")
  gotoBtnId = hashId("s.gotob")
  gotoCancelId = hashId("s.goc")
  famId = hashId("s.fam")
  szId = hashId("s.sz")
  fontOkId = hashId("s.fok")
  fontCancelId = hashId("s.fc")
  aboutOkId = hashId("s.aboutok")
  askYesId = hashId("s.askyes")
  askNoId = hashId("s.askno")
  askCancelId = hashId("s.askcancel")
  infoOkId = hashId("s.iok")
  dirId = hashId("s.dir")
  nameId = hashId("s.name")
  fdOkId = hashId("s.fdok")
  fdCancelId = hashId("s.fdc")

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
    if focusIdOf() == replId.id:
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
##
## Each dialog is a widget that catches what its controls emit: buttons
## `Pressed`, fields `TextChanged`, the checkbox `Toggled`, the font combos
## `Picked`, the file list's rows `RowPressed`. The controls draw from the
## session state and the handlers write it back -- synchronously, so a
## handler's change shows in the rest of the same frame.

proc fieldRow(id: ElementId, labelText, value: string) =
  ## One dialog form row: a right-labelled text field. Its edits arrive
  ## as `TextChanged` at the dialog. Auto-id brackets (`container`),
  ## because a dialog declares several of these in one parent -- fixed
  ## labels would collide.
  let t = activeTheme
  container(row(width = grow(), height = fit(),
                gap = t.metrics.gapProse, alignY = centerY)):
    container(col(width = fixedPx(110), height = fit(), alignX = right,
                  alignY = centerY)):
      text(labelText, t.text.label, t.palette.labelColor)
    discard textField(id, value, "")

proc footerButton(id: ElementId, label: string, width = 120.0'f32) =
  ## A dialog footer button; the press arrives as `Pressed` at the dialog.
  discard button(id, label, width = fixedPx(width), height = fixedPx(38),
    fontSize = activeTheme.text.control)

widget FindDialog(replacing: bool):
  event Pressed(e):
    if e.id == nextId: doFind()
    elif e.id == replBtnId: doReplace()
    elif e.id == allId: doReplaceAll()
    elif e.id == findCancelId: dismiss()
  event TextChanged(e):
    if e.id == queryId: query = e.text
    elif e.id == replId: replText = e.text
  event Toggled(e):
    if e.id == caseId: matchCase = e.on
  label(if replacing: "Find and Replace" else: "Find")
  fieldRow(queryId, "Find what:", query)
  if replacing:
    fieldRow(replId, "Replace with:", replText)
  clay "fopts", row(width = grow(), height = fit(), gap = 24,
                    alignY = centerY):
    discard checkbox(caseId, "Match case", matchCase)
    if findStatus.len > 0:
      clay "fst", row(width = grow(), height = fit(), alignY = centerY):
        caption(findStatus)
  clay "fbtns", row(width = grow(), height = fit(), gap = 10,
                    alignY = centerY):
    spacer()
    footerButton(nextId, "Find Next")
    if replacing:
      footerButton(replBtnId, "Replace")
      footerButton(allId, "Replace All")
    footerButton(findCancelId, "Cancel")

widget GotoDialog():
  event Pressed(e):
    if e.id == gotoBtnId: doGoto()
    elif e.id == gotoCancelId: dismiss()
  event TextChanged(e):
    if e.id == gotoId: gotoText = e.text
  label("Go To Line")
  fieldRow(gotoId, "Line number:", gotoText)
  if gotoStatus.len > 0:
    caption(gotoStatus)
  clay "gbtns", row(width = grow(), height = fit(), gap = 10,
                    alignY = centerY):
    spacer()
    footerButton(gotoBtnId, "Go To")
    footerButton(gotoCancelId, "Cancel")

widget FontDialog():
  event Picked(e):
    if e.id == famId: famIdx = e.index
    elif e.id == szId: szIdx = e.index
  event Pressed(e):
    if e.id == fontOkId:
      zoomSize = fontPx()
      dismiss()
    elif e.id == fontCancelId:
      dismiss()
  label("Choose Font")
  clay "frow1", row(width = grow(), height = fit(), gap = 10,
                    alignY = centerY):
    discard comboBox(famId, fontFams, famIdx, "Family")
    discard comboBox(szId, fontSz, szIdx, "Size")
  clay "fprev", col(width = grow(), height = fixedPx(76), gap = 4,
      padding = padAll(10), alignY = centerY)
      .bg(fieldBg).border(hairline, panelBorder).corner(panelRadius):
    bodyText("The quick brown fox jumps over the lazy dog", fontPx())
  clay "fbtns2", row(width = grow(), height = fit(), gap = 10,
                     alignY = centerY):
    spacer()
    footerButton(fontOkId, "OK")
    footerButton(fontCancelId, "Cancel")

widget AboutDialog():
  event Pressed(e):
    if e.id == aboutOkId: dismiss()
  heading("Duck", 3)
  bodyText("A Notepad clone built on ellipse_ui: clay layout, the standard widget set, SDL3. Every menu item, chord and dialog here really works -- find, replace, wrap, zoom, undo, the file pickers.")
  caption("Documents keep the line endings they came in with; new files write CRLF like the original.")
  clay "abtns", row(width = grow(), height = fit(), alignX = right,
                    alignY = centerY):
    footerButton(aboutOkId, "OK")

widget AskDialog():
  event Pressed(e):
    if e.id == askYesId: doAskYes()
    elif e.id == askNoId: doAskNo()
    elif e.id == askCancelId: askBack()
  label(askMsg)
  clay "abtns2", row(width = grow(), height = fit(), gap = 10,
                     alignY = centerY):
    spacer()
    footerButton(askYesId, "Yes", 90)
    footerButton(askNoId, "No", 90)
    footerButton(askCancelId, "Cancel", 90)

widget InfoDialog():
  event Pressed(e):
    if e.id == infoOkId: dismiss()
  label(infoMsg)
  clay "ibtns", row(width = grow(), height = fit(), alignX = right,
                    alignY = centerY):
    footerButton(infoOkId, "OK")

widget FileRow(index: int, caption: string, selected: bool):
  ## One row of the file list -- `index` -1 is the ".." row. A click
  ## emits `RowPressed` (with whether it completed a double click).
  emits RowPressed(index: int, double: bool)
  let rowId =
    if index < 0: localIdWithIndex("fd.up", 0'u32)
    else: localIdWithIndex("fd.row", uint32(index))
  item(rowId, optionRowDecl(hovered(), selected, pressing())):
    text(caption, activeTheme.text.option)
  if clickedIn(rowId):
    emit RowPressed(index: index, double: doubleClick())

widget FileDialog(isOpen: bool):
  event TextChanged(e):
    if e.id == dirId: fdDir = e.text
    elif e.id == nameId: fdName = e.text
  event RowPressed(e):
    if e.index < 0:
      fdDir = parentOf(fdDir)
      refreshList()
    elif e.index < fdEntries.len:
      fdSel = e.index
      if isOpen:
        fdName = fdEntries[e.index].name
      if e.double:
        fdActivate(e.index)
  event Pressed(e):
    if e.id == fdOkId: fdAccept()
    elif e.id == fdCancelId: dismiss()
  label(if isOpen: "Open" else: "Save As")
  fieldRow(dirId, "Directory:", fdDir)
  if fdDir != fdLoaded:
    refreshList()
  fieldRow(nameId, "File name:", fdName)
  if fdError.len > 0:
    caption(fdError)
  scrollPanel "fd.list", col(width = grow(), height = fixedPx(200), gap = 2,
      padding = padAll(4))
      .bg(fieldBg).border(hairline, panelBorder).corner(panelRadius)
      .clip(horizontal = false, vertical = true,
            childOffset = currentScrollOffset()):
    if not isRoot(fdDir):
      FileRow(index = -1, caption = "..", selected = false)
    var i = 0
    while i < fdEntries.len:
      let e = fdEntries[i]
      FileRow(index = i,
              caption = (if e.isDir: "[ ]  " else: "     ") & e.name,
              selected = i == fdSel)
      inc i
  clay "fdbtns", row(width = grow(), height = fit(), gap = 10,
                     alignY = centerY):
    spacer()
    footerButton(fdOkId, if isOpen: "Open" else: "Save", 110)
    footerButton(fdCancelId, "Cancel")

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
  of kFind: FindDialog(replacing = false)
  of kReplace: FindDialog(replacing = true)
  of kGoto: GotoDialog()
  of kFont: FontDialog()
  of kAbout: AboutDialog()
  of kAsk: AskDialog()
  of kInfo: InfoDialog()
  of kOpen: FileDialog(isOpen = true)
  of kSave: FileDialog(isOpen = false)
  of kNone: discard
  if fresh:
    fresh = false
    # Notepad drops the caret in the first field on opening.
    if kind == kFind or kind == kReplace:
      focusAt(queryId, query, query.len)
    elif kind == kGoto:
      focusAt(gotoId, gotoText, gotoText.len)
    elif kind == kOpen or kind == kSave:
      focusAt(nameId, fdName, fdName.len)
  closeElement()   # panel
  closeElement()   # center
  closeElement()   # backdrop
