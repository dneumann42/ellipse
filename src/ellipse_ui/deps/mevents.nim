## Port of the nimony template plugin behind `handleEvents` and `defineEvent`
## (`ellipse_ui/events`); included into that module, dispatching on the
## invoked name.
##
##   handleEvents:              (stmts handleEvents (stmts ...))
##     event Saved(e): ...
##     drawUi()
##
## becomes a block holding the handler frame around the other statements
## (see `meventgen.emitEventFrame`), and
##
##   defineEvent Saved(path: string)
##
## declares the event type of a widget's `emits Saved(path: string)`.
##
## Shapes verified against the standard parser (see `meventgen`): a trailing
## block attaches to the command it follows, so an `event` section arrives
## as Command(event, <head>, StmtList).

import std/[macros, strutils]
import ./meventgen

macro handleEvents*(body: untyped): untyped =
  ## Catch events around a block of statements outside any widget: the
  ## block's `event Name(e): ...` sections become a frame's handlers, the
  ## remaining statements run inside it.
  if body.kind != nnkStmtList:
    error("handleEvents: expected a block: `handleEvents: ...`", body)
  var sections = collectEventSections(body, "handleEvents",
                                      allowEmits = false)
  if sections.error.len == 0:
    checkSections(sections, "handleEvents", checkEmits = false)
  if sections.error.len > 0:
    error(sections.error, sections.errorAt)
  var nodes: seq[NimNode] = @[]
  emitEventFrame(nodes, sections, "handleEvents", "")
  result = newStmtList()
  for n in nodes:
    result.add n

macro defineEvent*(head: untyped): untyped =
  ## Declare an event type at top level -- `defineEvent Saved(path: string)`
  ## -- for widgets that share it through a bare `emits Saved`.
  var sections = EventSections(decls: @[], handlers: @[], rest: @[], error: "")
  parseEventHead(sections, "defineEvent", head)
  if sections.error.len > 0:
    error(sections.error, head)
  if not sections.decls[0].declares:
    error("defineEvent: `" & sections.decls[0].name &
      "` needs a field list: `defineEvent " & sections.decls[0].name &
      "()` for none", head)
  var nodes: seq[NimNode] = @[]
  emitEventType(nodes, sections.decls[0],
                moduleNameOf(head.lineInfoObj))
  result = newStmtList()
  for n in nodes:
    result.add n
