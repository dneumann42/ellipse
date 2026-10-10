# Writing GUIs in Owl

Owl is the small S-expression-flavoured scripting language the ellipse toolkit
exposes. This tutorial covers building GUIs in Owl: the language shape you need,
the `use gui` builtin set, the `widget` form, events, themes, dialogs, and the
live-reloading app. Read [nim-tutorial.md](nim-tutorial.md) for the concepts in
depth -- this document maps each of them to Owl.

- [1. The language you need](#1-the-language-you-need)
- [2. A window and a view](#2-a-window-and-a-view)
- [3. Layout](#3-layout)
- [4. Widgets](#4-widgets)
- [5. Widgets with slots and the `widget` form](#5-widgets-with-slots-and-the-widget-form)
- [6. Events](#6-events)
- [7. Focus and keys](#7-focus-and-keys)
- [8. Themes](#8-themes)
- [9. App, dialogs and popups](#9-app-dialogs-and-popups)
- [10. Hot reloading and the repl](#10-hot-reloading-and-the-repl)
- [11. A full walkthrough](#11-a-full-walkthrough)

---

## 1. The language you need

Owl is indentation-based. A form is either a bare symbol/command call or a
parenthesised call. Zero-argument calls need the parens: `(apply-theme)`,
`(length xs)`.

```owl
use base
use gui

count = 0                       ; a binding
names = [] "Ada" "Grace"        ; a list literal
point = {}:                     ; a record literal
    x = 1
    y = 2
```

Function definitions:

```owl
fun add a b:
    + a b                       ; the last form is the value

fun label-of p:
    p.name                      ; field access
```

Control flow -- note the Owl shape: the block after `if cond:` holds the *then*
value first and the *else* value(s) after it.

```owl
if own-window:
    "window"                    ; then
    "inline"                    ; else
```

`when cond:` runs its whole block only when `cond` is true (a guard, no else).
`cond:` picks the first `(test = body)` whose test is truthy:

```owl
cond:
    (= index 1) = (light-theme)
    (= index 2) = (contrast-theme)
    true = ({})
```

`while cond:` loops; `do:` runs a block; `set name value` assigns. `with record
(field = value)` returns an updated copy:

```owl
set draft (with draft (name = "Grace"))
```

Common operations: `=`, `<>`, `<`, `>`, `<=`, `>=`, `+ - * /`, `and`, `or`,
`not`, `concat`, `to-string`, `parse`, `length`, `index`, `slice`, `find`,
`append`, `pop-front`, `char`, `is-empty`, `is-any`, `nothing`, `true`, `false`.
`{}` builds a record, `[] a b c` a list.

Reading a binding's value as an expression needs parens: `(count)`, `(draft.name)`.

---

## 2. A window and a view

```owl
use gui

count = 0

fun view:
    handle-events:
        column (padding = 24) (gap = 8) (align-x = "center"):
            text (concat "Clicked " (to-string count) " times") 32
            when (button "inc" "Increment"):
                set count (+ count 1)

run-app (title = "Counter"):
    (view)
```

- `use gui` gives the toolkit builtins (`column`, `text`, `button`, ...) and the
  Owl layer (`widget`, `run-app`).
- `run-app (title = ...) (width = ...) (height = ...) (debug = true):` opens the
  window and runs the frame loop; its block is the view, re-run every frame.
- `(view)` calls your view fun. Because it is re-evaluated every frame,
  redefining anything it calls changes the next frame.

The mental model is the same immediate mode as Nim ([nim-tutorial.md](nim-tutorial.md)):
pass a value in, store the return back:

```owl
set vsync (checkbox "cb-vsync" "VSync" vsync)
set name  (text-field "tf-name" name "Your name")
```

Run an Owl app with `owl run` from the project directory, or `owl repl` for a
live repl (see [section 10](#10-hot-reloading-and-the-repl)). The Owl build is
terminal-only unless built with SDL (`make build_owl_sdl`).

---

## 3. Layout

`row` and `column` open a container; `text` draws a label. Options are named
forms in parens; the trailing block (or `:` block) holds the children.

```owl
column (id = "root") (width = grow) (height = grow) (gap = 8) (padding = 16)
       (align-x = "center") (align-y = "top") (bg = "bg"):
    text "one"
    text "two"
```

| option | values |
| --- | --- |
| `id` | a string, for scroll targets and `focus-ring` |
| `width`, `height` | `grow`, `fit`, `(grow min max)`, `(pct f)`, or a number of pixels |
| `gap` | pixels between children |
| `padding` | a number, or a record of `left`/`right`/`top`/`bottom` |
| `align-x` | `"left"` (default), `"center"`, `"right"` |
| `align-y` | `"top"` (default), `"center"`, `"bottom"` |
| `bg`, `hover-bg` | a colour |
| `corner` | a corner radius |
| `border`, `border-color` | border width and colour |
| `clip` | `"x"`, `"y"`, `"both"` |
| `scroll` | `"x"`, `"y"`, `"both"` (a clip container fed by the wheel) |
| `focus-ring` | an element id to ring while it holds focus |

Sizing values:

```owl
grow                        ; fill leftover space
(grow 0 820)                ; fill, clamped
fit                         ; hug the content
(pct 0.5)                   ; half the parent's inner size
48                          ; 48 pixels
```

Colours are palette token names, `#rrggbb[aa]` strings, or records:

```owl
(bg = "bg")
(bg = "panel-border")
(bg = "#1c1e26")
(bg = (rgb 220 60 60))
(bg = (rgb 20 24 40 60))    ; with alpha
```

The palette tokens are `bg`, `panel`, `panel-border`, `button`, `button-hover`,
`button-press`, `field`, `selected`, `accent`, `text`, `dim`, `label`,
`on-accent`, `shadow`, and `none`/`transparent`.

Scrolling: set `(scroll = "y")` on a container and its children get the wheel
scroll offset; the floating scrollbar is drawn automatically for `column`/`row`
that scroll. `(set-scroll-position "list")` scrolls a named container from code
(add `(x = ..)`/`(y = ..)`).

`text` options:

```owl
text "hello"                       ; body size, text colour
text "big" 32
text "red" 16 (color = "accent")
text "code" (font = "mono") (wrap = false)
```

`(pad-item)`, `(hairline)`, `(panel-radius)`, `(item-radius)` are the theme
metric shorthands; `(theme)` is the whole live theme (see
[section 8](#8-themes)). Floats via the layout are produced by the toolkit
widgets; there is no separate `floating` form in the Owl surface.

---

## 4. Widgets

The stock widgets, all reachable after `use gui`:

```owl
; buttons and links -- true when activated
when (button "ok" "OK"):
    (accept)
when (button "wide" "Wide" (width = 120) (height = 40)):
    nothing
when (text-link "more" "Show more"):
    set expanded true

; toggles -- return the value to store back
set wifi  (checkbox "wifi" "Wifi" wifi)
set vsync (switch "vsync" "VSync" vsync)

; dropdowns
set backend (combo-box "backend" backends backend "Pick one")
set modules (multi-select "mods" module-names modules "None selected")

; text
set artist (text-field "artist" artist "Your name")
set notes  (multiline-field "notes" notes "Leave a note..." (rows = 3) (max-lines = 6))

; numbers
set quantity (int-number-field "qty" quantity 1 1 60)
set volume   (number-field "vol" volume 0.05 0 1)

; reading matter
heading "Widget Gallery" 1
overline "ellipse_ui on clay"
label "Small label"
body-text "A wrapped paragraph."
caption "Helper text."
badge "beta"

; structure
section "Audio":
    set volume (number-field "vol" volume 0.05 0 1)

labeled "Artist":
    set artist (text-field "artist" artist)

card "Session" (actions = tab-actions):
    body-text "Cards hug their content."

card-row:
    stat-card "Count" (to-string count) "menu or buttons"

tabbed-view "settings" tabs:
    page = (active-tab "settings")
    if (= page 0):
        ; first tab
        do:
            body-text "General"
    ; else branch follows, or use cond:
```

Positional arguments follow the Nim order (`button id label`, `combo-box id
options selected placeholder`, `number-field id value step min max`,
`text-field id text placeholder`, ...). Everything after can also be passed by
name: `(button "ok" "OK" (height = 40) (font-size = 14))`.

Menus and lists:

```owl
tool-bar "bar":
    menu "File":
        when (menu-item "Increment" "Ctrl++"):
            set count (+ count 1)
        (menu-separator)
        when (menu-item "Reset"):
            (reset-all)
    menu "View":
        when (menu-item "Intro text"):
            set show-intro (not show-intro)

list-row "rows" i:
    text (concat "Entry " (to-string i))

list-card "cards" i 150:
    text (concat "Card " (to-string i))
```

`list-row label index:` needs a body block; `list-card label index width:` too.

The editor:

```owl
set doc (code-editor "doc" doc (max-lines = 0) (font = "mono"))
```

`code-editor id text (max-lines) (read-only) (font) (wrap) (indent-after)`
returns the text to store back. `(editor-caret "doc" doc)` gives the caret byte
offset.

Keyboard and focus builtins usable in custom controls:

| `(hovered)` | `(clicked "id")` | `(activated "id")` |
| `(focused "id")` | `(gained-focus "id")` | `(pressing)` |
| `(register-focus "id" tab)` | `(set-focus "id")` | `(key-pressed "ctrl+s")` |
| `(request-frame)` | `(refresh-due (label = "x") (ms = 1000))` | `(invalidate "x")` |

`(take-key "ctrl+enter")` tests a chord and takes it out of the frame;
`(typed-text)` returns and takes this frame's typed characters.

---

## 5. Widgets with slots and the `widget` form

The `widget` form is Owl's port of the Nim `widget` macro. It rewrites a
definition into a fun whose body runs inside an event frame shared with the Nim
widgets, so Owl and Nim widgets bubble events to each other.

```owl
widget Page &body:
    column (id = "app") (width = grow) (height = grow) (align-x = "center") (bg = "bg"):
        (body)

widget Toolbar &body:
    tool-bar "toolbar" (body = body)
```

- A parameter written `&name` is the slot the call's `:` block fills; the
  parameter `body` is then callable as `(body)`. A slot left empty draws
  nothing.
- Non-slot parameters are ordinary arguments, passed positionally or by name.
- The widget gives back its body's last value, like a `fun`.
- `(widget-code Name)` prints the fun a widget became.

Call a widget with a trailing block:

```owl
Page:
    Toolbar:
        (view)
```

Or pass slots by name: `(widget-name (body = some-fun))`. The `slot` builtin is
the empty slot: `(actions = slot)`.

Focus and events:

```owl
widget focusable Counter label n:
    emits Bumped by
    row (gap = 8) (align-y = "center"):
        text (concat label ": " (to-string n))
        when (button (concat id ".more") "+1"):
            emit Bumped (by = 1)
```

- `focusable` adds an `id` parameter first and `(tab-index = 0)` last, and
  registers the widget on the Tab chain before its body runs.
- `emits Name field...` declares an event and its fields; a bare `emits Name`
  names one declared elsewhere (the stock ones, below).
- `event Name e:` sections are the widget's handlers. A handler consumes the
  event unless it calls `(reemit)`; `set e (with e (field = ...))` changes what
  is passed on.
- An `emit` of an event the widget does not declare is refused when the widget
  is defined.

---

## 6. Events

The stock events are declared for you and reach Owl handlers as records:

```
Pressed          id
Toggled          id on
Picked           id index
TextChanged      id text
TextCommitted    id text
NumberChanged    id value
IntChanged       id value
SelectionChanged id selection
MenuPicked       label
```

Catch them around a tree with `handle-events:`:

```owl
fun view:
    handle-events:
        event Bumped e:
            set count (+ count e.by)
        event Toggled e:
            when (= e.id "wifi"):
                set dirty true
        column (padding = 24):
            Counter "clicks" "Clicks" count
```

`define-event Name fields` declares a shared event at top level. `(known-event
name)` tests whether a name is a declared event. `(emit Name (field = value))`
emits; `(reemit)` passes a caught event on. The event log is `(event-log)`.

The widget return values work exactly like in Nim, so events are optional:

```owl
set vsync (checkbox "cb" "VSync" vsync)   ; enough on its own
```

---

## 7. Focus and keys

Focusable widgets (and anything you `(register-focus "id" tab)`) join the Tab
chain, which follows the HTML rules: positive indices first ascending, then
`tabIndex == 0` in layout order; negative keeps it click-focusable but off the
chain.

```owl
when (focused "artist"):
    ; this field holds focus
when (gained-focus "artist"):
    (focus-at "artist" artist)       ; select-all on arrival
when (or (clicked "chip") (activated "chip")):
    (do-chip)
```

`(set-focus "id")`, `(focus-at "id" text (pos))` move focus and the caret.
Key bindings: `(key-pressed "Ctrl+S")` is a one-off check. For keymaps, Owl
apps typically use `handle-events` plus `(take-key ...)`, or install a keymap
from the `keys.owl` library (see [nim-tutorial.md](nim-tutorial.md#8-keymaps-and-shortcuts)
for the chord syntax, which is shared).

---

## 8. Themes

`(theme)` returns the live theme as a record: `palette`, `text`, `radii`,
`metrics`, `scrollbar`. Read a token with `(theme).metrics.pad-item`,
`(theme).text.caption`, `(theme).radii.panel` (Owl spells metric names in kebab
case).

`(set-theme overrides)` starts from the default theme and applies the
differences; every widget takes it on from the next one drawn:

```owl
fun light-theme:
    {}:
        palette = {}:
            bg = rgb 244 245 248
            panel = rgb 255 255 255
            panel-border = rgb 208 212 222
            button = rgb 226 230 238
            button-hover = rgb 203 210 224
            button-press = rgb 178 187 206
            field = rgb 255 255 255
            selected = rgb 206 221 248
            accent = rgb 46 92 190
            text = rgb 24 27 34
            dim = rgb 116 122 138
            label = rgb 72 78 94
            on-accent = rgb 255 255 255
            shadow = rgb 20 24 40 60
        scrollbar = {}:
            width = 10
            margin = 4
            radius = 5
            min-thumb = 28
            track = rgb 226 229 238 150
            thumb = rgb 150 158 176 190
            thumb-hot = rgb 112 122 145 230

fun apply-theme:
    set-theme (theme-for theme-index)
```

`set-theme` accepts `palette`, `text`, `radii`, `metrics` and `scrollbar`
records. The full token names mirror `ellipse_ui/theme` in kebab case:
palette keys are the colour token names above; `text` keys are `h1`..`h6`,
`button`, `menu`, `control`, `option`, `chevron`, `card-title`, `stat-label`,
`stat-value`, `stat-hint`, `label`, `caption`, `overline`, `badge`; `radii` keys
are `button`, `field`, `check`, `tick`, `inner`, `item`, `panel`, `popover`,
`popover-shadow`, `tab`, `tab-panel`, `card`, `pill`, `switch`, `switch-knob`;
`metrics` keys are `control-height`, `toolbar-height`, `pad-button`, `pad-item`,
`pad-panel`, `border-hairline`, `gap-card`, `press-offset`, and so on.
`(rgb r g b (a = 255))` builds a colour.

The terminal uses the theme's `cells` sizes automatically (as in Nim): draw in
the terminal and the type scale, colours and radii apply while geometry comes
from the cell-tuned metrics.

---

## 9. App, dialogs and popups

`run-app` is the whole app shell. While it runs, the app serves repls on its
socket and watches the project for changes, so a saved `.owl` file reloads live.

```owl
run-app (title = "Widget Gallery") (width = 1280) (height = 720) (debug = true):
    (view)
```

Other app builtins: `(quit-app)` closes the window; `(window-title "text")` sets
the title; `(on-close f)` asks `f` before closing (return true to close);
`(after-frame f)` runs `f` after the next frame; `(watch-fd fd f)` /
`(unwatch-fd fd)` react to a descriptor between frames; `(frame-error)` is why
the last frame failed; `(use-terminal)` makes the next `gui-run` take over the
terminal; `(window-backend)` tells whether a window will open.

`(gui-run config view)` is the low-level opener `run-app` uses: `config` has
`title`, `width`, `height`, `debug`, `quiet`; `view` is called every frame.

### 9.1 Defining and opening a dialog

```owl
define-dialog "app.member"
    (title = "Add team member")
    (width = 680) (max-height = 680) (scroll = true)
    (header = ({} (enabled = true) (fullscreen = true)))
    (body = member-body)
    (footer = member-footer)

fun begin-member-form (mode = "inline"):
    open-dialog "app.member" (mode = mode) (on-done = member-done)
```

- `define-dialog name (title) (width) (max-height) (scroll) (dismissable)
  (header = {..}) (body = f) (footer = g)`. Define it at module level: a dialog
  in its own window runs the program again and that run must define it too. A
  body, footer or callback written as a bare name is looked up each time it
  runs, so redefining it from a repl changes an open dialog.
- `(header = {} (enabled) (draggable) (fullscreen) (close-button))` configures
  an inline dialog's title bar.
- `open-dialog name (args = {}) (mode = "inline" | "window") (on-done = f)
  (title)`. `on-done` receives a record: `status` (`"accepted"`,
  `"cancelled"`, `"failed"`, `"open"`), `accepted`, `answer` (which button),
  `fields`.

Inside a dialog body:

```owl
fun member-body:
    when (dialog-opened):
        set draft (blank)
        (focus-at "mf.name" draft.name)
    when (focused "mf.bio"):
        (pass-enter)                    ; Enter breaks the line here
    when (dialog-enter):                ; Enter elsewhere submits
        (submit)
    (form-body)

fun submit:
    set tried true
    when (valid):
        accept (to-fields draft) "add"

fun member-footer:
    when (text-link "mf.reset" "Reset form"):
        (reset-form)
    (spacer)
    when (button "mf.cancel" "Cancel"):
        (cancel)
    when (button "mf.submit" "Add member"):
        (submit)
```

| `(dialog-args)` | the opener's fields |
| `(dialog-opened)` | true on the dialog's first frame |
| `(dialog-enter)` | Enter was pressed this frame |
| `(pass-enter)` | let this frame's Enter reach the focused widget |
| `(dialog-in-window)` | the dialog is a window of its own |
| `(accept fields (answer = "ok"))` | close accepted |
| `(cancel)` | close cancelled |
| `(any-dialog-open)` | some dialog is up |
| `(is-dialog-process)` | this process only shows one dialog |

Dialog fields are records of strings (they cross into a dialog's own process as
text), so numbers and booleans are written and read by hand:

```owl
fun to-fields m:
    {}:
        name = m.name
        role = m.role
        admin = m.admin

fun from-fields f:
    {}:
        name = f.name
        role = (index (parse f.role) 0)
        admin = (= f.admin "1")
```

### 9.2 Quick popups

```owl
alert "The build finished." (title = "Build") (detail = "412 files, 3.1 s")
confirm "Delete the 3 selected files?" confirm-done (yes = "Delete")
ask "Save changes?" ([] "Save" "Don't save" "Cancel") ask-done (cancel-index = 2)
prompt "Name the new folder:" prompt-done (text = "Untitled")
toast "Copied to clipboard"
```

`confirm`'s callback gets true/false; `ask`'s gets the chosen index (`-1` when
dismissed); `prompt`'s gets the text. Each takes `(mode = "inline" | "window")`.

`(set-clipboard text)`, `(text-columns)`, `(scroll-into-view container element)`
and `(scroll-to-end id)` round out the text/scroll helpers.

---

## 10. Hot reloading and the repl

An Owl app reloads itself. While `run-app` is running:

- the app serves repls on its socket: from a terminal, `owl repl` then `attach`;
- a project module whose `.owl` file changes on disk is reloaded, and `live.owl`
  keeps the values of its bindings.

So editing a file and saving shows the change in the running window; from an
attached repl you can `run` statements and redefine functions live. State in
plain bindings survives a reload. This is why the gallery keeps its demo values
as top-level bindings.

`(widget-code Name)` prints the fun a `widget` became, handy in the repl;
`(known-event name)` checks whether an event is declared.

---

## 11. A full walkthrough

The Owl twin of the Nim gallery. It builds on the structure from
[section 5](#5-widgets-with-slots-and-the-widget-form).

```owl
use base
use math
use strings
use gui

count = 0
show-intro = true
vsync = true
backend = 1
artist = "Ada Lovelace"
backends = [] "OpenGL" "Vulkan" "Software"

fun draw-app:
    Scroll:
        heading "Widget Gallery" 1
        overline "ellipse_ui on clay"
        when show-intro:
            body-text "The standard widget set, all immediate-mode clay layout blocks."

        section "Toggles & buttons":
            row (id = "trow") (width = grow) (height = fit) (gap = 28) (align-y = "center"):
                set vsync (checkbox "cb-vsync" "VSync" vsync)
                when (button "btn-inc" "Increment" (height = 48)):
                    set count (+ count 1)
                badge "beta"

        section "Dropdowns":
            row (id = "drow") (width = grow) (height = fit) (gap = 16) (align-y = "top"):
                labeled "Backend":
                    set backend (combo-box "combo-backend" backends backend "Pick one")

        section "Text entry":
            labeled "Artist":
                set artist (text-field "tf-artist" artist "Your name")

        row (id = "counter") (width = grow) (height = fit) (gap = 12) (align-y = "center"):
            text (to-string count) 48
            when (button "inc" "Increment" (height = 44)):
                set count (+ count 1)

        row (id = "footer") (width = grow) (height = fit) (gap = 14) (align-y = "center"):
            when (text-link "lnk-intro" "Toggle intro"):
                set show-intro (not show-intro)

widget Page &body:
    column (id = "app") (width = grow) (height = grow) (align-x = "center") (bg = "bg"):
        (body)

widget Toolbar &body:
    tool-bar "toolbar" (body = body)

widget Scroll &body:
    column (id = "scroll") (width = grow) (height = grow) (padding = 28) (scroll = "y"):
        column (id = "content") (width = (grow 0 820)) (height = fit) (gap = 10) (align-x = "center"):
            (body)

fun view:
    Page:
        Toolbar:
            menu "File":
                when (menu-item "Increment" "Ctrl++"):
                    set count (+ count 1)
                when (menu-item "Decrement" "Ctrl+-"):
                    set count (- count 1)
            menu "View":
                when (menu-item "Intro text"):
                    set show-intro (not show-intro)
        (draw-app)

run-app (title = "Widget Gallery"):
    (view)
```

That is a complete Owl application: a scrollable page, a menu bar, immediate
mode state, the themed widget set and floating scrollbars. The shipping
`apps/owl-gallery/` is the same tour with every widget, a modal form
(`memberform.owl`) and theme presets (`themes.owl`) -- read it next, with
[reference-widgets.md](reference-widgets.md) open for signatures.
