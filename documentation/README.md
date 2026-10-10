# Writing GUIs with ellipse

This is the manual for building graphical applications with the ellipse UI
toolkit, in **Nim (Nimony)** and in **Owl**. It is a tutorial: it starts with a
window and a label and walks all the way to dialogs, themes, keymaps, widget
events and a live-reloading app.

The toolkit is *immediate mode*: a frame re-runs your whole view function, and
every widget call both draws the control and reads its state. There is no
widget tree kept between frames, no callbacks registered up front; you pass a
value in, the widget returns the value to store back.

## Where to go

| Document | What it covers |
| --- | --- |
| [nim-tutorial.md](nim-tutorial.md) | The full Nim/Nimony tutorial: layout, widgets, events, focus, keys, theme, cadence, app shell, dialogs, hot reload. |
| [owl-tutorial.md](owl-tutorial.md) | The same system from Owl: `widget`, `run-app`, the builtin set, hot reload and the repl. |
| [reference-widgets.md](reference-widgets.md) | One-page reference tables: every widget and the layout/combinator vocabulary, with Nim and Owl signatures side by side. |

The existing `docs/` folder (design notes, `ui.org`, `clay.org`, ...) is left
untouched; this `documentation/` folder is the tutorial.

## Building and running

The build uses Nimony (`./build/nimony/bin/nimony`, fetched by
`./scripts/setup.sh`).

```sh
make setup          # fetch the Nimony compiler (once)
make bin/gallery    # build the Nim widget gallery
make run_gallery    # run it in a window
make run_gallery_tui # run it in the terminal instead
```

The gallery is the canonical, executable tour of the whole widget set:
`apps/gallery.nim` (Nim) and `apps/owl-gallery/src/main.owl` (Owl). When this
manual and the gallery disagree, the gallery wins.

Owl builds terminal-only by default; use `make build_owl_sdl` for a window
backend.

## Two quick starts

### Nim (Nimony)

```nim
import ellipse_ui/app

var count = 0

proc view() {.raises.} =
  clay "root", col(width = grow(), height = grow(), padding = padAll(24),
                   gap = 8):
    text("Clicked " & $count & " times")
    if textLink(hashId("more"), "Add one"):
      inc count

when isMainModule:
  run App(window: WindowConfig(title: "Counter"), view: view)
```

`import ellipse_ui/app` brings in the whole kit: clay layout, the platform and
renderer, the logger, the core `ui`, the widget set, the debug overlay and the
dialogs. `run` opens the window and runs the frame loop; `view` is called every
frame.

### Owl

```owl
use gui

count = 0

fun view:
    handle-events:
        column (padding = 24) (gap = 8):
            text (concat "Clicked " (to-string count) " times")
            when (text-link "more" "Add one"):
                set count (+ count 1)

run-app (title = "Counter"):
    (view)
```

`use gui` gives both the toolkit builtins and the Owl layer (`widget`,
`run-app`). `run-app` opens the window and runs the loop; its block is the view,
re-run every frame. Saving a project file reloads it live (see
[owl-tutorial.md](owl-tutorial.md)).

## The mental model in one example

```nim
var checked = false
...
checked = checkbox(hashId("wifi"), "Wifi", checked)
```

The checkbox draws itself from `checked`, and returns the state to store back --
flipped if the user clicked it or pressed Space/Enter on it this frame. That is
the whole contract, repeated by every input widget: **pass the value in, assign
the return value back**. An event (`Toggled`) is emitted alongside it for code
further up the tree, but the return value is enough on its own.

Read [nim-tutorial.md](nim-tutorial.md) next.
