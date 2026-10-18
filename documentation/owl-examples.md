# Owl widget & layout examples

Every widget of the toolkit, shown in Owl with several examples each, plus
layout recipes and the full story of the `widget` command. Companion to
[reference-widgets.md](reference-widgets.md) (the signature tables) and
[nim-tutorial.md](nim-tutorial.md) (the Nim walkthrough). Every block below
was run against `bin/owl` as written.

- [0. Reading the examples](#0-reading-the-examples)
- [1. App skeletons](#1-app-skeletons)
- [2. Layout: row and column](#2-layout-row-and-column)
- [3. Layout recipes](#3-layout-recipes)
- [4. Text and headings](#4-text-and-headings)
- [5. Buttons and links](#5-buttons-and-links)
- [6. Checkboxes and switches](#6-checkboxes-and-switches)
- [7. Text fields](#7-text-fields)
- [8. Number fields](#8-number-fields)
- [9. Dropdowns: combo-box and multi-select](#9-dropdowns-combo-box-and-multi-select)
- [10. Tabs](#10-tabs)
- [11. Menus](#11-menus)
- [12. List rows and cards](#12-list-rows-and-cards)
- [13. The code editor](#13-the-code-editor)
- [14. Composite widgets](#14-composite-widgets)
- [15. Scrolling](#15-scrolling)
- [16. Focus and the keyboard](#16-focus-and-the-keyboard)
- [17. Interaction primitives](#17-interaction-primitives)
- [18. Events](#18-events)
- [19. The theme](#19-the-theme)
- [20. Dialogs](#20-dialogs)
- [21. Cadence and the app shell](#21-cadence-and-the-app-shell)
- [22. The `widget` command](#22-the-widget-command)
- [23. A complete app](#23-a-complete-app)

---

## 0. Reading the examples

Every GUI file starts from the same preamble. `use gui` brings the toolkit
builtins and the `widget` / `run-app` layer:

```owl
use io
use base
use math
use strings
use gui
```

Add `use iterators` when you want the `for` loops of § 12:

```owl
use iterators
```

A handful of shapes repeat in every example:

**State is a plain binding, input widgets are a round trip.** Pass the value
in, store the return back, every frame:

```owl
volume = 0.4

set volume (number-field "vol" volume (step = 0.05) (min = 0) (max = 1))
```

**Everything draws inside a view fun, called every frame:**

```owl
fun view:
    column (width = grow) (height = grow) (padding = 24) (gap = 16):
        heading "Notes" 1

run-app (title = "Notes") (width = 900) (height = 640):
    (view)
```

**Command style vs. paren calls.** Widgets read as bare lines with plain
arguments and `(name = value)` options; as a value inside another call, wrap
them in parentheses:

```owl
button "ok" "OK" (width = grow)
again = (button "inc" "+1")
when again:
    echo "one more"
```

...and **zero-argument functions are always parenthesized** — a bare word on
a line of its own is just read as a value, it does not call:

```owl
(spacer)
(theme)
(quit-app)
```

**Colours** are palette names, hex, or `(rgb r g b (a = 255))`:

```owl
row (bg = "panel") (border-color = "#ff0000"):
    text "accent" (color = "accent")
text "translucent" (color = (rgb 0 0 0 (a = 128)))
```

The palette names: `bg`, `panel`, `panel-border`, `button`, `button-hover`,
`button-press`, `field`, `selected`, `accent`, `text`, `dim`, `label`,
`on-accent`, `shadow`.

**Sizes** for `width` / `height` are: a bare number of pixels (Owl has no
`(fixed n)` form — the number *is* fixed pixels), `grow`, `fit`, or
`(pct f)`:

```owl
column (width = 220) (height = grow)
row (width = (pct 0.5)) (height = 48)
column (width = (grow (min = 120) (max = 400)))
```

**Conditionals**, since the examples lean on them (`when` = statement,
`if` = first block form is *then*, the rest is *else*, `do:` groups several
forms into one branch, `cond:` is a match ladder):

```owl
when (button "b" "Go"):
    echo "pressed"

answer = if ready:
    "yes"
    "no"

cond:
    (= tab 0) = text "General"
    (= tab 1) = text "Appearance"
    true = text "Other"
```

**Indexing gotcha:** `index` treats a bare symbol key as a *name*. For list
positions, force the number: `(index xs (+ i 0))`.

---

## 1. App skeletons

The smallest app that opens a window and quits:

```owl
use base
use gui

fun view:
    column (width = grow) (height = grow) (padding = 24):
        when (button "bye" "Goodbye"):
            (quit-app)

run-app (title = "Hello"):
    (view)
```

State, an event round trip through `handle-events`, and a `widget` of your
own — the same three files `owl new notes --gui` scaffolds for you:

```owl
use io
use base
use math
use strings
use gui

clicks = 0
dark = true

widget Counter id label n:
    emits Bumped by
    row (gap = 12) (align-y = "center"):
        text (concat label ": " (to-string n))
        when (button (concat id ".more") "+1"):
            emit Bumped (by = 1)

fun view:
    handle-events:
        event Bumped e:
            set clicks (+ clicks e.by)
        column (width = grow) (height = grow) (padding = 24) (gap = 16):
            heading "Notes" 1
            Counter "c" "Clicks" clicks
            set dark (switch "dark" "Dark" dark)

run-app (title = "Notes"):
    (view)
```

Running things:

```sh
# from a shell
owl new notes --gui      # scaffold project.owl + src/main.owl + src/widgets.owl
cd notes && owl run      # hot reload: save a file and the next frame takes it
owl run main.owl         # or a bare file, anywhere
owl repl                 # a session you can drive
```

---

## 2. Layout: row and column

`row` lays children left to right, `column` top to bottom. Both take the same
options and a `:` block of children.

The two directions:

```owl
row (gap = 8):
    label "First"
    label "Second"

column (gap = 4) (padding = 12):
    label "One"
    label "Two"
```

Named (repeatable) or anonymous containers; a container with an id can be
scrolled, focused and found again:

```owl
column "sidebar" (width = 220) (height = grow) (gap = 8):
    label "Menu"

row (width = grow) (height = 40):
    label "Anonymous: laid out by position"
```

**Gap and padding.** Padding takes one number, `[x y]`, `[left right top
bottom]`, or a record:

```owl
column (gap = 16) (padding = 12):
    label "even padding"

row (padding = [] 8 24):
    label "x = 8, y = 24"

row (padding = [] 12 20 8 4):
    label "l r t b"

row (padding = ({} (left = 12) (right = 20) (top = 8) (bottom = 4))):
    label "record"
```

**Sizing axes** on `width` / `height`:

```owl
column (width = grow) (height = grow):
    label "fills the parent"

column (width = fit):
    label "hugs its content (the default)"

column (width = 240) (height = 120):
    label "exactly 240 x 120 pixels"

column (width = (pct 0.5)):
    label "half the parent"

column (width = (grow (min = 200)) (height = (fit (min = 40) (max = 120)))):
    label "with bounds"
```

**Alignment** for the whole block:

```owl
row (width = grow) (height = 120) (align-x = "center") (align-y = "center"):
    label "centered both ways"

row (width = grow) (align-x = "right"):
    label "pushed right"
```

(`align-x`: `"left" | "center" | "right"`, `align-y`: `"top" | "center" |
"bottom"`.)

**Decoration** — fill, rounded corners, borders, hover tint:

```owl
column (padding = 16) (bg = "panel") (corner = 8):
    label "a rounded panel"

row (padding = 8) (bg = "#20242e") (border = 1) (border-color = "panel-border"):
    label "with a hairline border"

column (gap = 4) (padding = 10) (bg = "field") (hover-bg = "button"):
    label "this whole block tints while the pointer is inside"
```

**Clipping and scrolling** (§ 15 has the scroll helpers):

```owl
column "clip-me" (height = 100) (clip = "y"):
    label "children beyond 100 px are cut off"

column "scroll-me" (height = 240) (scroll = "y"):
    label "scrollable: with an id, a floating scrollbar"
    label "is attached automatically at <id>.bar"

column (scroll = "both") (width = grow) (height = grow):
    label "both axes, no scrollbar (no id)"
```

(`clip` / `scroll`: `true` (= y), `"x"`, `"y"`, `"both"`.)

**Focus rings** — draw a keyboard ring tied to some widget's id:

```owl
row (gap = 8) (focus-ring = "target"):
    button "target" "Tab to me"
```

**`spacer`** pushes what follows to the far edge:

```owl
row (width = grow):
    label "left"
    (spacer)
    label "right"
```

---

## 3. Layout recipes

**Sidebar + main pane** — a row of two columns:

```owl
fun shell:
    row (width = grow) (height = grow) (gap = 0):
        column (width = 220) (height = grow) (padding = 12) (gap = 10) (bg = "panel"):
            overline "navigation"
            label "Home"
            label "Search"
        column (width = grow) (height = grow) (padding = 24) (gap = 16):
            heading "Main" 1

(shell)
```

**Header bar with actions at the right edge** (`spacer` + slot, see § 22):

```owl
row "top" (width = grow) (height = 56) (padding = [] 16 8) (gap = 12) (align-y = "center") (bg = "panel"):
    heading "Report" 1
    (spacer)
    button "refresh" "Refresh"
    button "export" "Export"
```

**A form: labels above fields** (`labeled`, § 14, inside a column):

```owl
column (width = grow) (gap = 10) (padding = 16):
    labeled "Name":
        set name (text-field "name" name (placeholder = "Ada"))
    labeled "Email":
        set email (text-field "email" email (placeholder = "ada@example.com"))
    row (gap = 8) (align-x = "right") (width = grow):
        button "cancel" "Cancel"
        button "save" "Save"
```

**A settings page that scrolls:**

```owl
column "settings" (scroll = "y") (width = grow) (height = grow) (padding = 24) (gap = 16):
    heading "Settings" 1
    section "General":
        column (gap = 8) (width = grow):
            set dark (switch "dark" "Dark theme" dark)
            set lang (combo-box "lang" ([] "English" "German") lang)
    section "Editor":
        column (gap = 8) (width = grow):
            set size (int-number-field "size" size (min = 8) (max = 32))
```

**A dashboard row of stat cards** (`card-row` equalises widths):

```owl
card-row:
    stat-card "Members" (to-string (length people)) (hint = "in the team")
    stat-card "Active" "42" (hint = "right now")
    stat-card "Uptime" "3 d 4 h"
```

**A hoverable list** — a scrolling column of `list-row`s:

```owl
column "member-list" (scroll = "y") (width = grow) (height = 140) (gap = 4):
    for i (range (length people)):
        list-row "member" i:
            row (gap = 8) (padding = 6) (width = grow):
                badge (to-string i)
                text (index people (+ i 0))
                (spacer)
                caption "online"
```

**A centered card** — grow both axes on the shell and let the card fit:

```owl
column (width = grow) (height = grow) (align-x = "center") (align-y = "center"):
    card "Sign in":
        column (width = 280) (gap = 8):
            set user (text-field "user" user (placeholder = "user"))
```

---

## 4. Text and headings

Static text. `label` is a field caption, `body-text` a paragraph, `caption`
and `overline` small texts, `badge` a pill, `heading` levels 1–6, and `text`
the raw leaf with full control:

```owl
label "Name"
body-text "A longer paragraph that wraps to the column's width."
caption "hint text under a field"
overline "section eyebrow"
badge "beta"
```

Headings by level — positional or named:

```owl
heading "Chapter one" 1
heading "Chapter two" (level = 2)
```

`text` takes size, colour, font and wrap:

```owl
text "plain"
text "big dim" (size = 20) (color = "dim")
text "0x4f7c9c" (font = "mono") (size = 13)
text "this line will not wrap" (wrap = false)
```

A title block built from them:

```owl
column (gap = 2):
    overline "release"
    heading "Ellipse 0.4" 2
    caption "ships the owl GUI layer"
    badge "new"
```

---

## 5. Buttons and links

`button id label` returns `true` on the press and emits `Pressed`:

```owl
when (button "save" "Save"):
    (save-note)

row (gap = 8) (align-y = "center"):
    button "wide" "Grow with the row" (width = grow)
    button "tall" "Taller" (height = 44) (font-size = 14)
    button "tabbed" "First in tab order" (tab-index = 1)
```

A button that changes state — store the round trip:

```owl
count = 0

when (button "inc" "Count up"):
    set count (+ count 1)
badge (to-string count)
```

`text-link id text` — an inline hyperlink, `true` when clicked, also emits
`Pressed`:

```owl
when (text-link "more" "show more"):
    set expanded true
```

---

## 6. Checkboxes and switches

Both are round trips and emit `Toggled`:

```owl
wifi = true
sync = false

set wifi (checkbox "wifi" "Wifi" wifi)
set sync (switch "sync" "Sync" sync)
```

A settings column combining them with a number field:

```owl
column (gap = 8) (width = grow):
    set dark (switch "dark" "Dark theme" dark)
    set beep (checkbox "beep" "Click sounds" beep)
    when sync:
        set delay (int-number-field "delay" delay (min = 1) (max = 60))
```

A row that reacts to its own state:

```owl
set wifi (checkbox "wifi" "Wifi" wifi)
when wifi:
    caption "connected"
```

---

## 7. Text fields

`text-field id text` — a single-line editor. Enter commits: the new text is
the return value, and `TextChanged` fires per keystroke, `TextCommitted` on
Enter:

```owl
name = ""

set name (text-field "name" name (placeholder = "Your name"))
```

Sizing and tab order:

```owl
set query (text-field "query" query (placeholder = "Search") (width = 240) (tab-index = 2))
```

Acting on the commit instead of per keystroke:

```owl
handle-events:
    event TextCommitted e:
        when (= e.id "search"):
            run-search e.text
    set query (text-field "search" query (placeholder = "Search"))
```

`multiline-field` — several rows, Enter inserts a newline, leaving the field
commits:

```owl
notes = ""

set notes (multiline-field "notes" notes (placeholder = "Scratchpad") (rows = 4) (max-lines = 20))
```

A compact variant inside a form row:

```owl
row (gap = 8) (width = grow):
    labeled "Comment":
        set comment (multiline-field "comment" comment (rows = 2) (max-lines = 6) (width = 260))
```

---

## 8. Number fields

`number-field` is a float with steppers:

```owl
volume = 0.4

set volume (number-field "vol" volume (step = 0.05) (min = 0) (max = 1))
```

Positional form: `number-field id value step min max`:

```owl
set price (number-field "price" price 0.10 0 100)
```

`whole = true` clamps input to integers, and `int-number-field` is the plain
integer variant:

```owl
set qty (int-number-field "qty" qty (step = 1) (min = 0) (max = 99))
set pct-done (number-field "pct" pct-done (step = 5) (min = 0) (max = 100) (whole = true))
```

Both emit `NumberChanged` / `IntChanged`:

```owl
handle-events:
    event NumberChanged e:
        set last-value e.value
    set volume (number-field "vol" volume (min = 0) (max = 1))
```

---

## 9. Dropdowns: combo-box and multi-select

`combo-box id options selected` returns the chosen index (`-1` = nothing
chosen, the placeholder shows):

```owl
formats = ([] "PNG" "JPEG" "WebP")
fmt = -1

set fmt (combo-box "fmt" formats fmt (placeholder = "Pick a format"))
when (<> fmt -1):
    caption (concat "picked: " (index formats (+ fmt 0)))
```

Sizing and tab order:

```owl
kinds = ([] "Note" "Task" "Journal")
kind = 0

set kind (combo-box "kind" kinds kind (width = 180) (tab-index = 3))
```

A default of `-1` means "nothing picked yet":

```owl
when (button "convert" "Convert"):
    when (= fmt -1):
        alert "Choose a format first"
```

`multi-select id options selection` — `selection` is a **list of chosen
indices**, and so is the return value (it emits `SelectionChanged`):

```owl
tags = ([] "urgent" "later" "archive")
picks = ([] 0)

set picks (multi-select "tags" tags picks (placeholder = "Tags..."))
caption (concat (to-string (length picks)) " selected")
```

Summarising the chosen labels:

```owl
fun summary chosen:
    out = ""
    for p (items chosen):
        set out (concat out (index tags (+ p 0)) " ")
    out
```

---

## 10. Tabs

`tab-strip id labels selected` is the strip alone — the bar of tabs,
returning the new index:

```owl
tab = 0

set tab (tab-strip "views" ([] "Files" "Search" "Preview") tab)
```

`tabbed-view id tabs:` draws the strip *and* the panel; the body reads the
current index with `(active-tab id)`:

```owl
tabbed-view "settings" ([] "General" "Appearance"):
    at = (active-tab "settings")
    cond:
        (= at 0) = text "The general tab"
        true = text "The appearance tab"
```

A tabbed view whose panels are separate funs:

```owl
fun general-panel:
    column (gap = 8) (width = grow):
        label "General stuff here"

fun appearance-panel:
    column (gap = 8) (width = grow):
        label "Theme controls"

tabbed-view "prefs" ([] "General" "Appearance" "Advanced"):
    which = (active-tab "prefs")
    cond:
        (= which 0) = (general-panel)
        (= which 1) = (appearance-panel)
        true = text "No advanced settings yet"
```

---

## 11. Menus

`tool-bar id:` opens the menu bar; `menu label:` holds one dropdown;
`menu-item label (shortcut = ...)` returns `true` when picked and emits
`MenuPicked`; `(menu-separator)` is the rule between items:

```owl
tool-bar "file":
    menu "File":
        menu-item "New" (shortcut = "ctrl+n")
        menu-item "Open..."
        (menu-separator)
        menu-item "Quit"
    menu "View":
        menu-item "Zoom in"
        menu-item "Zoom out"
```

Acting on items right where they are declared:

```owl
tool-bar "edit":
    menu "Edit":
        when (menu-item "Copy"):
            (set-clipboard doc)
        when (menu-item "Delete"):
            (delete-current)
        menu-item "Redo" (shortcut = "ctrl+y")
```

Or catch the stock event once, at the app level:

```owl
handle-events:
    event MenuPicked e:
        cond:
            (= e.label "Quit") = (quit-app)
            true = echo e.label
    tool-bar "file":
        menu "File":
            menu-item "Quit"
```

---

## 12. List rows and cards

`list-row label index:` is a themed hover row — one item of a list panel.
`label` + `index` give it a stable id across frames (`localIdWithIndex`):

```owl
column "member-list" (scroll = "y") (width = grow) (height = 160) (gap = 4):
    for i (range (length people)):
        list-row "member" i:
            row (concat "member-row-" (to-string i)) (gap = 8) (padding = 6) (width = grow):
                badge (to-string i)
                text (index people (+ i 0))
                (spacer)
                when (text-link (concat "kick-" (to-string i)) "kick"):
                    remove-person i
```

Inside one you lay out freely — a two-line row:

```owl
list-row "song" i:
    column (gap = 2) (padding = 6) (width = grow):
        label (index titles (+ i 0))
        caption (index artists (+ i 0))
```

`list-card label index (width = ...)` is the card version for horizontal
strips (default width 150 px):

```owl
row (gap = 8) (clip = "x"):
    for i (range (length team)):
        list-card "team" i (width = 200):
            column (gap = 4) (width = grow):
                label (index team (+ i 0))
                badge "member"
```

---

## 13. The code editor

`code-editor id text` is a scrollable document area with selection, caret,
drag, undo and Emacs keys. Store the text back every frame (Owl strings have
no escapes — keep buffer defaults simple):

```owl
doc = "fun hello: echo hi"

set doc (code-editor "doc" doc)
```

Monospaced, no wrap. The editor scrolls its own document, so a fixed-height
box frames it:

```owl
column (width = grow) (height = 300):
    set doc (code-editor "doc" doc (font = "mono") (wrap = false))
```

The remaining options: `max-lines`, `read-only`, and `indent-after` (a
trailing character that indents the next line like the one above):

```owl
set scratch (code-editor "scratch" scratch (max-lines = 5000))
set output (code-editor "output" output (read-only = true))
set cfg (code-editor "cfg" cfg (font = "mono") (indent-after = "{"))
```

Helpers around it — caret, keys taken before widgets, clipboard, width:

```owl
caret = (editor-caret "doc" doc)          ; byte offset of the caret
when (take-key "ctrl+enter"):             ; true once, and the key is eaten
    run-buffer doc
typed = (typed-text)                       ; text typed this frame, chords excluded
(set-clipboard doc)                        ; system clipboard (OSC 52 in a terminal)
cols = (text-columns)                      ; monospace columns that fit the window
```

A tiny console — feed typed text into the buffer, then pin the view to the
bottom as output arrives:

```owl
column (width = grow) (height = grow):
    typed = (typed-text)
    when (<> typed ""):
        set doc (concat doc typed)
    set doc (code-editor "term" doc (font = "mono") (wrap = false))
    scroll-to-end "term"
```

---

## 14. Composite widgets

**`card title:`** — a framed panel with a title row. Give it an `actions`
fun, or a `(body = fun)`:

```owl
card "Account":
    body-text "Sign in to continue."

fun account-actions:
    when (button "acct-refresh" "Refresh"):
        (reload-account)

card "Account" (actions = account-actions):
    label "ada@example.com"

fun account-body:
    label "ada@example.com"

card "Account" (body = account-body)
```

**`stat-card label value (hint = ...)`** — a big-number panel (values are
text):

```owl
stat-card "Members" "1 204" (hint = "+12 today")
stat-card "Uptime" "3 d 4 h"
```

**`card-row:`** — a row of cards that share widths:

```owl
card-row:
    stat-card "Open" (to-string (length open-items))
    stat-card "Done" (to-string done-count) (hint = "this week")
```

**`section title:`** — a heading-2 group:

```owl
section "Goals":
    column (gap = 6) (width = grow):
        label "Ship ellipse 0.4"
        label "Write the owl tutorial"
```

**`prose:`** — a comfortable reading column:

```owl
prose:
    heading "Design notes" 2
    body-text "Immediate mode means the view runs every frame..."
    caption "see the nim tutorial for the model"
```

**`labeled label:`** — a small field label above its control:

```owl
labeled "Name":
    set name (text-field "name" name)

fun email-field:
    set email (text-field "email" email (placeholder = "you@example.com"))

labeled "Email" (control = email-field)
```

Composing them — a settings card in a section:

```owl
section "Preferences":
    card "Editor":
        column (gap = 8) (width = grow):
            labeled "Font size":
                set size (int-number-field "size" size (min = 8) (max = 32))
            set mono (switch "mono" "Monospace" mono)
```

---

## 15. Scrolling

`(scroll = ...)` on a container makes it scroll (and attaches a floating
scrollbar when the container has an id — the bar lives at `<id>.bar`):

```owl
column "log" (scroll = "y") (width = grow) (height = 200):
    for line (items lines):
        text line
```

`(clip = ...)` clips without scrollbars (drive it with the helpers or add
your own bar):

```owl
column (clip = "both") (width = grow) (height = 160):
    label "content beyond the box is cut off, no bars"
```

Scroll programmatically. Positions are pixels and negative is down (`0` is
the top, `-1000000000` clamps to the end):

```owl
set-scroll-position "log" (x = 0) (y = 0)      ; to the top
set-scroll-position "log" (y = -400)           ; 400 px down
set-scroll-position "log" (y = -1000000000)    ; the very end
```

`scroll-to-end id` is the one-liner for the bottom (a terminal follows new
output), and `scroll-into-view container element` pulls a child into sight:

```owl
when (> (length lines) 0):
    text (index lines 0)
    scroll-to-end "log"

scroll-into-view "member-list" "member-row-7"
```

Both in a chat-style pane:

```owl
column "chat" (scroll = "y") (width = grow) (height = grow):
    for i (range (length messages)):
        row (concat "msg-" (to-string i)):
            text (index messages (+ i 0))
when (new-message):
    scroll-to-end "chat"
```

---

## 16. Focus and the keyboard

Ask whether an id holds focus, move focus, or check edge events:

```owl
focused "save"                 ; is it the focus target right now
(gained-focus "save")          ; ...did focus arrive this frame
activated "save"               ; Enter/Space pressed while it holds focus
```

Move focus yourself:

```owl
set-focus "save"
```

Put a custom element on the Tab chain (negative tab-index: click-focusable
but off the chain):

```owl
register-focus "zone" 2
row "zone" (focus-ring = "zone") (width = grow) (height = 60):
    label "a custom focusable region"
when (activated "zone"):
    echo "zone activated by keyboard"
```

Send focus into a text field, caret at a position (`pos` defaults to the
end):

```owl
when (button "edit-name" "Edit name"):
    focus-at "name" name (pos = 0)
```

Read the keyboard. `key-pressed` matches a chord held this frame; widgets
still see the key:

```owl
when (key-pressed "ctrl+s"):
    (save-file)
when (key-pressed "enter"):
    (commit-search)
```

...while `take-key` (§ 13) matches and *removes* the chord so no widget
drawn after it can see the same press.

Enter-routing in dialogs: `(dialog-enter)` is the dialog's "default button
was asked for"; `(pass-enter)` hands this frame's Enter back to the focused
widget (a multiline field inserts a newline instead):

```owl
when (dialog-enter):
    accept ({} (text = draft))
```

---

## 17. Interaction primitives

Reads about the pointer, against the open element or a named id:

```owl
(hovered)              ; pointer is over whichever element is open now
hovered "zone"         ; ...or over that id
clicked "zone"         ; a click completed on it this frame
pressing "zone"        ; the button is held down on it
```

A drop zone that reacts in place:

```owl
row "zone" (width = grow) (height = 60) (bg = "panel") (hover-bg = "button") (corner = 8):
    when (pressing "zone"):
        text "pressing..."
    when (hovered "zone"):
        text "hovered"
    text "press or hover this panel"
when (clicked "zone"):
    (toast "you clicked the panel")
```

A card that shows a menu button only while hovered:

```owl
column "file-card" (gap = 4) (padding = 12) (bg = "panel") (hover-bg = "button"):
    label "report.pdf"
    when (hovered "file-card"):
        when (button "file-card.menu" "⋯"):
            (open-file-menu)
```

`hovered` with no id works inside the element the pointer is over — in a
row's own block:

```owl
row (padding = 8):
    when (hovered):
        text "pointer here"
```

---

## 18. Events

Widgets emit typed events that bubble up through the frames around them.
`handle-events:` opens a catching frame; `event Name e:` sections are its
handlers, everything after them is the framed body:

```owl
handle-events:
    event Bumped e:
        set clicks (+ clicks e.by)
    column (width = grow):
        Counter "c" "Clicks" clicks
```

Custom events are records with named fields — declare them with
`define-event`:

```owl
define-event "Searched" ([] "term")

when (button "go-search" "Search"):
    emit Searched (term = query)
```

`emit` returns `true` when some frame above consumed the event, and handlers
see the stock payloads as records (`Toggled` has `id` and `on`, `Picked` has
`id` and `index`, `TextChanged` / `TextCommitted` carry `text`,
`MenuPicked` a `label`...):

```owl
handle-events:
    event Toggled e:
        echo (concat e.id " -> " (to-string e.on))
    set wifi (checkbox "wifi" "Wifi" wifi)
```

A handler consumes unless it says otherwise — `(reemit)` passes the event on
(changed or not; inside a widget's `event` section a bare `reemit` line is
rewritten to the call):

```owl
handle-events:
    event Picked e:
        echo "the outer frame sees it after the reemit"
    handle-events:
        event Picked e:
            echo "the inner one, passing it on"
            (reemit)
        set fmt (combo-box "fmt" formats fmt)
```

What a frame passed over is visible without handlers:

```owl
column (gap = 4):
    for r (items (event-log)):
        row (gap = 8):
            badge r.name
            caption (concat "passed " (to-string r.passed) " handled by " (to-string r.handled))
```

Stock events the widgets already emit: `Pressed`, `Toggled`, `Picked`,
`TextChanged`, `TextCommitted`, `NumberChanged`, `IntChanged`,
`SelectionChanged`, `MenuPicked`. Declare your own with `define-event`, or
inside a widget with `emits` (§ 22).

---

## 19. The theme

`(theme)` is the live theme as nested records — palette, text sizes, radii,
metrics and scrollbar, kebab-cased:

```owl
text "accent" (color = (theme).palette.accent)
caption (concat "pad = " (to-string (theme).metrics.pad-item))
row (height = (theme).metrics.control-height) (bg = "panel"):
    label "one control tall"
```

gui.owl exports short helpers for the hot tokens:

```owl
column (padding = (pad-item) (gap = (hairline))):
    label "sized by theme tokens"
```

(`pad-item`, `hairline`, `panel-radius`, `item-radius`.)

`set-theme record` replaces the theme with the default plus your overrides —
call it at startup, or swap presets from a control (a preset is only the
differences):

```owl
fun warm-preset:
    {} (palette = ({} (bg = "#151219") (accent = (rgb 232 179 57)))) (metrics = ({} (pad-item = 9)))

when (button "theme.warm" "Warm preset"):
    set-theme (warm-preset)
when (button "theme.reset" "Reset"):
    (set-theme)
```

Every section you can override matches the reference table — `palette`
(colours), `text` (sizes `h1`...`badge`), `radii` (`button`...`switch-knob`),
`metrics` (`control-height`...`press-offset`), `scrollbar` (`width`,
`margin`, `radius`, `min-thumb`, `track`, `thumb`, `thumb-hot`):

```owl
set-theme ({} (text = ({} (control = 15))) (radii = ({} (panel = 10))) (scrollbar = ({} (width = 10) (thumb = "dim"))))
```

Colours in themes and widgets accept the same three forms — a palette name,
hex, or `(rgb r g b (a = ...))`:

```owl
row (bg = (rgb 30 40 60) (border-color = "#3a3f4c") (border = 1) (corner = (panel-radius))):
    text "custom fill" (color = "#ffffff")
```

---

## 20. Dialogs

Declare a dialog at module level (`define-dialog`), open it from anywhere
(`open-dialog`), close it from inside (`accept` / `cancel`):

```owl
draft = ""

fun rename-body:
    when (dialog-opened):
        set draft ((dialog-args).name)
    column (padding = 16) (gap = 12) (width = grow):
        heading "Rename file" 2
        labeled "New name":
            set draft (text-field "rename-field" draft (placeholder = "name"))
        when (dialog-enter):
            accept ({} (name = draft)) (answer = "rename")
        row (gap = 8):
            (spacer)
            when (button "rename-ok" "Rename"):
                accept ({} (name = draft)) (answer = "rename")
            when (button "rename-cancel" "Cancel"):
                (cancel)

fun rename-footer:
    caption "Enter renames, Escape cancels"

fun renamed r:
    when r.accepted:
        set file-name r.fields.name

define-dialog "rename" (title = "Rename file") (width = 420) (scroll = true) (header = ({} (draggable = true) (close-button = true))) (body = rename-body) (footer = rename-footer)

when (button "rename-open" "Rename file..."):
    open-dialog "rename" (args = ({} (name = file-name))) (title = "Rename") (on-done = renamed)
```

Notes on the shapes:

- `args` is a record of strings/numbers/booleans/lists; `dialog-args` reads
  it inside the body. `dialog-opened` is true on the body's first frame —
  the moment to seed local state.
- `accept ({} (name = draft)) (answer = "rename")` closes with fields and a
  one-word answer; `(cancel)` closes cancelled.
- `on-done` receives the result record: `status` (`"open"`, `"accepted"`,
  `"cancelled"`, `"failed"`), `accepted`, `answer`, `fields`.
- `mode` is `"inline"` (inside the app window, the default) or `"window"`
  (its own window — the dialog is a second run of your program, so keep the
  `define-dialog` at module level).
- The body's funs are late-bound by name: redefine them from `owl repl` and
  an open dialog takes them on.

The stock dialogs cover the small cases — typically fired from a click or a
menu item:

```owl
fun do-delete yes:
    when yes:
        echo "deleted"

fun do-pick i:
    echo (concat "button " (to-string i))

fun got-name t:
    set name t

fun after-save r:
    echo r.status

row (gap = 8):
    when (button "btn.alert" "Alert"):
        alert "Saved" (title = "Done") (detail = "3 files written") (on-done = after-save)
    when (button "btn.confirm" "Confirm"):
        confirm "Delete this?" (on-answer = do-delete) (yes = "Delete") (no = "Keep")
    when (button "btn.ask" "Ask"):
        ask "Pick a colour" ([] "Red" "Green" "Blue") (on-answer = do-pick) (title = "Colour") (cancel-index = -1)
    when (button "btn.prompt" "Prompt"):
        prompt "Your name" (on-text = got-name) (text = name) (placeholder = "Ada")
    when (button "btn.toast" "Toast"):
        toast "Copied to clipboard" (seconds = 2)
```

Callbacks: `on-answer` gets `true`/`false` (confirm) or the button index
(ask), `on-text` the string (prompt), `on-done` the result record (alert,
`confirm` accepts it too when you give the names).

Query helpers:

```owl
when (any-dialog-open):
    caption "a dialog is up — the view keeps drawing behind it"
inside-window = (dialog-in-window)
is-dialog-run = (is-dialog-process)
```

In a dialog holding a multiline field, hand Enter to the field instead of
the default button:

```owl
when (and (dialog-enter) (focused "body")):
    (pass-enter)
multiline-field "body" draft (rows = 5)
```

---

## 21. Cadence and the app shell

The loop only runs frames someone asked for.

`request-frame` schedules the next one (anything a widget does — a click,
typing — asks automatically):

```owl
when (button "again" "Redraw now"):
    (request-frame)
```

`refresh-due label ms` is the cadence tick — true on the first frame and
every `ms` after, and it wakes the loop by itself:

```owl
ticks = 0

when (refresh-due "clock" 1000):
    set ticks (+ ticks 1)
badge (concat "ticks: " (to-string ticks))
```

`invalidate` forces a redraw (optionally by label), `after-frame` runs a fun
once the current frame has finished, `frame-error` is the last frame's error
message (an Owl view that throws shows the error over the window and the
next frame tries again):

```owl
(invalidate "clock")

fun paint-done:
    set painted true
(after-frame paint-done)

err-text = (frame-error)
when (<> err-text nothing):
    badge "the last frame failed — fix the source"
```

The shell itself. `run-app` opens the window and runs until it closes:

```owl
run-app (title = "Notes") (width = 900) (height = 640):
    (view)
```

Retarget the title bar from the view, and ask before the person closes the
app — `on-close` runs your fun first and closes only when it returns `true`
(`on-close nothing` restores the plain behaviour):

```owl
window-title (concat "Notes — " (to-string (length open-items)))

fun ask-first:
    toast "use File > Quit to leave"
    false

on-close ask-first
```

`(quit-app)` leaves the loop from anywhere — the close button, a menu item,
or the `Ctrl+Q` of a terminal app:

```owl
when (key-pressed "ctrl+q"):
    (quit-app)
```

`gui-run config view` is the raw form `run-app` wraps, and
`window-backend` / `use-terminal` pick window vs. terminal rendering:

```owl
echo (concat "a window is possible: " (to-string (window-backend)))
(use-terminal)
gui-run ({} (title = "Raw") (width = 800) (height = 600)) view
```

`watch-fd fd f` runs a fun between frames whenever a file descriptor turns
readable (each callback triggers a frame too) — the hook for pipes and
sockets in a terminal app; `unwatch-fd fd` removes it:

```owl
watch-fd fd poll-process
```

---

## 22. The `widget` command

`widget` is Owl's port of the Nim `widget` macro. It rewrites a definition
into a fun whose body runs inside its own event frame — so a widget can
declare events, catch its children's events, and hand a return value back,
exactly like the stock widgets.

```text
widget Name param...:
    emits Event field...       ; optional: declare + emit permission
    event Name e: ...          ; optional: catch a child's event
    body...                    ; the last value is the widget's return
```

Call it like any command — bare for statements, parenthesized for values.

### A first widget

```owl
widget Hello whom:
    row (gap = 8) (padding = 6) (bg = "panel") (corner = 6):
        overline "greeting"
        label whom

Hello "Ada"
```

### Parameters and defaults

Defaults are `(name = value)` pairs; callers pass them named or by
position:

```owl
widget Meter name (value = 0.0) (max = 100.0):
    row (gap = 8) (align-y = "center"):
        label name
        row (width = grow) (height = 10) (bg = "field") (corner = 5):
            row (width = (* 200.0 (/ value max))) (height = 10) (bg = "accent") (corner = 5)

Meter "Disk" (value = 42.0)
Meter "Ram" 63.5 128.0
```

### Returning a value

The body's last value is the return — collect into a local and end on it:

```owl
widget YesNo question:
    pick = nothing
    row (gap = 8):
        label question
        when (button "yesno.yes" "Yes"):
            set pick true
        when (button "yesno.no" "No"):
            set pick false
    pick

answer = nothing
set answer (YesNo "Are you sure?")
when (<> answer nothing):
    caption (concat "answer: " (to-string answer))
```

### Slots: `&name` parameters

A parameter written `&name` is a slot: the caller's `:` block, or a named
fun. Call it with `(name)`. Omitted, it draws nothing (the slot defaults to
the exported `slot` fun):

```owl
widget Panel title &body:
    card title:
        (body)

Panel "About this demo":
    body-text "Everything here is inside the caller's block."
    caption "a block with two forms"

fun settings-body:
    label "the same content as a named fun"

Panel "Settings" (body = settings-body)
Panel "Nothing at all"
```

Slots are what let widgets compose widgets:

```owl
widget HeaderBar text &actions:
    row (width = grow) (height = 56) (padding = [] 16 8) (gap = 12) (align-y = "center") (bg = "panel") (corner = 8):
        heading text 1
        (spacer)
        (actions)

fun copy-note:
    when (button "copy" "Copy"):
        (set-clipboard body)

fun save-note:
    when (button "save" "Save"):
        alert "Note saved"

HeaderBar title:
    (copy-note)
    (save-note)
```

### Declaring and emitting events: `emits` / `emit`

`emits Name field...` names what the widget emits — custom events get their
fields declared at the same time. Emitting an undeclared event is a load
error:

```owl
widget Counter id label n:
    emits Bumped by
    row (gap = 12) (align-y = "center"):
        text (concat label ": " (to-string n))
        when (button (concat id ".more") "+1"):
            emit Bumped (by = 1)

handle-events:
    event Bumped e:
        set clicks (+ clicks e.by)
    Counter "c" "Clicks" clicks
```

A bare `emits Name` (no fields) re-declares nothing but grants permission to
emit — useful for relaying a *stock* event, which keeps its Nim payload:

```owl
widget OkButton label:
    emits Pressed
    when (button "ok.button" label):
        emit Pressed (id = "ok.button")
```

### Catching a child's events: `event ... reemit`

The body runs inside the widget's own frame, so an `event Name e:` section
catches what the body emits. Without `reemit` the event stops here:

```owl
widget QuietCombo id options selected:
    event Picked e:
        echo (concat "the combo handled index " (to-string e.index))
    combo-box id options selected
```

With `reemit` the same frame lets it travel on to the handlers above:

```owl
widget Guard label text:
    event TextCommitted e:
        echo "checked, passing it on"
        reemit
    labeled label:
        text-field "guard.field" text (placeholder = "Type, press Enter")
```

Handlers see the payload record and may change it before the reemit — the
handler fun's last value (a record of the event's fields) replaces it.

### `focusable` widgets

`widget focusable Name ...` prepends an `id` parameter, appends
`(tab-index = 0)`, and puts the widget on the Tab chain (`register-focus`)
before running the body:

```owl
widget focusable Stepper label (value = 0):
    row id (gap = 8) (padding = 6) (bg = "panel") (corner = 6) (focus-ring = id):
        when (button (concat id ".down") "-"):
            set value (- value 1)
        text (to-string value)
        when (button (concat id ".up") "+"):
            set value (+ value 1)
    value

set stepper (Stepper "step" "Count" 1)
```

The `id` it receives is the element to draw, focus and ring around —
`focused id`, `activated id` and `clicked id` all work against it:

```owl
widget focusable BigToggle label (on = false):
    when (activated id):
        set on (not on)
    when (clicked id):
        set on (not on)
    mark = if on:
        "on"
        "off"
    row id (gap = 8) (align-y = "center") (focus-ring = id):
        text label
        badge mark
    on
```

### What `widget` generates

The command compiles the definition into an ordinary fun wrapped in
`widget-frame` — the event frame the Nim widgets share. The `emits` lines
are acted on at definition time (custom events get `define-event`, stock
ones are already declared), every `event Name e:` section becomes a handler
fun, and the body runs last, inside the frame. Read the generated source any
time with `widget-code`:

```owl
echo (widget-code "Counter")
```

```owl
fun Counter id label n:
    fun widget-body:
        row (gap = 12) (align-y = "center"):
            text (concat label ": " (to-string n))
            when (button (concat id ".more") "+1"):
                emit Bumped (by = 1)
    widget-frame "Counter" id ([]) widget-body
```

With an `event` section, the handler table gets a `[name fun]` pair, and the
handler fun's last value — the record `e` — replaces the payload on its way
past a `reemit`:

```owl
fun Guard label text:
    fun widget-on-TextCommitted e:
        echo "checked, passing it on"
        (reemit)
        e
    fun widget-body:
        labeled label:
            text-field "guard.field" text (placeholder = "Type, press Enter")
    widget-frame "Guard" nothing ([] ([] "TextCommitted" widget-on-TextCommitted)) widget-body
```

A `focusable` widget grows an `id` parameter, a trailing `(tab-index = 0)`,
and the `register-focus` line before its body:

```owl
fun Stepper id label (value = 0) (tab-index = 0):
    register-focus id tab-index
    fun widget-body:
        row id (gap = 8):
            when (button (concat id ".up") "+"):
                set value (+ value 1)
        value
    widget-frame "Stepper" id ([]) widget-body
```

You can also build the frame by hand with the `widget-frame name id
handlers body` builtin — passing your own `([] ([] "Name" fun) ...)` pairs —
when a definition outgrows the command.

### Widgets in modules

Put app widgets in their own module — the `--gui` scaffold does this in
`src/widgets.owl` — and hot reload picks up edits while the app runs:

```owl
; widgets.owl
use base
use gui
export all

widget Counter id label n:
    emits Bumped by
    row (gap = 12) (align-y = "center"):
        text (concat label ": " (to-string n))
        when (button (concat id ".more") "+1"):
            emit Bumped (by = 1)
```

```owl
; main.owl
use gui
use widgets
```

### Gotchas

- A parameter named `label` (or `text`, `heading`...) shadows the stock
  widget of that name inside the body — rename the parameter or call the
  widget another way.
- Zero-argument slots/functions need parentheses when called: `(body)`,
  `(spacer)`, `(theme)`.
- Events emitted in a body bubble only until the first `event` section or
  enclosing `handle-events` that does not `reemit`.
- A `widget` needs a name (`widget Name params...:`); a body with no last
  value returns `nothing`.

---

## 23. A complete app

A notebook app in one file — sidebar + header layout, nearly every widget, a
custom widget with a slot, events, dialogs, cadence and a theme preset (run
it with `owl run`):

```owl
use io
use base
use math
use strings
use iterators
use gui

; ---------- app state ----------
title = "Shopping list"
body = "milk, bread, coffee"
dark = true
mono = true
wrap = false
autosaves = 0
tag-picks = ([] 0)
tags = ([] "urgent" "later" "archive")
kind = 0
kinds = ([] "Note" "Task" "Journal")
last-action = "welcome"

; ---------- custom widgets used by the app ----------

widget HeaderBar text &actions:
    row (width = grow) (height = 56) (padding = [] 16 8) (gap = 12) (align-y = "center") (bg = "panel") (corner = 8):
        heading text 1
        (spacer)
        (actions)

widget LabeledSwitch id label (on = false):
    labeled label:
        set on (switch id label on)
    on

fun saved r:
    when r.accepted:
        set last-action "saved"

fun copy-note:
    when (button "copy" "Copy"):
        (set-clipboard body)
        set last-action "copied"

fun save-note:
    when (button "save" "Save"):
        alert (concat "Saved " (to-string (length body)) " chars") (title = "Saved") (on-done = saved)

; ---------- the view ----------

fun view:
    handle-events:
        event MenuPicked e:
            when (= e.label "Quit"):
                (quit-app)
            set last-action e.label

        row (width = grow) (height = grow) (gap = 12) (padding = 12):

            column (width = 220) (height = grow) (gap = 10) (padding = 12) (bg = "panel") (corner = 8):
                overline "notebook"
                set dark (LabeledSwitch "dark" "Dark theme" dark)
                set mono (LabeledSwitch "mono" "Monospace" mono)
                set wrap (checkbox "wrap" "Soft wrap" wrap)
                set kind (combo-box "kind" kinds kind)
                set tag-picks (multi-select "tags" tags tag-picks (placeholder = "Tags..."))
                (spacer)
                card-row:
                    stat-card "Saves" (to-string autosaves) (hint = "this session")

            column (width = grow) (height = grow) (gap = 10):
                HeaderBar title:
                    (copy-note)
                    (save-note)
                set title (text-field "title" title (placeholder = "Note title"))
                font-name = if mono:
                    "mono"
                    "ui"
                set body (code-editor "body" body (font = font-name) (wrap = wrap) (max-lines = 5000))
                row (gap = 8) (align-y = "center"):
                    badge (concat (to-string (length body)) " chars")
                    badge (concat "kind: " (index kinds (+ kind 0)))
                    when (refresh-due "autosave" 10000):
                        set autosaves (+ autosaves 1)
                    caption last-action
                    err-text = (frame-error)
                    when (<> err-text nothing):
                        badge "last frame failed"

run-app (title = "Notes") (width = 860) (height = 560):
    (view)
```

---

*Every example above parses and evaluates against `bin/owl`; the long ones
were run as real apps in the TUI. If a snippet trips, `frame-error` prints
why, and the repl lets you patch the view live.*
