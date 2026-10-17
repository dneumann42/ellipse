## The ellipse GUI kit: the clay layout engine behind an SDL3 (or terminal)
## renderer, the standard widget set, dialogs and the app shell.
##
##   import ellipse_ui
##
##   run(App(window: WindowConfig(title: "hello"),
##           view = proc () = button("Press me")))
##
## `ellipse_ui/app` is the one-stop import (it re-exports clay, the platform,
## the renderer, ui, widgets, debug and dialogs); this module adds the clock
## and the hot-loading loop around it. Ported from the nimony kit
## (`ellipse-preview`); the game engine lives in `ellipse.nim` beside this.

import ellipse/clock
import ellipse/hotload
import ellipse_ui/app

export clock, hotload, app
