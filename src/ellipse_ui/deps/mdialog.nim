## Nimony template plugin: the `dialog` and `formDialog` definition macros.
##
## `dialog Name("spec.name", <DialogSpec field = value...>):` + body defines
##
##   proc NameBody() {.raises.} = ...        # the body statements
##   proc NameFooter() {.raises.} = ...      # the `footer:` section, if any
##   let Name = defineDialog("spec.name", DialogSpec(<fields>,
##       body: NameBody, footer: NameFooter))
##
## `formDialog` is the same over the forms helpers, wiring the record round
## trip, the Enter rule and the validation list:
##
##   proc NameErrors(): seq[string] = formErrors(<validate entries>)
##   proc NameValid(): bool = formValid(NameErrors())
##   proc NameSubmit() = formSubmit(draft, "add", NameErrors())
##   proc NameBody() {.raises.} =
##     beginForm(draft)
##     formEnter "bio": NameSubmit()
##     ...body statements...
##   ...
##
## Inside the sections the words `draft`, `submit`, `valid` and `errors`
## name the form's draft and its generated procs; `draft = task` points the
## word `draft` at another variable (the rewrite maps it there).
##
## Head arguments: the spec name (leading StrLit) and `field = value` pairs.
## `title`/`width`/`maxHeight`/`scroll`/`dismissable`/`header` reach the
## DialogSpec verbatim. A formDialog consumes `draft = <ident>`,
## `answer = "..."`, `enter = "..."` and `key = "..."` for itself.
##
## Input shape (verified against nifler output):
##   (stmts dialog (call Name "spec.name" (vv title "T")...)
##          (stmts <body...> (call footer (stmts ...)) (call validate (stmts ...))))

import plugins
import std/[syncio, envvars]

type
  HeadArg = object
    key: string
    val: NifCursor     ## the `field = value` / `field: value` value node
  Spec = object
    handle: string     ## the ident the definitions are named after
    name: string       ## the dialog's spec name
    args: seq[HeadArg] ## DialogSpec fields, in order
    draft, answer, key: string
    enters: seq[string]
    error: string
    errorAt: NifCursor

proc atomText(n: NifCursor): string =
  case n.kind
  of Ident:
    result = n.identText
  of Symbol, SymbolDef:
    result = n.symText
  else:
    result = ""

proc tagOf(n: NifCursor): string =
  if n.kind == TagLit: n.tagText else: ""

proc callee(n: NifCursor): string =
  ## The callee of a plain `(call ident ...)` node, "" otherwise.
  if n.tagOf == "call": firstChild(n).atomText else: ""

proc copyRewritten(dest: var NifBuilder; src: NifCursor;
                   map: seq[(string, string)]) =
  ## Deep-copy `src`'s subtree, renaming `Ident` leaves per `map`.
  if src.kind == Ident:
    var hit = ""
    for (k, v) in map:
      if k == src.identText:
        hit = v
    if hit.len > 0:
      dest.addIdent hit
    else:
      var q = src
      dest.takeTree q
  elif src.kind == TagLit:
    dest.openTree(src.tagId, src.info)
    var c = firstChild(src)
    while c.hasMore:
      copyRewritten(dest, c, map)
      skip c
    dest.closeTree()
  else:
    var q = src
    dest.takeTree q

proc collectChildren(dest: var NifBuilder; src: NifCursor;
                     map: seq[(string, string)]) =
  ## Copy every child of a `(stmts ...)` node into `dest`, which is open on
  ## its own `(stmts` tree.
  var c = firstChild(src)
  while c.hasMore:
    copyRewritten(dest, c, map)
    skip c

proc parseSpec(n: NifCursor; isForm: bool): Spec =
  result = Spec(args: @[], enters: @[])
  var args = callArgs(n)
  if not args.hasMore or args.tagOf != "call":
    result.error = "expected `Name(\"spec.name\", field = value...)`"
    result.errorAt = args
    return
  let head = args
  result.handle = head.callee
  if result.handle.len == 0:
    result.error = "expected `Name(\"spec.name\", ...)`"
    result.errorAt = head
    return
  var c = firstChild(head)
  skip c                                 # the handle
  var firstPos = true
  while c.hasMore:
    if c.kind == StrLit and firstPos:
      result.name = c.stringValue
      firstPos = false
    elif c.tagOf == "vv" or c.tagOf == "kv":
      var kv = firstChild(c)
      let k = kv.atomText
      skip kv
      if not kv.hasMore:
        result.error = "argument `" & k & "` needs a value"
        result.errorAt = c
        return
      var taken = false
      if isForm and k in ["draft", "answer", "enter", "key"]:
        taken = true
        if k == "draft":
          if kv.kind != Ident and kv.kind != Symbol:
            result.error = "`draft = ` names the draft variable, not an " &
                           "expression"
            result.errorAt = kv
            return
          result.draft = kv.atomText
        elif kv.kind == StrLit:
          case k
          of "answer": result.answer = kv.stringValue
          of "enter": result.enters.add kv.stringValue
          else: result.key = kv.stringValue
        else:
          result.error = "`" & k & " = ` wants a string"
          result.errorAt = kv
          return
      if not taken:
        result.args.add HeadArg(key: k, val: kv)
    else:
      result.error = "unexpected positional argument (only the spec name " &
                     "leads; everything else is `field = value`)"
      result.errorAt = c
      return
    skip c
  if result.name.len == 0:
    result.error = "expected the spec name: `Name(\"...\")`"
    result.errorAt = head
    return
  if result.draft.len == 0:
    result.draft = "draft"
  if result.answer.len == 0:
    result.answer = "ok"

proc openStmts(b: var NifBuilder; info: LineInfo) =
  b.openTree("stmts", info)

proc emitFormProcs(dest: var NifBuilder; info: LineInfo; sp: Spec; h: string;
                   validateStmts, bodyStmts: NifCursor) =
  ## The form's generated plumbing: Errors, Valid, Submit and the body proc
  ## with `beginForm` and the Enter rule ahead of the author's statements.
  # proc hErrors(): seq[string] = result = formErrors(validate entries...)
  dest.openTree("proc", info)
  dest.addIdent h & "Errors"
  dest.addEmptyNode3 info                # export, pattern, typevars
  dest.openTree("params", info)
  dest.closeTree()
  dest.openTree("at", info)              # seq[string]
  dest.addIdent "seq"
  dest.addIdent "string"
  dest.closeTree()
  dest.addEmptyNode2 info                # pragmas, effects
  dest.openTree("stmts", info)
  dest.openTree("asgn", info)
  dest.addIdent "result"
  dest.openTree("call", info)
  dest.addIdent "formErrors"
  collectChildren(dest, validateStmts, @[])
  dest.closeTree()                       # call
  dest.closeTree()                       # asgn
  dest.closeTree()                       # stmts
  dest.closeTree()                       # proc

  # proc hValid(): bool = result = formValid(hErrors())
  dest.openTree("proc", info)
  dest.addIdent h & "Valid"
  dest.addEmptyNode3 info
  dest.openTree("params", info)
  dest.closeTree()
  dest.addIdent "bool"
  dest.addEmptyNode2 info
  dest.openTree("stmts", info)
  dest.openTree("asgn", info)
  dest.addIdent "result"
  dest.openTree("call", info)
  dest.addIdent "formValid"
  dest.openTree("call", info)
  dest.addIdent h & "Errors"
  dest.closeTree()
  dest.closeTree()                       # formValid(...)
  dest.closeTree()                       # asgn
  dest.closeTree()
  dest.closeTree()                       # proc

  # proc hSubmit() = formSubmit(draft, answer, hErrors())
  dest.openTree("proc", info)
  dest.addIdent h & "Submit"
  dest.addEmptyNode3 info
  dest.openTree("params", info)
  dest.closeTree()
  dest.addEmptyNode3 info                # void result, pragmas, effects
  dest.openTree("stmts", info)
  dest.openTree("call", info)
  dest.addIdent "formSubmit"
  dest.addIdent sp.draft
  dest.addStrLit sp.answer
  dest.openTree("call", info)
  dest.addIdent h & "Errors"
  dest.closeTree()
  dest.closeTree()                       # call formSubmit
  dest.closeTree()                       # stmts
  dest.closeTree()                       # proc

  # proc hBody() {.raises.} = beginForm(draft); formEnter: hSubmit(); body
  dest.openTree("proc", info)
  dest.addIdent h & "Body"
  dest.addEmptyNode3 info
  dest.openTree("params", info)
  dest.closeTree()
  dest.addEmptyNode info                 # void result
  dest.openTree("pragmas", info)
  dest.addIdent "raises"
  dest.closeTree()
  dest.addEmptyNode info                 # effects
  dest.openTree("stmts", info)
  dest.openTree("call", info)            # beginForm(draft [, (vv key "...")])
  dest.addIdent "beginForm"
  dest.addIdent sp.draft
  if sp.key.len > 0:
    dest.openTree("vv", info)
    dest.addIdent "key"
    dest.addStrLit sp.key
    dest.closeTree()
  dest.closeTree()
  if sp.enters.len == 1:
    dest.openTree("call", info)          # formEnter "bio": hSubmit()
    dest.addIdent "formEnter"
    dest.addStrLit sp.enters[0]
    dest.openTree("stmts", info)
    dest.openTree("call", info)
    dest.addIdent h & "Submit"
    dest.closeTree()
    dest.closeTree()                     # (stmts of formEnter)
    dest.closeTree()                     # formEnter
  elif sp.enters.len > 1:
    # enterThrough "a", "b"; if dialogEnter(): hSubmit()
    dest.openTree("call", info)
    dest.addIdent "enterThrough"
    for e in sp.enters:
      dest.addStrLit e
    dest.closeTree()
    dest.openTree("if", info)
    dest.openTree("elif", info)
    dest.openTree("call", info)
    dest.addIdent "dialogEnter"
    dest.closeTree()
    dest.openTree("stmts", info)
    dest.openTree("call", info)
    dest.addIdent h & "Submit"
    dest.closeTree()
    dest.closeTree()                     # stmts
    dest.closeTree()                     # elif
    dest.closeTree()                     # if
  else:
    dest.openTree("call", info)          # formEnter: hSubmit()
    dest.addIdent "formEnter"
    dest.openTree("stmts", info)
    dest.openTree("call", info)
    dest.addIdent h & "Submit"
    dest.closeTree()
    dest.closeTree()                     # (stmts of formEnter)
    dest.closeTree()                     # formEnter
  collectChildren(dest, bodyStmts, @[])  # the author's statements
  dest.closeTree()                       # stmts
  dest.closeTree()                       # proc

proc emitBodyOnly(dest: var NifBuilder; info: LineInfo; h: string;
                  bodyStmts: NifCursor) =
  ## `proc hBody() {.raises.} = <body>` -- the plain dialog's one proc.
  dest.openTree("proc", info)
  dest.addIdent h & "Body"
  dest.addEmptyNode3 info
  dest.openTree("params", info)
  dest.closeTree()
  dest.addEmptyNode info                 # void result
  dest.openTree("pragmas", info)
  dest.addIdent "raises"
  dest.closeTree()
  dest.addEmptyNode info                 # effects
  dest.openTree("stmts", info)
  collectChildren(dest, bodyStmts, @[])
  dest.closeTree()
  dest.closeTree()

proc emitFooter(dest: var NifBuilder; info: LineInfo; h: string;
                footerStmts: NifCursor) =
  dest.openTree("proc", info)
  dest.addIdent h & "Footer"
  dest.addEmptyNode3 info
  dest.openTree("params", info)
  dest.closeTree()
  dest.addEmptyNode info                 # void result
  dest.openTree("pragmas", info)
  dest.addIdent "raises"
  dest.closeTree()
  dest.addEmptyNode info                 # effects
  dest.openTree("stmts", info)
  collectChildren(dest, footerStmts, @[])
  dest.closeTree()
  dest.closeTree()

proc emitHandle(dest: var NifBuilder; info: LineInfo; sp: Spec; h: string;
                hasFooter: bool) =
  ## `let h = defineDialog("<name>", DialogSpec(<fields>, body: hBody
  ## [, footer: hFooter]))`.
  dest.openTree("let", info)
  dest.addIdent h
  dest.addEmptyNode3 info                # export, pattern, typevars
  dest.openTree("call", info)
  dest.addIdent "defineDialog"
  dest.addStrLit sp.name
  dest.openTree("oconstr", info)
  dest.addIdent "DialogSpec"
  for a in sp.args:
    dest.openTree("kv", info)
    dest.addIdent a.key
    var v = a.val
    dest.takeTree v
    dest.closeTree()
  dest.openTree("kv", info)
  dest.addIdent "body"
  dest.addIdent h & "Body"
  dest.closeTree()
  if hasFooter:
    dest.openTree("kv", info)
    dest.addIdent "footer"
    dest.addIdent h & "Footer"
    dest.closeTree()
  dest.closeTree()                       # oconstr
  dest.closeTree()                       # call
  dest.closeTree()                       # let

proc transform(n: NifCursor): NifBuilder =
  let kind = pluginName(n)
  let isForm = kind == "formDialog"
  if kind != "dialog" and not isForm:
    return errorTree("mdialog: unknown template `" & kind & "`", n)
  let info = n.info
  let sp = parseSpec(n, isForm)
  if sp.error.len > 0:
    return errorTree(kind & " `" & sp.handle & "`: " & sp.error, sp.errorAt)
  let h = sp.handle
  var map: seq[(string, string)] = @[]
  if isForm:
    map.add ("submit", h & "Submit")
    map.add ("valid", h & "Valid")
    map.add ("errors", h & "Errors")
    if sp.draft != "draft":
      map.add ("draft", sp.draft)

  var args = callArgs(n)
  var bodyNode = args
  skip bodyNode                          # the head -> the body (stmts ...)
  if not bodyNode.hasMore or bodyNode.tagOf != "stmts":
    return errorTree(kind & " `" & h & "`: expected a body", bodyNode)

  # split the body's statements from its `footer:`/`validate:` sections
  var treeBody = createTree()
  treeBody.openStmts(info)
  var treeFooter = createTree()
  treeFooter.openStmts(info)
  var treeValidate = createTree()
  treeValidate.openStmts(info)
  var anyFooter = false
  var anyValidate = false
  var splitError = ""
  var splitAt = bodyNode
  block:
    var c = firstChild(bodyNode)
    while c.hasMore:
      let sec = callee(c)
      if sec == "footer" or sec == "validate":
        if sec == "validate" and not isForm:
          splitError = "a plain dialog has no validate section (use " &
                       "formDialog)"
          splitAt = c
        else:
          var k = firstChild(c)
          skip k                         # the section name
          if k.hasMore and k.tagOf == "stmts":
            if sec == "footer":
              anyFooter = true
              collectChildren(treeFooter, k, map)
            else:
              anyValidate = true
              collectChildren(treeValidate, k, map)
          else:
            splitError = "section `" & sec & "` wants an indented block"
            splitAt = c
      else:
        copyRewritten(treeBody, c, map)
      skip c
  treeBody.closeTree()
  treeFooter.closeTree()
  treeValidate.closeTree()
  if splitError.len > 0:
    return errorTree(kind & " `" & h & "`: " & splitError, splitAt)

  result = createTree()
  result.withTree StmtsS, info:
    if isForm:
      emitFormProcs(result, info, sp, h, snapshot(treeValidate),
                    snapshot(treeBody))
    else:
      emitBodyOnly(result, info, h, snapshot(treeBody))
    if anyFooter:
      emitFooter(result, info, h, snapshot(treeFooter))
    emitHandle(result, info, sp, h, anyFooter)

  if getEnv("MDIALOG_DSL_DEBUG").len > 0:
    try:
      writeFile("/tmp/opencode/mdialog-output-" & h & ".nif",
                renderTree(result))
    except ErrorCode:
      discard

var inp = loadPluginInput()
saveTree transform(inp)
