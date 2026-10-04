## Tests for the theming system (ellipse_ui/theme).
##
## Widgets resolve every token against `activeTheme` while they render, so
## these tests check the *rendered* rectangles: push a theme (or mutate
## `activeTheme` / wrap a call in `withTheme`), draw one frame, and look
## for the theme's colour among the commands clay produced.

import std/syncio

import clay
import ellipse/platform/platform
import ellipse_ui/ui
import ellipse_ui/widgets

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

proc mono(text: string; cfg: TextConfig): Size =
  Size(width: float32(text.len) * float32(cfg.fontSize), height: float32(cfg.fontSize))

let btnId = hashId("theme.btn")
let rootId = hashId("theme.root")

proc fillCount(color: Color): int =
  ## How many rectangle commands this frame painted with `color`.
  result = 0
  let cmds = renderCommands()
  for cmd in cmds:
    if cmd.kind == renderRectangle and cmd.fill == color:
      inc result

proc frame() =
  beginLayout()
  clay "theme.root", col(width = grow(), height = grow(), gap = 8,
                          padding = padAll(16)):
    discard button(btnId, "Go")
  endLayout()

proc main() {.raises.} =
  setCurrentContext(initContext(size(800.0, 600.0)))
  setMeasureText(mono)
  setPointerState(vec2(-100.0, -100.0), false)
  frame()
  expect(elementData(rootId).found, "theme: frame lays out")

  # --- defaults ------------------------------------------------------------------
  expect(defaultTheme().palette.accent == rgb(96, 130, 220),
    "theme: default accent is the original blue")
  expect(activeTheme.palette.buttonBg == rgb(52, 56, 72),
    "theme: live theme starts at the default palette")
  # the button's bg + its hover-free idle state paints one buttonBg rect
  expect(fillCount(buttonBg) >= 1, "theme: button paints the default bg")

  # --- mutate the live theme: applies to the next widget, every frame ------------
  let danger = rgb(200, 40, 40)
  activeTheme.palette.buttonBg = danger
  frame()
  expect(fillCount(danger) >= 1, "theme: mutated colour reaches the next frame")
  expect(fillCount(rgb(52, 56, 72)) == 0, "theme: old colour gone after mutation")
  activeTheme = defaultTheme()

  # --- pushTheme / popTheme: snapshot, customise a region, restore ----------------
  var pushed = defaultTheme()
  pushed.palette.buttonBg = danger
  pushed.radii.button = 0.0
  pushTheme(pushed)
  frame()
  var squareDanger = 0
  let cmds = renderCommands()
  for cmd in cmds:
    if cmd.kind == renderRectangle and cmd.fill == danger and
        cmd.rectCorner.topLeft == 0.0:
      inc squareDanger
  expect(squareDanger >= 1,
    "theme: pushTheme swaps palette and metrics together")
  popTheme()
  expect(activeTheme.radii.button == 8.0, "theme: popTheme restores the snapshot")

  # push-without-argument then mutate, restore at pop
  pushTheme()
  activeTheme.palette.buttonBg = danger
  frame()
  expect(fillCount(danger) >= 1, "theme: pushed snapshot lets you mutate freely")
  popTheme()
  frame()
  expect(fillCount(danger) == 0, "theme: popTheme undoes the pushed mutation")

  # --- withTheme: one block, one effect --------------------------------------------
  frame()   # settle with the restored theme
  let before = fillCount(rgb(52, 56, 72))
  withTheme:
    activeTheme.palette.buttonBg = danger
    frame()  # every widget declared inside sees the patched theme
  expect(fillCount(danger) >= 1, "theme: withTheme styles the widgets in its body")
  frame()
  expect(fillCount(rgb(52, 56, 72)) == before,
    "theme: after withTheme the live theme is unchanged")

  # --- setTheme swaps wholesale; defaultTheme() resets ------------------------------
  var light = defaultTheme()
  light.palette.bg = rgb(245, 245, 245)
  light.palette.textColor = rgb(20, 20, 20)
  setTheme(light)
  expect(bgColor == rgb(245, 245, 245), "theme: setTheme installs the new look")
  setTheme(defaultTheme())
  expect(bgColor == rgb(12, 12, 16), "theme: defaultTheme() resets")

  # --- token plumbing: widget text sizes follow the scale ---------------------------
  setTheme(defaultTheme())
  frame()
  var sawButtonFont = false
  let cmds1 = renderCommands()
  for cmd in cmds1:
    if cmd.kind == renderText and cmd.fontSize == activeTheme.text.button:
      sawButtonFont = true
  expect(sawButtonFont, "theme: button text uses the type-scale token")
  activeTheme.text.button = 12
  frame()
  var sawSmallFont = false
  let cmds2 = renderCommands()
  for cmd in cmds2:
    if cmd.kind == renderText and cmd.fontSize == 12:
      sawSmallFont = true
  expect(sawSmallFont, "theme: type-scale change reaches the next frame")
  setTheme(defaultTheme())

  expect(takeErrors().len == 0, "theme: no clay errors after the session")

  echo "theme_test: ", passed, " passed, ", failures, " failed"
  if failures > 0:
    quit 1

when isMainModule:
  try:
    main()
  except ErrorCode:
    echo "theme_test aborted by ErrorCode"
    quit 1
