# Widget & API reference

One-page signature tables for the whole toolkit. Nim signatures are the real
`proc`/`widget` declarations from `src/ellipse_ui`; Owl signatures are the
builtin names and named arguments from `src/owl/libraries/gui.owl` +
`src/owl/libraries/gui.nim`. Read the tutorials for behaviour:

- [nim-tutorial.md](nim-tutorial.md) — full Nim/Nimony walkthrough.
- [owl-tutorial.md](owl-tutorial.md) — full Owl walkthrough.

Conventions used below:

- `id` is an `ElementId` (Nim) — build it with `hashId("name")` or `localId`.
  In Owl you pass a plain string (`"name"`) wherever `id` appears.
- `A = ...` denotes a default value.
- `-> T` is the value the widget returns; **store it back** into your state.
- Owl named arguments are passed as `(name = value)`; positional arguments
  also work where listed.

---

## 1. Layout vocabulary (clay)

### 1.1 Sizing axes

| Nim | Owl | Meaning |
| --- | --- | --- |
| `fit(min, max)` | `(fit)` | Shrink to content (default). |
| `grow(min, max)` | `(grow)` | Fill the available space. |
| `fixedPx(pixels)` | `(fixed n)` | Exactly `n` pixels. |
| `pct(fraction)` | `(pct f)` | A fraction of the parent (0..1). |

In Owl these are values passed to `width` / `height` / `scroll`-style options,
e.g. `(width = grow)` or `(height = (fixed 200))`.

### 1.2 Containers

| Nim | Owl | Notes |
| --- | --- | --- |
| `clay "label", decl, body` | — | Named container: open `label`, configure `decl`, run `body`, close. |
| `clay decl, body` | — | Auto-id container (repeatable). |
| `container(decl): body` | — | Auto-id bracket, same as `clay` without a label. |
| `row(...)`, `col(...)` | `row (…):`, `column (…):` | The two directions (Owl `row`/`column`). |
| `item(id, decl): body` | — | Explicit-id bracket. |
| `item(label, index, decl): body` | — | Stable id for a loop child (`localIdWithIndex`). |
| `textElement(text, cfg)` | `text value` | A text leaf (advanced; prefer the text widgets). |

`row` / `col` / `column` options:

| Nim parameter | Owl option | Default |
| --- | --- | --- |
| `gap: int` | `(gap = n)` | `0` |
| `padding: Padding` | `(padding = n \| (x y) \| (l r t b) \| record)` | `Padding()` |
| `width: SizingAxis` | `(width = …)` | `fit()` |
| `height: SizingAxis` | `(height = …)` | `fit()` |
| `alignX: AlignX` | `(align-x = "left"/"center"/"right")` | `left` |
| `alignY: AlignY` | `(align-y = "top"/"center"/"bottom")` | `top` |
| — | `(bg = color)` / `(hover-bg = color)` | none |
| — | `(corner = n)` | `0` |
| — | `(border = n) (border-color = …)` | none |
| — | `(clip = true/"x"/"y"/"both")` | none |
| — | `(scroll = true/"x"/"y"/"both")` | none |
| — | `(focus-ring = id)` | none |

### 1.3 Declaration combinators (Nim)

These take and return an `ElementDeclaration`, so they chain after `row`/`col`:

| Combinator | Meaning |
| --- | --- |
| `.bg(color)` | Fill colour. |
| `.overlay(color)` | Overlay tint. |
| `.corner(radius)` / `.corner(tl, tr, bl, br)` | Corner rounding. |
| `.border(width, color, betweenChildren = 0)` | Border. |
| `.padding(padding)` | Padding (again). |
| `.gap(gap)` | Gap (again). |
| `.align(x, y)` / `.sizing(w, h)` | Alignment / sizing (again). |
| `.clip(horizontal, vertical, childOffset = Vec2())` | Make a scroll/clip container. |
| `.custom(data)` | A custom-painted element (`pointer` payload). |
| `.image(data, tint)` | An image leaf. |
| `.aspect(ratio)` | Lock an aspect ratio. |
| `.floating(...)` | Take the element out of flow. |
| `.focusRing(id)` | Draw a focus ring tied to `id`. |

### 1.4 Shared layout parts

| Nim | Owl | Meaning |
| --- | --- | --- |
| `spacer(vertical = false)` | `spacer` (value) | Push the next sibling to the far edge. |
| `chevron(isOpen)` | — | Dropdown caret glyph. |
| `tickBox(checked)` | — | A tick square. |
| `textLine(text, cfg, width)` | — | A static text line. |

---

## 2. Text & headings

| Nim | Owl | Returns |
| --- | --- | --- |
| `text(s)` *(via `clay`)* | `text s` | — |
| `label(text: string)` | `label s` | — |
| `bodyText(text, fontSize = control)` | `body-text s` | — |
| `caption(text)` | `caption s` | — |
| `overline(text)` | `overline s` | — |
| `badge(text)` | `badge s` | — |
| `heading(text, level = 1)` | `heading text (level = n)` | — |
| `h1(text)` … `h6(text)` | — | — |
| `textLink(text)` `focusable` | `text-link id text` | `bool` (clicked); emits `Pressed`. |

```
Nim : if textLink(hashId("more"), "Add one"): …
Owl : when (text-link "more" "Add one"): …
```

---

## 3. Input widgets

All follow the same contract: value in, returned value stored back, and an
event emitted for code further up.

### 3.1 Button & links

```nim
widget focusable button(label: string, width = fit(), height = fit(),
                        fontSize = 0'u16) -> bool
```

| Owl | Returns | Event |
| --- | --- | --- |
| `button id label (width = …) (height = …) (font-size = n) (tab-index = n)` | `true` on press | `Pressed` |
| `text-link id text` | `true` on click | `Pressed` |

### 3.2 Checkbox & switch

```nim
widget focusable checkbox(label: string, checked: bool,
                          fontSize = activeTheme.text.control) -> bool
widget focusable switch(label: string, on: bool) -> bool
```

| Owl | Returns | Event |
| --- | --- | --- |
| `checkbox id label checked` | new `checked` | `Toggled` |
| `switch id label on` | new `on` | `Toggled` |

```
Nim : checked = checkbox(hashId("wifi"), "Wifi", checked)
Owl : set checked (checkbox "wifi" "Wifi" checked)
```

### 3.3 Text fields

```nim
widget textField(id: ElementId, text: string, placeholder = "",
                 fontSize = activeTheme.text.control, width = grow(),
                 height = fixedPx(activeTheme.metrics.controlHeight),
                 tabIndex = 0) -> string

widget multilineField(id: ElementId, text: string, placeholder = "",
                      fontSize = activeTheme.text.control, rows = 4,
                      maxLines = 8, width = grow(), tabIndex = 0) -> string
```

| Owl | Returns | Events |
| --- | --- | --- |
| `text-field id text (placeholder = …) (width = …) (tab-index = n)` | new text | `TextChanged`, `TextCommitted` |
| `multiline-field id text (placeholder = …) (rows = n) (max-lines = n) (width = …) (tab-index = n)` | new text | `TextChanged`, `TextCommitted` |

Enter commits a single-line field; a multiline field inserts a newline and
commits on leaving the field.

### 3.4 Number fields

```nim
widget focusable numberField(value: float, step = 1.0,
                             minVal = -1.0e9, maxVal = 1.0e9, whole = false,
                             width = grow(),
                             height = fixedPx(activeTheme.metrics.controlHeight)) -> float

widget intNumberField(id: ElementId, value: int, step = 1,
                      minVal = -1000000000, maxVal = 1000000000,
                      width = grow(),
                      height = fixedPx(activeTheme.metrics.controlHeight),
                      tabIndex = 0) -> int
```

| Owl | Returns | Event |
| --- | --- | --- |
| `number-field id value (step = n) (min = n) (max = n) (whole = bool) (width = …) (tab-index = n)` | new value | `NumberChanged` |
| `int-number-field id value (step = n) (min = n) (max = n) (width = …) (tab-index = n)` | new value | `IntChanged` |

### 3.5 Dropdowns

```nim
widget comboBox(id: ElementId, options: seq[string], selected: int,
               placeholder = "", width = grow(),
               height = fixedPx(activeTheme.metrics.controlHeight),
               tabIndex = 0) -> int

widget multiSelect(id: ElementId, options: seq[string], selection: Selection,
                  placeholder = "Select...", width = grow(),
                  height = fixedPx(activeTheme.metrics.controlHeight),
                  tabIndex = 0) -> Selection
```

| Owl | Returns | Event |
| --- | --- | --- |
| `combo-box id options selected (placeholder = …) (width = …) (tab-index = n)` | index (`-1` = placeholder) | `Picked` |
| `multi-select id options selection (placeholder = …) (width = …) (tab-index = n)` | new mask | `SelectionChanged` |

`Selection` is a bitmask. Helpers (Nim, `widgets/multiselects`):

| Function | Meaning |
| --- | --- |
| `bit(i)` | One-item mask. |
| `isSet(sel, i)` | Is index `i` selected. |
| `allSelected(n)` | Mask with the first `n` set. |
| `countSelected(sel)` | How many are set. |
| `selectionSummary(sel, options)` | A short human summary. |

### 3.6 Tabs

```nim
widget tabStrip(id: ElementId, labels: seq[string], selected: int,
               tabIndex = 0) -> int
widget TabbedView(id: ElementId, tabs: seq[string], body: proc(): void)

proc activeTab*(id: ElementId): int
proc setActiveTab*(id: ElementId, index: int)
```

| Owl | Returns |
| --- | --- |
| `tab-strip id labels selected (tab-index = n)` | new index |
| `tabbed-view id tabs: body` | — (body reads `(active-tab id)`) |
| `(active-tab id)` | current index |

### 3.7 Menus

```nim
proc toolBar*(id: string, blk: MenuBody)
proc menu*(label: string, blk: MenuBody)
proc menuSeparator*()
widget menuItem(label: string, shortcut = "") -> bool
```

| Owl | Returns | Event |
| --- | --- | --- |
| `tool-bar id: menus` | — | — |
| `menu label: items` | — | — |
| `menu-item label (shortcut = …)` | `true` when chosen | `MenuPicked` |
| `menu-separator` | — | — |

### 3.8 Lists

```nim
template listRow*(label, index, body)            # themed hover row
template listCard*(label, index, width, body)    # themed hover card
proc listRowDecl*(idle = panelBg, hover = buttonHoverBg): ElementDeclaration
proc listCardDecl*(width: SizingAxis, idle = buttonBg,
                   hover = buttonHoverBg): ElementDeclaration
```

| Owl | Notes |
| --- | --- |
| `list-row label index: body` | Themed hover row of a list panel. |
| `list-card label index (width = …): body` | Themed hover card of a strip. |

### 3.9 Editor

```nim
widget editor(id: ElementId, text: string, opts = EditorOpts()) -> EditorStats
```

`EditorOpts` / `EditorStats` live in `ellipse_ui/widgets/editor`. The editor
is a scrollable document area with painted selection, drag caret and an undo
history; `EditorStats.text` is the text to store back. Owl exposes it as
`code-editor` plus the caret/clipboard helpers below.

| Owl | Meaning |
| --- | --- |
| `code-editor id text (opts = …)` | The document area. |
| `editor-caret id text` | Caret position. |
| `take-key id text` | Hand one key to the editor. |
| `typed-text` | Text typed this frame. |
| `set-clipboard s`, `scroll-into-view id`, `scroll-to-end id` | Helpers. |

---

## 4. Composite widgets

| Nim | Owl | Shape |
| --- | --- | --- |
| `Card(title, actions, body)` | `card title (actions = fun): body` | Framed panel with a title row. |
| `StatCard(label, value, hint)` | `stat-card label value (hint = …)` | Big number panel. |
| `CardRow(body)` | `card-row: body` | A row of cards. |
| `Section(title, body)` | `section title: body` | Heading-2 + content group. |
| `Prose(body)` | `prose: body` | A reading column. |
| `Labeled(label, control)` | `labeled label: control` | Field label above its control. |
| `container(decl): body` | `row`/`column` | Auto-id bracket. |

Slots (`body`, `actions`, `control`) are `proc(): void` in Nim and a `:`
block or a named fun in Owl.

```
Nim : Labeled(label = "Name"):
        name = textField(hashId("name"), name)
Owl : labeled "Name":
          set name (text-field "name" name)
```

---

## 5. Scrolling

| Nim | Owl | Meaning |
| --- | --- | --- |
| `scrollbar(id, container, style = …, always = false)` | (attached by `scroll`) | Floating bar(s) of a clip container. |
| `scrollPanel(label, decl, body)` | — | Framed clip container + attached bar under `label & ".bar"`. |
| `setScrollPosition(id, Vec2(x, y))` | `set-scroll-position id (x = n) (y = n)` | Scroll a container programmatically. |
| `currentScrollOffset()` | (used by `scroll`) | The offset to feed `.clip(childOffset = …)`. |

Add `.clip(horizontal = …, vertical = …, childOffset = currentScrollOffset())`
to the container, then call `scrollbar` / `scrollPanel` for the bars. Owl's
`(scroll = true/"x"/"y"/"both")` option does both for you.

---

## 6. Focus & keyboard

| Nim | Owl | Meaning |
| --- | --- | --- |
| `focused(id)` | `focused id` | Is `id` the focus target. |
| `focus(id, text)` / `focusAt(id, text, pos)` | `set-focus id` / `focus-at id text (pos = n)` | Move focus. |
| `registerFocus` (via `focusable`) | `register-focus id tab-index` | Put a widget on the Tab chain. |
| `gainedFocus(id)` | `gained-focus id` | Focus arrived this frame. |
| `keyActivated(id)` | `activated id` | Enter/Space on the focused widget. |
| `keyPressed(key)` | `key-pressed key` | A key is held. |
| `frameKeys()` | — | Keys seen this frame. |
| `installKeyFilter(fn)` / `clearKeyFilter()` | — | Filter the key stream. |

See [nim-tutorial.md](nim-tutorial.md) §7–8 and
[owl-tutorial.md](owl-tutorial.md) §7 for keymaps and shortcut vocabulary.

---

## 7. Interaction primitives

Read from whatever element is currently open.

| Nim | Owl | Meaning |
| --- | --- | --- |
| `hovered()` | `hovered` | Pointer over the open element. |
| `pointerOver(id)` | — | Pointer over a specific id. |
| `pressing(id)` / `pressing()` | `pressing id` | Held down. |
| `clickedIn(id)` | `clicked id` | Click completed on `id`. |
| `clickedOut(id)` | — | Click completed elsewhere. |
| `pressedNow()` | — | A press edge this frame. |
| `shade(over, press, idle, hover)` | — | Three-way button fill. |
| `squeeze(pad, press)` | — | Compress padding while held. |

---

## 8. Events

| Nim | Owl | Meaning |
| --- | --- | --- |
| `emits Name(field: T, …)` | `emits Name field…` | Declare an event. |
| `emit Name(field = value, …)` | `emit Name (field = value)…` | Emit it. |
| `event Name(e): body` | `event Name e: body` | Catch it in a widget. |
| `handleEvents(): body` / `handleEvents(handler)` | `handle-events: body` | Catch at a call site. |
| `reemit()` | `reemit` | Pass a caught event on. |
| `eventLog()` | `event-log` | The recent-event readout. |

Stock events: `Pressed`, `Toggled`, `Picked`, `TextChanged`,
`TextCommitted`, `NumberChanged`, `MenuPicked` (plus `SelectionChanged`,
`IntChanged`). See [nim-tutorial.md](nim-tutorial.md) §9.

---

## 9. Theme

| Nim | Owl | Meaning |
| --- | --- | --- |
| `activeTheme` | `(theme)` | The live theme record. |
| `withTheme(t): body` | `set-theme record` | Push a theme for the body. |
| `pushTheme(t)` / `popTheme()` | — | Manual push/pop. |

Theme fields (`ellipse_ui/theme`): `palette` (colours), `text` (sizes),
`radii`, `metrics`, `scrollbar`. In Owl they are kebab-case records, e.g.
`(theme).palette.accent`, `(theme).metrics.pad-item`; presets in
`apps/owl-gallery/src/themes.owl`. See
[nim-tutorial.md](nim-tutorial.md) §10 for the full table.

---

## 10. Cadence & app shell

| Nim | Owl | Meaning |
| --- | --- | --- |
| `requestFrame()` | `request-frame` | Schedule another frame. |
| `refreshDue(interval)` | `refresh-due interval` | Cadence tick. |
| `invalidate()` | `invalidate` | Force a redraw. |
| `frameDelta()` | — | Seconds since the last frame. |
| `run(app)` | `run-app (title = …) (width = …) (height = …) &view` | Open the window and run the loop. |
| `quit()` | `quit-app` | Leave the loop. |
| `onClose(fn)` | `on-close fn` | Close hook. |
| `afterFrame(fn)` | `after-frame fn` | Per-frame-end hook. |
| — | `frame-error` | The last frame error, if any. |
| — | `watch-fd fd fn` / `unwatch-fd fd` | File-descriptor watching. |

See [nim-tutorial.md](nim-tutorial.md) §11–12 and
[owl-tutorial.md](owl-tutorial.md) §10.

---

## 11. Dialogs

| Nim | Owl | Meaning |
| --- | --- | --- |
| `dialog(...)` | `define-dialog name (title = …) (width = …) (max-height = …): body` | Declare. |
| `openDialog(name, fields)` | `open-dialog name fields` | Open it. |
| `dialogArgs(name)` | `dialog-args name` | Its `Fields`. |
| `dialogOpened(name)` | `dialog-opened name` | Is it open. |
| `accept()` / `cancel()` | `accept` / `cancel` | Close with a result. |
| `alert/confirm/ask/prompt/toast` | same names | The stock dialogs. |
| — | `any-dialog-open` | Is any dialog up. |
| — | `pass-enter`, `dialog-enter`, `dialog-in-window` | Enter-routing helpers. |

The `Fields` wire form is documented in
[nim-tutorial.md](nim-tutorial.md) §13.

---

## 12. The `widget` macro (Nim <-> Owl)

```nim
widget Name(param: T, ...) -> Ret:
  emits EventName
  ...
```

```
widget Name param...:
    emits EventName
    ...
```

| Modifier / form | Nim | Owl |
| --- | --- | --- |
| Focusable | `widget focusable Name(...)` | `widget focusable Name ...` |
| Return value | `-> T` | the body's last value |
| Slots | `param: proc(): void` | `&name` parameter |
| Adds `id` + `tabIndex` | automatic when `focusable` | automatic when `focusable` |

A `focusable` widget gains `id: ElementId` first and `tabIndex = 0` last, and
registers on the Tab chain before its body. See
[nim-tutorial.md](nim-tutorial.md) §5 and
[owl-tutorial.md](owl-tutorial.md) §5.
