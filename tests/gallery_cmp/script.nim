## The interaction script both galleries run for the parity test (included
## by the Nim and the owl driver): clicks by element id or by visible text,
## typed keys, and a screenshot after each step.

var shotDir* = ""
var shotNames*: seq[string] = @[]

proc settle(n = 4) {.raises.} =
  for i in 0 ..< n:
    frame()

proc clickAt(x, y: float32) {.raises.} =
  setPointer(x, y, false)
  settle(2)
  setPointer(x, y, true)
  settle(2)
  setPointer(x, y, false)
  settle(3)

proc clickId(label: string) {.raises.} =
  let d = elementData(elementId(label))
  if not d.found:
    echo "no element ", label
    return
  clickAt(d.box.x + d.box.width / 2, d.box.y + d.box.height / 2)

proc clickText(label: string; nth = 0) {.raises.} =
  var seen = 0
  let cmds = renderCommands()
  for cmd in cmds:
    if cmd.kind == renderText and lineText(cmd) == label:
      if seen == nth:
        clickAt(cmd.box.x + cmd.box.width / 2, cmd.box.y + cmd.box.height / 2)
        return
      inc seen
  echo "no text ", label

proc key(kind: KeyEventKind) {.raises.} =
  pushKeyEvent(KeyEvent(kind: kind))
  settle(3)

proc typeText(s: string) {.raises.} =
  for c in s:
    var one = ""
    one.add c
    pushKeyEvent(KeyEvent(kind: kevText, text: one))
    settle(1)
  settle(3)

proc shot(name: string) {.raises.} =
  settle(3)
  setPointer(-1000.0, -1000.0, false)
  settle(3)
  shotNames.add name
  discard saveScreenshot(shotDir & "/" & name & ".bmp", bg = activeTheme.palette.bg)

proc sequence*() {.raises.} =
  settle(6)
  shot("00-start")
  clickId("combo-theme")
  shot("01-theme-open")
  clickText("Light")
  shot("02-light")
  clickId("cb-vsync")
  clickId("sw-wifi")
  clickId("btn-inc")
  clickId("btn-inc")
  shot("03-toggled")
  clickId("multi-modules")
  clickText("Networking")
  key(kevEscape)
  shot("04-multiselect")
  clickText("Session")
  shot("05-tab-session")
  clickText("Actions")
  shot("06-tab-actions")
  clickText("Reset all")
  shot("07-reset")
  clickText("View")
  shot("08-view-menu")
  clickText("Large count")
  shot("09-large-count")
  clickId("btn-member")
  shot("10-member-open")
  clickId("gallery.member.name")
  typeText("Grace Hopper")
  clickText("Add member")
  shot("11-member-errors")
  clickId("gallery.member.email")
  typeText("grace@example.com")
  clickId("gallery.member.team")
  clickText("Widgets")
  # the agree box is below the form's fold: Tab to it from the bio
  clickId("gallery.member.bio")
  key(kevTab)
  key(kevTab)
  typeText(" ")
  shot("12-member-filled")
  clickText("Add member")
  shot("13-member-added")
  if anyDialogOpen():
    key(kevEscape)
  clickId("pop-confirm")
  shot("14-confirm")
  clickText("Delete")
  shot("15-confirmed")
  clickId("pop-prompt")
  typeText(" stuff")
  key(kevEnter)
  shot("16-prompted")
  clickId("lnk-intro")
  shot("17-no-intro")
