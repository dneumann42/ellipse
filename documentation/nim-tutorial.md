# Writing GUIs in Nim (Nimony)

This is the complete tutorial for the ellipse graphical toolkit in Nim. It
assumes only that you can build the project (`make setup`) and run a binary.
Every feature the toolkit ships is covered; [reference-widgets.md](reference-widgets.md)
has the one-line signatures if you already know the shape of things.

Import the whole kit with either:

```nim
import ellipse        # clock, hotload and the GUI app
import ellipse_ui/app # just the GUI app
```

`ellipse_ui/app` re-exports clay (layout), the platform and renderer, the
logger, the core `ui` module, the widget set and the dialogs. Import it and you
have everything below.

- [1. The mental model](#1-the-mental-model)
- [2. A window and a view](#2-a-window-and-a-view)
- [3. Layout with clay](#3-layout-with-clay)
- [4. Elements, ids and items](#4-elements-ids-and-items)
- [5. Interaction primitives](#5-interaction-primitives)
- [6. The widget set](#6-the-widget-set)
- [7. Focus and the keyboard](#7-focus-and-the-keyboard)
- [8. Keymaps and shortcuts](#8-keymaps-and-shortcuts)
- [9. Events](#9-events)
- [10. The theme](#10-the-theme)
- [11. Cadence, animation and the frame loop](#11-cadence-animation-and-the-frame-loop)
- [12. The app shell and its hooks](#12-the-app-shell-and-its-hooks)
- [13. Dialogs](#13-dialogs)
- [14. Hot reloading](#14-hot-reloading)
- [15. A full walkthrough](#15-a-full-walkthrough)

---

## 1. The mental model

A frame re-runs your view function from top to bottom. Each call declares a
rectangle and its children in the layout engine (clay), and reads the engine's
pointer, scroll and focus state for that frame. What changes between frames is
ordinary Nim state that *you* own.

Two rules follow from that and they explain almost everything:

1. **Input widgets are a round trip.** Pass the value in, assign the return
   back:

   ```nim
   checked = checkbox(hashId("wifi"), "Wifi", checked)
   name    = textField(hashId("name"), name, "Your name")
   volume  = numberField(hashId("vol"), volume, 0.05, 0.0, 1.0)
   ```

2. **Transient view state lives in the toolkit, keyed by element id.** Which
   dropdown is open, which field holds the caret, which tab is selected, where
   the scrollbars sit -- all of that is remembered per id between frames so you
   do not have to model it.

Layout is immediate too: a widget's box is computed from its content and its
parent, every frame. You guide it with sizing (`grow`, `fit`, `fixedPx`,
`pct`) rather than with coordinates.

---

## 2. A window and a view

```nim
import ellipse_ui/app

var count = 0

proc view() {.raises.} =
  clay "root", col(width = grow(), height = grow(), padding = padAll(24),
                   gap = 8, alignX = centerX):
    text("Clicked " & $count & " times", 32)
    if button(hashId("inc"), "Increment"):
      inc count

when isMainModule:
  run App(window: WindowConfig(title: "Counter"), view: view)
```

- `App` holds the window config and the frame hooks (see
  [section 12](#12-the-app-shell-and-its-hooks)).
- `WindowConfig(title: "Counter")` opens a window; add `width`/`height` for a
  fixed size.
- `run` opens the window and runs the paced frame loop until it closes.
- `view` is a `proc () {.closure, raises.}` that declares the tree.

The frame loop only runs frames somebody asked for. Initially it runs one, then
idle: a click, a key, a hover change or `requestFrame()` wakes it. Cadences
([section 11](#11-cadence-animation-and-the-frame-loop)) let a clock ask for
one frame a second without busy-looping.

Run in a terminal instead of a window with `--tui` (or `ELLIPSE_TUI=1`). The
same tree renders as text cells; see the theme section for how sizes adapt.

You can also drive frames by hand for tests and screenshots by passing a
`script` to `run`:

```nim
run(App(window: WindowConfig(title: "shot"), view: view),
    script = proc () {.closure, raises.} =
      for i in 0 ..< 6: frame()
      discard saveScreenshot("out.bmp"))
```

---

## 3. Layout with clay

### 3.1 The three spellings of a container

```nim
# 1. The clay block form: an id, a declaration, then children.
clay "panel", col(width = grow(), height = fit(), gap = 8, padding = padAll(12))
    .bg(panelBg).corner(8):
  text("inside the panel")

# 2. container: the same, without an explicit id (clay picks one).
container(col(gap = 8)):
  text("one")
  text("two")

# 3. The raw engine calls, when you need to interleave logic.
openElement(hashId("row"))
configureOpenElement(row(width = grow()).bg(fieldBg))
text("child")
closeElement()
```

Inside a `view`, the whole tree is wrapped by the app's `layout:` block. If you
write your own frame driver, wrap declarations in `layout:` yourself.

### 3.2 Rows, columns and sizing

`row` stacks children left-to-right (`Direction.leftToRight`); `col` stacks them
top-to-bottom. Both take:

| argument | default | meaning |
| --- | --- | --- |
| `gap` | `0` | pixels between children |
| `padding` | `Padding()` | inset, use `padAll(n)` or `Padding(left:.., ...)` |
| `width`, `height` | `fit()` | sizing axis |
| `alignX` | `left` | cross-axis x alignment: `left`, `right`, `centerX` |
| `alignY` | `top` | cross-axis y alignment: `top`, `bottom`, `centerY` |

Sizing axes:

```nim
grow()                 # fill leftover space (min/max clamp optional)
grow(min = 0, max = 400)
fit()                  # hug the content
fit(min = 40, max = 200)
fixedPx(48)            # an exact size, in pixels
pct(0.5)               # a fraction of the parent's inner size
```

A 50/50 split of a panel:

```nim
clay "panes", row(width = grow(), height = grow(), gap = 8):
  clay "left", col(width = pct(0.5), height = grow()).bg(fieldBg): ...
  clay "right", col(width = grow(), height = grow()).bg(fieldBg): ...
```

### 3.3 Decoration combinators

All take `sink ElementDeclaration` and return a new one, so they chain with
`proc` call syntax (`.`):

```nim
row(width = grow()).bg(panelBg).corner(10).border(1, panelBorder)
```

| combinator | effect |
| --- | --- |
| `.bg(color)` | background fill |
| `.overlay(color)` | a translucent tint drawn over children |
| `.corner(r)` / `.corner(tl, tr, bl, br)` | corner radius, in pixels |
| `.border(width, color, betweenChildren = 0)` | a uniform border |
| `.gap(n)` / `.padding(p)` / `.align(x, y)` / `.sizing(w, h)` | adjust the layout |
| `.clip(horizontal, vertical, childOffset)` | make this a scroll/clip container |
| `.floating(attachTo, ...)` | position out of flow (menus, popovers, shadows) |
| `.aspect(ratio)` | width/height aspect ratio |
| `.image(data, tint)` / `.custom(data)` | draw an image / hand a painter data |

You can also set struct fields directly when a combinator does not exist:

```nim
var d = row(width = grow(), height = fit())
d.border = BorderConfig(color: panelBorder, width: BorderWidth(bottom: 1))
configureOpenElement(d)
```

### 3.4 Colors

```nim
rgb(220, 60, 60)        # opaque, alpha 255
rgb(0, 0, 0, 70)        # translucent -- alpha 0 means "draw nothing"
lerp(idle, hover, 0.5)  # interpolate two colours (also float/rect)
```

Theme tokens read the live theme (`bgColor()`, `panelBg()`, `accent()`,
`textColor()`, ...); see [section 10](#10-the-theme).

### 3.5 Text

The plain helper:

```nim
text("a label")                       # body size, text colour
text("big", 32)                       # size in points
text("red", 16, rgb(220, 60, 60))     # size and colour
```

The full form takes a `TextConfig`:

```nim
textElement("wrapped paragraph", TextConfig(
  fontSize: 18,
  color: textColor,
  fontId: 0,             # 0 = UI font, MonoFont = monospaced
  wrap: wordWrap,        # wordWrap | newlineWrap | noWrap
  justify: justifyLeft,  # justifyLeft | justifyCenter | justifyRight
  letterSpacing: 0,
  lineHeight: 0))        # 0 = measured
```

### 3.6 Padding and floating

```nim
padAll(8)
Padding(left: 8, right: 8, top: 4, bottom: 2)
```

A floating element is positioned against another element or the root, out of
the normal flow -- this is how menus, dropdown popovers and scrollbar thumbs are
built:

```nim
openElement(hashId("tip"))
configureOpenElement(col(width = fit(), padding = padAll(6)).bg(panelBg)
    .floating(attachElementId,
      offset = vec2(0.0, 6.0), zIndex = 100,
      points = AttachPoints(element: pointLeftTop, parent: pointLeftBottom),
      parentId: anchorId.id, fitViewport: true)):
  text("above the anchor")
closeElement()
```

`AttachTo` is `attachParent` (the direct parent), `attachElementId` (the element
`parentId` names), `attachRoot` (absolute), or `attachNone`. `capture` is
`capturePointer` (default, hides what is beneath) or `passThroughPointer`.
`clipTo: clipToAttachedParent` makes the float inherit the attach target's clip.

### 3.7 Scrolling

A clip container gives its children a scroll offset and clips them:

```nim
clay "panel", col(width = grow(), height = grow())
    .clip(horizontal = false, vertical = true,
          childOffset = currentScrollOffset()):
  for i in 0 ..< 100:
    text("row " & $i)
```

`updateUI` feeds the wheel into `updateScrollContainers`, with an acceleration
and glide filter. `setScrollPosition(id, vec2(x, y))` scrolls from code.
`currentScrollOffset()` is the offset to hand the children each frame.

The floating bar lives in the widget set:

```nim
scrollPanel("list", col(width = grow(), height = grow(), gap = 2)
    .bg(fieldBg).border(1, panelBorder).corner(panelRadius)
    .clip(horizontal = false, vertical = true,
          childOffset = currentScrollOffset())):
  for i in 0 ..< 24:
    listRow("list.row", i):
      text("entry " & $i)
```

`scrollPanel` names the bar `<label>.bar`, draws it after the children, and
hides it while the content fits. To attach a bar by hand call
`scrollbar(barId, containerId)` inside the container's scope after its children.
`scrollbar` also takes `always = true` to keep chrome visible while empty. See
[section 6.9](#69-scrollbars-and-scrollpanel).

---

## 4. Elements, ids and items

### 4.1 Identity

The engine tracks elements across frames by a hashed `ElementId`. Build one
with:

| helper | when |
| --- | --- |
| `hashId("name")` | a compile-time constant id; the common case |
| `elementId("name")` | a runtime equivalent, same hash |
| `localId("name", parentId)` | a child id unique inside a parent |
| `localIdWithIndex("name", index, parentId)` | a numbered child in a loop |
| `elementIdWithIndex("name", index)` | numbered, not scoped to a parent |

Ids are equal when their hashes are equal, so two `hashId("save")` calls from
anywhere match. Use `hashId` for anything a widget takes (buttons, fields,
scroll targets); use `localId`/`localIdWithIndex` for repeated children so they
stay stable as the list changes.

```nim
let saveId = hashId("save")     # often hoisted to a module-level `let`
```

`elementData(id)` gives last frame's box (`box`, `found`); it is how a floating
element or a scroll container finds its anchor. `openElementId()` is the id of
the element currently open.

### 4.2 Repeated rows and cards

The low-level rhythm is `openElement` / `configureOpenElement` / children /
`closeElement`. Two templates bracket it for lists:

```nim
item("list.row", i, row(width = grow(), padding = padAll(6))
    .bg(shade(hovered(), panelBg)).corner(itemRadius)):
  text("Entry " & $i)
```

`item(label, index, decl, body)` uses clay's local id for the label at that
index -- a stable hover identity. `item(id, decl, body)` takes an explicit id.
The declaration is configured *while the element is open*, so it may call
`hovered()` and `currentScrollOffset()`.

The themed versions pre-answer the look:

```nim
listRow("rows", i):
  text("Entry " & $i)

listCard("cards", i, fixedPx(150)):
  text("Card " & $i)
```

`listRowDecl(idle = panelBg, hover = buttonHoverBg)` and
`listCardDecl(width, idle = buttonBg, hover = buttonHoverBg)` are the styling,
so you can reuse or fork it: `item(label, i, listRowDecl(idle = fieldBg)):`.

---

## 5. Interaction primitives

These are what the widgets are built from; reach for them in custom controls.

| call | meaning |
| --- | --- |
| `hovered()` | the pointer is over the *currently open* element |
| `pointerOver(id)` | the pointer is over element `id` |
| `pressedNow()` | the primary button went down this frame |
| `clickedIn(id)` | a press completed inside `id` (down and up on it) |
| `clickedOut(id)` | a press that started inside `id` finished outside it |
| `pressing(id)` | the button is down and was pressed inside `id` (held) |
| `pressing()` | `pressing` for the open element |
| `shade(over, press)` | the raised-surface colour for hover/press |
| `shade(over, idle, hover)` | the same with a caller-chosen resting colour |
| `shade(over)` | idle/hover pick without a press state |
| `squeeze(pad, press)` | shift content down while held, outer box unchanged |
| `focusRing(decl, id)` | add an accent ring while `id` holds keyboard focus |

A hand-rolled hover button:

```nim
let over = pointerOver(myId)
let press = pressing(myId)
item(myId, row(width = fit(), padding = squeeze(padAll(8), press))
    .bg(shade(over, press)).corner(6).focusRing(myId)):
  text("Press me")
if clickedIn(myId) or keyActivated(myId):
  doSomething()
```

The press is *held*: `updateUI` snapshots the pointer-over list on the down
edge, so `pressing(id)` stays true while the button is held even if the pointer
drags off, exactly like a native button that stays sunk until release.

---

## 6. The widget set

Every widget is `import`ed with `ellipse_ui/app` (or
`ellipse_ui/widgets`). Input widgets follow the round-trip rule and also emit
an event ([section 9](#9-events)); the return value works on its own.

### 6.1 Buttons and links

```nim
if button(hashId("ok"), "OK"):
  accept()
if button(hashId("wide"), "Wide", width = fixedPx(120), height = fixedPx(40)):
  ...
if button(hashId("small"), "Small", fontSize = 14):
  ...

if textLink(hashId("more"), "Show more"):
  expanded = true
```

`button` is a Tab stop: Enter or Space presses it while focused. It draws the
raised surface, the compressed hold, and the stock terminal half-block shadow.
`textLink` is accent text that underlines on hover and presses like a link. Both
return true on the press and emit `Pressed(id)`.

### 6.2 Checkboxes and switches

```nim
wifi  = checkbox(hashId("wifi"), "Wifi", wifi)
vsync = switch(hashId("vsync"), "VSync", vsync)
```

Both return the new state, flip on Space/Enter while focused, and emit
`Toggled(id, on)`. The tick box is a filled square (not a glyph) so it renders
anywhere. A switch is the same control over a slider track.

### 6.3 Single-choice dropdown

```nim
backend = comboBox(hashId("backend"), @["OpenGL", "Vulkan", "Software"],
                   backend, "Pick one")
```

`comboBox(id, options, selected, placeholder = "", width = grow(), height =
fixedPx(controlHeight), tabIndex = 0) -> int`. It returns the selection index
(`-1` shows the placeholder) and emits `Picked(id, index)`. Keyboard: Enter
toggles the list, Space opens, Escape closes, Up/Down step the selection.
Opening one dropdown closes any other.

### 6.4 Multi-choice dropdown

The selection is a caller-owned bitmask:

```nim
modules = multiSelect(hashId("mods"),
                      @["Render", "Audio", "Input", "Networking"],
                      modules, "None selected")
```

`multiSelect(id, options, selection, placeholder = "Select...", ...) ->
Selection`. Returning the mask to store back. Use the helpers:

```nim
bit(2)                       # the flag for option 2
isSet(mask, 2)               # is option 2 selected
countSelected(mask)          # how many are selected
allSelected(4)               # a mask with the first four bits set
selectionSummary(mask, opts) # "Render, Audio" or "3 selected"
```

Build an initial mask with `bit(0) or bit(2)`. It emits
`SelectionChanged(id, selection)`. The popover has an All/None footer.

### 6.5 Text fields and the editor

```nim
artist = textField(hashId("artist"), artist, "Your name")

notes = multilineField(hashId("notes"), notes, "Leave a note...",
                       rows = 3, maxLines = 6)
```

`textField(id, text, placeholder = "", fontSize = control, width = grow(),
height = fixedPx(controlHeight), tabIndex = 0) -> string`. While focused it runs
the shared caret/selection engine. **Enter commits** (leaves the field, emits
`TextCommitted`), **Escape reverts** to the value the field was focused with. A
click outside commits too. The returned string is what you store; intermediate
edits are already in it, and `TextChanged(id, text)` fires on every change.

`multilineField` is the same engine over a growing, wrapping box: at least
`rows` lines, at most `maxLines` (0 = unbounded), then it scrolls (the wheel,
its scrollbar, and the caret pulling its line into view). Enter inserts a
newline here; a click outside or Tab leaves it.

The Emacs/readline key map both fields share:

| keys | action |
| --- | --- |
| `C-a` / `C-e` | line start / end |
| `C-b` / `C-f`, `Left`/`Right` | character back / forward |
| `M-b` / `M-f` | word back / forward |
| `Up`/`Down`, `C-p`/`C-n` | line up / down |
| `C-k` / `C-u` | kill to end / start of line |
| `C-w` / `M-d` | kill previous / next word |
| `C-y` | yank |
| `C-d` / `C-h`, `Delete`/`Backspace` | delete forward / backward |
| `C-g` / `Escape` | cancel |

Selection works with Shift+arrows, Shift+Home/End, and the clipboard (`C-c`,
`C-x`, `C-v`) goes through the system clipboard (OSC 52 in a terminal).

The **editor** is the full document area, for Notepad-style apps:

```nim
doc = editor(hashId("doc"), doc, EditorOpts(fontSize = 18,
                                           autoIndent = true)).text
```

`editor(id, text, opts = EditorOpts()) -> EditorStats`; store `result.text`
back. `EditorOpts` has `wrap` (word wrap, or a wide horizontal page),
`fontSize` (0 = theme `control`), `blocked` (a modal owns input: paint only),
`readOnly`, `maxLines` (0 = fill the parent and scroll), `indent` (what Tab
inserts), `autoIndent`, `indentAfter` (a line ending in this string indents the
next even without `autoIndent`), and `fontId` (`MonoFont` for code).

On top of the fields it adds painted selection, click/drag/double-click caret
placement, PageUp/PageDown by view height, scroll-to-caret and an undo history.
Drive it from a menu with the `editor*` verbs:

```nim
if menuItem("Undo"):    discard editorUndo(docId, doc)
if menuItem("Redo"):    discard editorRedo(docId, doc)
editorCopy(docId, doc); editorCut(docId, doc); editorPaste(docId, doc)
editorSelectAll(docId, doc)
```

Queries: `editorCaret(id, text)`, `editorSel(id, text)`, `editorUndoable()`,
`editorRedoable()`.

> **Nim tips.** In a valued widget, emit before the final `result = x`: Nimony
> may move `x` into `result`, and an emit after it would carry an emptied
> value. State that belongs to one focus session is keyed by `focusSerial()`.

### 6.6 Number fields

```nim
quantity = intNumberField(hashId("qty"), quantity, 1, 1, 60)
volume   = numberField(hashId("vol"), volume, 0.05, 0.0, 1.0)
```

`numberField(id, value, step = 1.0, minVal = -1e9, maxVal = 1e9,
whole = false, ...) -> float`. `intNumberField(id, value, step = 1,
minVal, maxVal, ...) -> int` is the whole-number view. Focusing seeds an
editable digit buffer; Enter commits the parse + clamp, Escape discards, Up/Down
and the hover steppers add/subtract `step` immediately. `numberField` emits
`NumberChanged(id, value)`; `intNumberField` catches that and emits
`IntChanged(id, value)` instead.

### 6.7 Headings and reading text

```nim
heading("Widget Gallery", 1)   # levels 1..6; h1..h6 are one-liners
overline("ellipse_ui on clay")
bodyText("A wrapped reading paragraph.")
caption("Helper text under a control.")
label("Small field label")
badge("beta")
```

`Section(title = "Audio"): ...` draws an h2 and its content as one spaced
block. `Prose:` is a column sized for reading: full-width flow with comfortable
gaps, holding `bodyText`/`caption`/heading calls. Long lines wrap at the
container width -- give the paragraph room (a `grow`-width parent).

### 6.8 Tabs

```nim
TabbedView(id = hashId("settings"), tabs = @["General", "Audio"]):
  case activeTab(hashId("settings"))
  of 0: generalPane()
  else: audioPane()
```

`TabbedView(id, tabs, body)` renders the strip and the page panel; `body` runs
after the selection was folded in, so `activeTab(id)` names the page to draw in
the same frame as the click. The selection is view state kept by the module;
move it from anywhere with `setActiveTab(id, index)`. It emits `Picked(id,
index)`. The strip is one Tab stop; Left/Right step it, Home/End jump.

For callers who own the selection, `tabStrip(id, labels, selected,
tabIndex = 0) -> int` is the standalone strip: `tab = tabStrip(id, labels,
tab)`.

### 6.9 Scrollbars and scrollPanel

`scrollbar(id, container, style = activeTheme.scrollbar, always = false)` draws
and drives the floating bar(s) of the scroll container `container`. Declare it
inside that container's scope, after its children. One bar per axis the
container clips; each appears only while its axis overflows (or always with
`always = true`). The thumb is draggable; clicking the bare track jumps to the
click.

`scrollPanel(label, decl, body)` wraps the whole shape and names the bar
`<panel>.bar`:

```nim
scrollPanel("list", col(width = grow(), height = grow(), gap = 2)
    .bg(fieldBg).border(1, panelBorder).corner(panelRadius)
    .clip(horizontal = false, vertical = true,
          childOffset = currentScrollOffset())):
  ...items...
```

The look comes from the theme's `ScrollbarStyle` (width, margin, radius,
minThumb, track/thumb/thumbHot colours) unless you pass a style.

### 6.10 Menus

```nim
toolBar("bar"):
  menu("File") do():
    if menuItem("New", "Ctrl+N"): newDoc()
    if menuItem("Open...", "Ctrl+O"): openDoc()
    menuSeparator()
    if menuItem("Quit"): quitApp()
  menu("View") do():
    if menuItem("Toggle intro"): showIntro = not showIntro
```

`menu` is a Tab stop: focused, Enter/Space/Down opens it; Up/Down move the
highlight; Enter picks; Escape closes; Left/Right step to the neighbouring menu.
`menuItem(label, shortcut = "") -> bool` returns true when clicked or picked
from the keyboard and emits `MenuPicked(label)` (menu items are identified by
their label). `menuSeparator()` draws a hairline rule.

### 6.11 Cards and stat cards

```nim
Card(title = "Session", actions = tabActions):
  bodyText("Cards hug their content.")
  wifi = switch(hashId("sw"), "Wifi", wifi)

CardRow:
  StatCard(label = "Count", value = $count, hint = "menu or buttons")
  StatCard(label = "Quantity", value = $quantity, hint = "")
```

`Card(title, actions, body)`: a framed panel; `actions` is a right-aligned slot
in the header (pass `emptySlot` when unused). `StatCard(label, value, hint)` is
a compact metric. `CardRow:` lays cards out horizontally. `Section` and `Card`
are the two grouping widgets most screens reach for.

### 6.12 Labeled

```nim
Labeled(label = "Artist"):
  artist = textField(hashId("artist"), artist, "Your name")
```

`Labeled(label, control)` puts a small label above its control -- the standard
form row.

---

## 7. Focus and the keyboard

Keyboard focus is one slot for the whole toolkit; the Tab chain walks it.
Making a widget focusable with the `widget` macro (`widget focusable Name(...)`)
injects an `id: ElementId` first parameter and a `tabIndex: int = 0` last one
and registers it while it lays out. Registering makes the widget:

- focusable by click -- a press inside takes focus, a press outside while it
  holds focus lets go;
- a stop on the Tab chain.

Tab order follows the HTML `tabindex` rules: positive `tabIndex` first,
ascending (ties in layout order), then every `tabIndex == 0` in layout order. A
negative `tabIndex` keeps the widget click-focusable but off the chain. The
chain wraps.

Inside a focusable widget's body you read:

| call | meaning |
| --- | --- |
| `focused(id)` | `id` holds focus |
| `gainedFocus(id)` | focus arrived at `id` this frame (by click/Tab/`setFocus`) |
| `keyActivated(id)` | Enter or Space went down while `id` focused |
| `keyHit(id, kind)` | a specific `KeyEventKind` went down while focused |
| `spaceHit(id)` | Space went down while focused |
| `focusSerial()` | bumped on every focus change (per-session state) |

Outside the macro you can register and move focus yourself:

```nim
registerFocus(id, tabIndex = 0, inside = ElementId())  # declare + click-fold
setFocus(id); blur();
focusNext(); focusPrev()          # Tab / Shift+Tab by hand
focusedId()                       # the raw id holding focus, 0 = none
focusIdOf()                       # same, as uint32
```

A custom focusable widget:

```nim
widget focusable Chip(label: string):
  emits Pressed
  item(id, row(width = fit(), padding = padAll(6))
      .bg(shade(pointerOver(id), pressing(id))).corner(6).focusRing(id)):
    text(label)
  if clickedIn(id) or keyActivated(id):
    emit Pressed(id: id)
```

Call it as `Chip(hashId("save"), "Save", tabIndex = 1)`.

The caret engine and Escape snapshots use `focusSerial()`: a field re-seeds its
buffer when the serial it recorded no longer matches, so a fresh focus session
starts clean.

---

## 8. Keymaps and shortcuts

Keymaps run once a frame, before focus and the widgets see the keys, and take
the keys they handle. Chords are written the way menus print them:

```nim
var main = Keymap(name: "app")
main.bindKey("Ctrl+S", quickSave)
main.bindKey("Ctrl+Shift+S", saveAs)
main.bindKey("F3", findNext)
main.bindKey("Ctrl+/", toggleComment)
installKeymap(main)
```

`Keymap` has `name`, `active` (a `proc(): bool`, nil = always), and `modal`
(while active, hides every keymap installed before it). `installKeymap(m)` puts
`m` on top, replacing an installed keymap of the same name in place.
`uninstallKeymap(name)` and `clearKeymaps()` remove them.

```nim
var dialogKeys = Keymap(name: "dialog", active: dialogOpen, modal: true)
dialogKeys.bindKey("Enter", confirm)
dialogKeys.bindKey("Escape", cancel)
installKeymap(dialogKeys)
```

The first binding a key matches runs, and the key is *taken*: `keyEvents()`,
`frameKeys()` and every widget see the frame without it -- so `Ctrl+F` opens
Find and does not also move the caret in the focused field. An active `modal`
keymap hides every keymap installed before it (a dialog's app chords go dead).
`active` is asked again for each key, so a chord that opens a dialog hands the
rest of the frame's keys to it.

Chord syntax: modifiers `Ctrl`, `Shift`, `Alt` (any order/case, `+` between),
then one key. A key is a character (`Ctrl+S`, `Ctrl+/`, `Alt+[`, `Ctrl+0`) or a
name: Enter (Return), Escape (Esc), Tab, Backspace, Delete (Del), Insert (Ins),
Left, Right, Up, Down, Home, End, PageUp (PgUp), PageDown (PgDn), Space,
F1..F12, Plus, Minus. With Ctrl or Alt a character names the *unshifted* key, so
the shifted symbol goes as `Shift+`: `Ctrl+Shift+/`, not `Ctrl+?`. `Ctrl+Plus`
matches Ctrl+= with or without Shift, and the keypad's +. A character chord
without Ctrl/Alt matches typed text: `"?"` is any keypress that types `?`.

For a one-off check without a keymap: `if pressed("Ctrl+Enter"): send()`.

---

## 9. Events

Events are typed payloads that bubble from the emitting widget through its
enclosing widgets until a handler catches them. They suit code that is above the
widget that changed -- a form that marks itself dirty, a parent that updates a
summary -- without threading return values through every call.

### 9.1 Declaring and catching in a widget

The `widget` macro lifts `emits` and `event` sections out of the body:

```nim
widget focusable Toggle(label: string, on: bool):
  emits Toggled(on: bool)          # declares `type Toggled* = object` + emit
  let clicked = clickedIn(id) or keyActivated(id)
  item(id, toggleRowDecl(pointerOver(id), pressing(id)).focusRing(id)):
    text(label)
  if clicked:
    emit Toggled(on: not on)

widget Settings(body: proc(): void):
  event Toggled(e):                # caught: bubbling stops here...
    dirty = true
    reemit                         # ...unless passed on
  body()
```

- `emits Name(field: Type, ...)` declares the event type (an exported object
  plus its `emit` overload).
- A bare `emits Name` names one declared elsewhere -- by another widget or a
  top-level `defineEvent Name(...)`. The macro refuses an `emit` of an event the
  widget does not declare.
- `event Name(e):` sections are the handlers; `e` points at the live payload.
  A handler *consumes* the event by default. `reemit` lets it continue to the
  next frame up, carrying whatever the handler changed. An `emit` inside a
  handler starts at the handler's *parent* frame, so a widget can translate one
  event into another without catching its own translation.
- Slot content runs inside the frame of the widget that calls the slot, so an
  `emit` in a caller's block bubbles through the host widget first.

### 9.2 Catching outside a widget

```nim
handleEvents:
  event Toggled(e):
    if e.id == wifiId: dirty = true
  event FormChanged:
    save()
  drawUi()
```

`handleEvents:` installs a frame around its statements; the `event` sections
become that frame's handlers and the rest runs inside it.

### 9.3 Declaring an event to share

```nim
defineEvent Saved(path: string)
```

declares `Saved` at top level for widgets that share it via a bare
`emits Saved`.

### 9.4 The stock events

The built-in widgets emit these, each tagged with the emitter's element id (or
label) so one handler can serve several controls:

| event | payload | emitted by |
| --- | --- | --- |
| `Pressed` | `id` | `button`, `textLink` |
| `Toggled` | `id`, `on` | `checkbox`, `switch` |
| `Picked` | `id`, `index` | `comboBox`, `tabStrip`, `TabbedView` |
| `TextChanged` | `id`, `text` | `textField`, `multilineField`, `editor` |
| `TextCommitted` | `id`, `text` | `textField` (Enter) |
| `NumberChanged` | `id`, `value` | `numberField` |
| `IntChanged` | `id`, `value` | `intNumberField` |
| `SelectionChanged` | `id`, `selection` | `multiSelect` |
| `MenuPicked` | `label` | `menuItem` |

The widgets still return their value too, so the event is optional.

### 9.5 The event log

Because handlers run mid-layout, whatever a catching widget already drew this
frame reflects the state before the event. `eventLog()` records each emit of the
last complete frame: the emitting widget (`source`), the frames it passed
(`path`), the frames that handled it (`handledBy`), and `consumed` (false =
reached the root unhandled). `currentEventLog()` is the frame in progress.
`WidgetKey` is a stable per-invocation identity; the debug overlay counts on it.

In a valued widget (`-> T`), **emit before the final `result = x`**.

---

## 10. The theme

A `Theme` collects every visual decision the standard widgets make:

```nim
type Theme = object
  palette: Palette          # colours
  text: TextSizes           # type scale, in points
  radii: Radii              # corner rounding, in pixels
  metrics: Metrics          # sizes, paddings, gaps, border widths
  scrollbar: ScrollbarStyle # floating bar geometry + colours
  cells: CellLook           # sizes for the terminal
```

Widgets read the *live* theme `activeTheme` while they render, so a change takes
effect from the next widget declaration on -- the immediate-mode way to
customise a control or apply an effect.

```nim
activeTheme.palette.accent = rgb(220, 60, 60)   # onward for this frame

pushTheme()                                     # snapshot...
activeTheme.radii.button = 0.0                  # ...square buttons...
discard button(hashId("sq"), "Square")
popTheme()                                      # ...and restore

withTheme:                                      # scoped: only this block
  activeTheme.palette.buttonBg = rgb(150, 40, 40)
  discard button(hashId("del"), "Delete")
```

- `pushTheme()` snapshots the live theme so you can mutate it freely;
  `popTheme()` puts it back. `pushTheme(t)` swaps in a whole theme.
- `withTheme:` runs its block against a patched theme and restores on exit.
- `setTheme(t)` replaces the live theme outright; `setTheme(defaultTheme())`
  resets to the built-in look.
- `defaultTheme()` reproduces the widget set's original look token for token.

The colour tokens keep their old names as zero-argument templates over the live
palette, usable exactly like constants:

```nim
bgColor() panelBg() panelBorder() buttonBg() buttonHoverBg() buttonPressBg()
fieldBg() selectedBg() accent() textColor() dimColor() labelColor()
onAccentColor() shadowColor()
itemRadius() panelRadius() padItem() hairline()
```

A full custom theme:

```nim
func lightTheme(): Theme =
  var t = defaultTheme()
  t.palette = Palette(
    bg: rgb(244, 245, 248),
    panelBg: rgb(255, 255, 255),
    panelBorder: rgb(208, 212, 222),
    buttonBg: rgb(226, 230, 238),
    buttonHoverBg: rgb(203, 210, 224),
    buttonPressBg: rgb(178, 187, 206),
    fieldBg: rgb(255, 255, 255),
    selectedBg: rgb(206, 221, 248),
    accent: rgb(46, 92, 190),
    textColor: rgb(24, 27, 34),
    dimColor: rgb(116, 122, 138),
    labelColor: rgb(72, 78, 94),
    onAccent: rgb(255, 255, 255),
    shadow: rgb(20, 24, 40, 60))
  t.radii = Radii(button: 0.0, field: 0.0, ...)   # start from defaultRadii()
  t.scrollbar = defaultScrollbarStyle()
  t
```

Read specific tokens with `activeTheme.text.control`, `activeTheme.radii.card`,
`activeTheme.metrics.padButton` and friends -- often via a `let t = activeTheme`
at the top of a widget.

**In the terminal** (`--tui`, `ELLIPSE_TUI=1`) the palette, type scale and radii
apply as they are (colours as 24-bit/256/16, large type as bold, radii as
rounded box corners) while sizes come from `cells`: `CellLook` carries a
`Metrics` and scrollbar geometry tuned for 8x16 cells (one-row controls,
one-column insets), which `setTheme`/`pushTheme` swap in for `metrics` and the
bar. Tune a theme's terminal look by editing `cells`; values are virtual pixels
snapped to whole cells. `forTerminal(t)` applies the swap by hand.

---

## 11. Cadence, animation and the frame loop

The loop only runs frames somebody asked for. A widget whose content is costly
or naturally slow guards it with `refresh`, which both decides whether the block
runs this frame and schedules the frame it is due in next:

```nim
var clockText = ""

widget Clock():
  refresh every(1000, wall = true):      # on the second, every second
    clockText = formatClock(now())
  text(clockText)

widget Title():
  refresh everyFrame():                  # keep it live at vsync
    titleText = focusedWindowTitle()
  text(titleText)

widget CpuGraph():
  item(hashId("cpu"), row(...)):
    refresh onHover(every(100)):         # sample only while looked at
      samples.add readCpu()
    ...
```

Cadences (from `ellipse/platform/pacing`, re-exported): `everyFrame()`,
`every(ms, wall = false)`, `onInput()` (first frame and `invalidate` only),
`onHover(rate)` and `c.whileHovered(rate)`. Hover means the pointer is over the
element open at the guard -- put the guard inside the widget's own `item` -- or
over a `hoverId` passed explicitly.

A guard is identified by its widget (the event system's `WidgetKey`) and its
position among that widget's guards this frame. Pass a `label` when guards come
and go conditionally, or when code outside the UI must wake it:

```nim
widget Title():
  refresh "title", onInput():
    titleText = wm.focusedTitle()
  text(titleText)

proc onWmFocusChanged() = invalidate("title")   # runs the next frame
```

`invalidate(label)` / `invalidate()` / `invalidate(key)` make the matching guard
due and ask for a frame. `requestFrame()` asks for exactly the next one.

Animation eases toward a target and keeps frames coming until it lands:

```nim
let t = approach(id, if over: 1.0 else: 0.0)   # 0..1, exp ease, rate default 14
item(id, row(...).bg(lerp(idle, hover, t))): ...
```

`approach(id, target, rate = 14.0, slot = 0)` works for floats and (per channel)
`Color`. `trackPointer()` wakes the loop on every pointer move for a widget that
follows the cursor. `frameDelta()`, `frameNow()`, `frameWall()` and the
resize flags come from the same module.

---

## 12. The app shell and its hooks

`app.nim` puts everything a `main` used to spell out -- stdout logging, resizes,
the F1 debug overlay, the per-frame update + layout, the render and the paced
loop -- behind `run`.

```nim
type App = object
  window: WindowConfig    # title, size, or a docked layer-shell bar
  debugMode: bool = true  # F1 toggles the debug overlay
  log: bool = true        # install the standard stdout logger
  prepare: AppFn          # first, in every process (dialogs too)
  setup: AppFn            # once, after bootup (main process only)
  input: InputHook        # every frame, inside updateUI
  before: AppFn           # every frame, before the layout pass
  view: AppFn             # every frame, inside layout
  after: AppFn            # every frame, after the layout pass
```

A frame runs, in order:

| hook | when | typical use |
| --- | --- | --- |
| `input` | inside `updateUI`, before focus, widgets and scrolling see input | app-wide bindings that take keys (`consumeKeys`) or the wheel (`holdWheel`) |
| `before` | after `updateUI`, before layout | chords read from `keyEvents` |
| `view` | inside `layout` | the widget tree |
| `after` | after layout | focus restores, window title |

`prepare` runs first, before the window opens, in *every* process the app starts
-- dialog windows included: the place to define dialogs and pick the theme.
`setup` runs once, after the window is up and before the first frame, in the
main process only.

Register extra input hooks (they run in `updateUI`, after the input frame opens
and before focus sees the keys, where F1 takes its key):

```nim
onInputFrame(proc () {.closure.} =
  if pressed("Ctrl+Equal"):
    zoom += 0.1
    holdWheel())        # keep this frame's wheel from also scrolling
```

Other entry points: `launch(app)` wires the app in without entering the loop;
`run(app)` opens and loops; `run(app, script)` skips the loop and runs `script`
instead (driving `frame()` yourself); `frame()` does one update+layout pass;
`render()` draws. Screenshots: set `ELLIPSE_SCREENSHOT=<path>` or call
`saveScreenshot(path, bg)`.

In `prepare`, pick your theme. In `view`, read app state. Dialogs ride along
every frame automatically (see below).

---

## 13. Dialogs

A dialog is defined at module level so that a dialog running in its own window
(the program started again as a child process) can define it too.

```nim
let memberDialog = defineDialog("app.member", DialogSpec(
  title: "Add team member",
  width: 680, maxHeight: 680, scroll: true,
  header: DialogHeader(enabled: true, fullscreen: true),
  body: body, footer: footer))
```

`DialogSpec` fields: `title`, `header`, `width` (default 420), `maxHeight`
(640), `scroll` (the body scrolls between title and footer), `dismissable`
(Escape and the backdrop cancel; default true), `body` (required `DialogFn`),
`footer` (a right-aligned row).

`DialogHeader` (inline dialogs only) is `enabled`, `draggable` (default true),
`fullscreen`, `closeButton` (default true; cancels like Escape). A windowed
dialog uses the window's own title bar.

Open it over the app, or in a window of its own:

```nim
enum DialogMode = dmInline, dmWindow

memberDialog.open(mode = dmWindow,
  args = fields(...),
  onDone = proc (r: DialogResult) {.closure.} =
    if r.accepted:
      members.add fromFields(r.fields))
```

`open(d: Dialog, args = Fields(), mode = dmInline, onDone = nil DialogDone,
title = "")` returns nothing (read state back through `onDone` or a handle).
`onDialog(name, ...)` opens by name. `DialogResult` is `status`, `answer` (which
button closed it), `fields`; `DialogStatus` is `dsOpen`, `dsAccepted`,
`dsCancelled`, `dsFailed`; `accepted(r)` is true for `dsAccepted`.

Inside a dialog body:

```nim
proc body() {.raises.} =
  if dialogOpened():                    # first frame: seed the draft
    draft = blank()
    focusAt(nameId, draft.name, draft.name.len)
  if focusIdOf() == bioId.id:           # Enter breaks the line here
    passEnter()
  if dialogEnter():                     # Enter elsewhere submits
    submit()
  caption("Everything is a draft until you submit.")
  formBody()
```

| call | meaning |
| --- | --- |
| `dialogArgs()` | the `Fields` the opener passed |
| `dialogOpened()` | true on this dialog's first frame |
| `dialogEnter()` | Enter was pressed this frame (true unless `passEnter`) |
| `passEnter()` | let this frame's Enter reach the focused widget instead |
| `dialogInWindow()` | the dialog is a window of its own |
| `accept(values = Fields(), answer = "ok")` | close with an accepted result |
| `cancel()` | close as cancelled |

Helpers to manage openings: `lastOpened()`, `dialogIsOpen(h)`,
`anyDialogOpen()`, `closeDialog(h, status, answer)`, `closeDialog(status,
answer, values)`, `dialogHandle()`, `dialogFullscreen()` /
`setDialogFullscreen(on)`.

### 13.1 The Fields wire form

`Fields` is the ordered string bag a dialog takes as arguments and hands back as
its result. It serialises to a single escaped line that crosses a process
boundary safely:

```nim
var f = Fields()
f.put("name", "Grace")
f.put("hours", 40)
f.put("remote", true)
f.put("tags", @["a", "b"])        # via putList

f.get("name")            # "Grace"
f.getInt("hours")        # 40
f.getFloat("rate", 0.0)  # default when missing
f.getBool("remote")      # true
f.getList("tags")        # @["a", "b"]
f.getFields("nested")    # a nested Fields
let line = encode(f)     # "name=Grace&hours=40&remote=1"
decode(line) == f
```

### 13.2 Quick popups

```nim
alert("The build finished.", title = "Build", detail = "412 files, 3.1 s")
confirm("Delete the 3 selected files?", proc (yes: bool) {.closure.} =
  ...)
ask("Save changes?", @["Save", "Don't save", "Cancel"],
    proc (i: int) {.closure.} = ..., cancelIndex = 2)
prompt("Name the folder:", proc (s: string) {.closure.} = ...,
       text = "Untitled")
toast("Copied to clipboard")           # seconds = 2.5
messageBox("...", @["OK", "Cancel"], title = "...")
```

Each takes an optional `mode = dmInline/dmWindow`. When the app started a dialog
in its own window, the child's answer comes back serialised through `onDone`.

---

## 14. Hot reloading

`import ellipse` brings `ellipse/hotload`. Marking a widget `widget hot Name(...)`
makes it hot-loadable: `make hot` lets a running app rebuild just that module
into a shared library and swap it in when you save the file. The source stays
the same shape; the `widget` plugin generates the rest. `make run` and the
gallery use the hot-loading path. (In Owl, saving any project file reloads it
live -- see [owl-tutorial.md](owl-tutorial.md).)

---

## 15. A full walkthrough

This pulls the pieces together into the shape `apps/gallery.nim` uses.

```nim
import ellipse_ui/app

# --- app state, owned by the module and mutated through widget round trips ---
var count = 0
var vsync = true
var backend = 1
var artist = "Ada Lovelace"

var backends: seq[string] = @[]

proc fillLists() =
  backends = @["OpenGL", "Vulkan", "Software"]

# --- page scaffolding: small widgets that compose slots ---------------------
widget Page(body: proc(): void):
  clay "app", col(width = grow(), height = grow(), alignX = centerX)
      .bg(bgColor):
    body()

widget Toolbar(body: proc(): void):
  toolBar("toolbar", body)

widget Scroll(body: proc(): void):
  scrollPanel "scroll", col(width = grow(), height = grow(), padding = padAll(28))
      .clip(horizontal = false, vertical = true,
            childOffset = currentScrollOffset()):
    clay "content", col(width = grow(max = 820), height = fit(), gap = 10,
                        alignX = centerX):
      body()

# --- the screen -------------------------------------------------------------
proc drawApp() =
  Scroll:
    heading("Widget Gallery", 1)
    overline("ellipse_ui on clay")

    Section(title = "Toggles & buttons"):
      clay "trow", row(width = grow(), height = fit(), gap = 28, alignY = centerY):
        vsync = checkbox(hashId("cb-vsync"), "VSync", vsync)
        if button(hashId("btn-inc"), "Increment", height = fixedPx(48)):
          inc count
        badge("beta")

    Section(title = "Dropdowns"):
      clay "drow", row(width = grow(), height = fit(), gap = 16, alignY = top):
        Labeled(label = "Backend"):
          backend = comboBox(hashId("combo-backend"), backends, backend, "Pick one")

    Section(title = "Text entry"):
      Labeled(label = "Artist"):
        artist = textField(hashId("tf-artist"), artist, "Your name")

    label("Counter -- driven by the File menu, too")
    clay "counter", row(width = grow(), height = fit(), gap = 12, alignY = centerY):
      text($count, 48)
      if button(hashId("inc"), "Increment", height = fixedPx(44)):
        inc count

proc view() {.raises.} =
  Page:
    Toolbar:
      menu("File") do():
        if menuItem("Increment", "Ctrl++"): inc count
        if menuItem("Decrement", "Ctrl+-"): dec count
        menuSeparator()
        if menuItem("Scroll to top"):
          setScrollPosition(hashId("scroll"), vec2(0.0, 0.0))
    drawApp()

when isMainModule:
  run App(window: WindowConfig(title: "Widget Gallery"), setup: fillLists,
          view: view)
```

That is a complete application: a scrollable page, a menu bar, immediate-mode
state, a themed widget set and floating scrollbars -- the same structure the
shipped gallery uses, with more widgets. Read [reference-widgets.md](reference-widgets.md)
for signatures paged in one place, and the shipping `apps/gallery.nim` for a
tour of every control at once.
