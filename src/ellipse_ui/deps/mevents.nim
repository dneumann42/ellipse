## Nimony template plugin behind `handleEvents` and `defineEvent`
## (`ellipse_ui/events`); one executable, dispatching on the invoked name.
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
## the event type of a widget's `emits Saved(path: string)`.

import plugins
import ./meventgen

proc handleEventsTree(n: NifCursor): NifBuilder =
  result = createTree()
  let info = n.info
  let body = callArgs(n)
  if not body.hasMore or body.kind != TagLit or body.tagText != "stmts":
    return errorTree("handleEvents: expected a block: `handleEvents: ...`", n)
  var sections = collectEventSections(body, "handleEvents",
                                      allowEmits = false)
  if sections.error.len == 0:
    checkSections(sections, "handleEvents", checkEmits = false)
  if sections.error.len > 0:
    return errorTree(sections.error, sections.errorAt)
  result.openTree("block", info)
  result.addEmptyNode info
  result.openTree("stmts", info)
  emitEventFrame(result, info, sections, "handleEvents", "")
  result.closeTree()
  result.closeTree()

proc defineEventTree(n: NifCursor): NifBuilder =
  result = createTree()
  let info = n.info
  let head = callArgs(n)
  if not head.hasMore:
    return errorTree("defineEvent: expected `defineEvent Name(field: T, ...)`", n)
  # reuse the `emits` parser on a synthetic view: it skips a leading word
  var sections = EventSections(decls: @[], handlers: @[], rest: @[], error: "")
  parseEventHead(sections, "defineEvent", head, n)
  if sections.error.len > 0:
    return errorTree(sections.error, sections.errorAt)
  if not sections.decls[0].declares:
    return errorTree("defineEvent: `" & sections.decls[0].name &
      "` needs a field list: `defineEvent " & sections.decls[0].name &
      "()` for none", n)
  result.openTree("stmts", info)
  emitEventType(result, sections.decls[0], moduleName(info))
  result.closeTree()

var inp = loadPluginInput()
case pluginName(inp)
of "handleEvents":
  saveTree handleEventsTree(inp)
of "defineEvent":
  saveTree defineEventTree(inp)
else:
  saveTree errorTree("ellipse_ui/deps/mevents: unknown template `" &
    pluginName(inp) & "`", inp)
