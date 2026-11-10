## Standard Nim port of the nimony template plugin: the `dialog` and
## `formDialog` definition macros. Included into `ellipse_ui/dialogs`.
##
## `dialog Name("spec.name", <DialogSpec field = value...>):` + body defines
##
##   proc NameBody()  = ...        # the body statements
##   proc NameFooter()  = ...      # the `footer:` section, if any
##   let Name = defineDialog("spec.name", DialogSpec(<fields>,
##       body: NameBody, footer: NameFooter))
##
## `formDialog` is the same over the forms helpers, wiring the record round
## trip, the Enter rule and the validation list:
##
##   proc NameErrors(): seq[string] = result = formErrors(<validate entries>)
##   proc NameValid(): bool = result = formValid(NameErrors())
##   proc NameSubmit() = formSubmit(draft, "add", NameErrors())
##   proc NameBody() =
##     beginForm(draft)
##     formEnter "bio": NameSubmit()
##     ...body statements...
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
## Shapes verified against the standard parser: the head is
## Call(Name, StrLit, ExprEqExpr...); a section is Call/Command(footer,
## StmtList).
{.push gcsafe.}


import std/[macros, strutils]

type
  HeadArg = object
    key: string
    val: NimNode     ## the `field = value` value node
  Spec = object
    handle: string   ## the ident the definitions are named after
    name: string     ## the dialog's spec name
    args: seq[HeadArg] ## DialogSpec fields, in order
    draft, answer, key: string
    enters: seq[string]
    error: string
    errorAt: NimNode

proc newIdent(s: string): NimNode = newIdentNode(s)

proc routine(kind: NimNodeKind, name: NimNode, ret, pragmas,
             body: NimNode): NimNode =
  ## A parameterless proc: name, pattern, typevars, params, pragmas,
  ## reserved, body.
  newTree(kind, name, newEmptyNode(), newEmptyNode(),
    newNimNode(nnkFormalParams).add(ret), pragmas, newEmptyNode(), body)

proc rewriteMap(n: NimNode; map: seq[(string, string)]): NimNode =
  ## Deep-copy `n`, renaming identifier leaves per `map`.
  if n.kind == nnkIdent:
    for (k, v) in map:
      if k == n.strVal:
        return newIdent(v)
  result = copyNimNode(n)
  for c in n:
    result.add rewriteMap(c, map)

proc copyStmtsInto(dest: NimNode; src: NimNode; map: seq[(string, string)]) =
  ## Copy every statement of a body into `dest` (a StmtList being built).
  for c in src:
    dest.add rewriteMap(c, map)

proc isSection(n: NimNode; name: string): bool =
  n.kind in {nnkCall, nnkCommand} and n.len == 2 and n[0].kind == nnkIdent and
    n[0].strVal == name and n[1].kind == nnkStmtList

proc parseSpec(n: NimNode; isForm: bool): Spec =
  result = Spec(args: @[], enters: @[])
  # n: the head call `Name("spec", field = value...)`
  if n.kind != nnkCall or n[0].kind != nnkIdent:
    result.error = "expected `Name(\"spec.name\", field = value...)`"
    result.errorAt = n
    return
  result.handle = n[0].strVal
  var firstPos = true
  var i = 1
  while i < n.len:
    let c = n[i]
    if c.kind == nnkStrLit and firstPos:
      result.name = c.strVal
      firstPos = false
    elif c.kind == nnkExprEqExpr and c[0].kind == nnkIdent:
      let k = c[0].strVal
      let v = c[1]
      var taken = false
      if isForm and k in ["draft", "answer", "enter", "key"]:
        taken = true
        if k == "draft":
          if v.kind != nnkIdent:
            result.error = "`draft = ` names the draft variable, not an " &
                           "expression"
            result.errorAt = v
            return
          result.draft = v.strVal
        elif v.kind == nnkStrLit:
          case k
          of "answer": result.answer = v.strVal
          of "enter": result.enters.add v.strVal
          else: result.key = v.strVal
        else:
          result.error = "`" & k & " = ` wants a string"
          result.errorAt = v
          return
      if not taken:
        result.args.add HeadArg(key: k, val: v)
    else:
      result.error = "unexpected positional argument (only the spec name " &
                     "leads; everything else is `field = value`)"
      result.errorAt = c
      return
    inc i
  if result.name.len == 0:
    result.error = "expected the spec name: `Name(\"...\")`"
    result.errorAt = n
  if result.draft.len == 0:
    result.draft = "draft"
  if result.answer.len == 0:
    result.answer = "ok"

proc emitFormProcs(dest: var seq[NimNode]; sp: Spec; h: string;
                   validateStmts, bodyStmts: NimNode) =
  ## The form's generated plumbing: Errors, Valid, Submit and the body proc
  ## with `beginForm` and the Enter rule ahead of the author's statements.
  # proc hErrors(): seq[string] = result = formErrors(validate entries...)
  var body = newStmtList()
  var fe = newCall(newIdent("formErrors"))
  copyStmtsInto(fe, validateStmts, @[])
  body.add newAssignment(newIdent("result"), fe)
  dest.add routine(nnkProcDef, newIdent(h & "Errors"),
    newTree(nnkBracketExpr, newIdent("seq"), newIdent("string")),
    newEmptyNode(), body)

  # proc hValid(): bool = result = formValid(hErrors())
  dest.add routine(nnkProcDef, newIdent(h & "Valid"), newIdent("bool"),
    newEmptyNode(), newStmtList(newAssignment(newIdent("result"),
      newCall(newIdent("formValid"), newCall(newIdent(h & "Errors"))))))

  # proc hSubmit() = formSubmit(draft, answer, hErrors())
  dest.add routine(nnkProcDef, newIdent(h & "Submit"), newEmptyNode(),
    newEmptyNode(), newStmtList(newCall(newIdent("formSubmit"),
      newIdent(sp.draft), newLit(sp.answer),
      newCall(newIdent(h & "Errors")))))

  # proc hBody() = beginForm(draft); formEnter: hSubmit(); body
  body = newStmtList()
  var beginCall = newCall(newIdent("beginForm"), newIdent(sp.draft))
  if sp.key.len > 0:
    beginCall.add newTree(nnkExprEqExpr, newIdent("key"), newLit(sp.key))
  body.add beginCall
  if sp.enters.len == 1:
    body.add newTree(nnkCommand, newIdent("formEnter"), newLit(sp.enters[0]),
      newStmtList(newCall(newIdent(h & "Submit"))))
  elif sp.enters.len > 1:
    var et = newCall(newIdent("enterThrough"))
    for e in sp.enters:
      et.add newLit(e)
    body.add et
    body.add newTree(nnkIfStmt, newTree(nnkElifBranch,
      newCall(newIdent("dialogEnter")),
      newStmtList(newCall(newIdent(h & "Submit")))))
  else:
    body.add newTree(nnkCommand, newIdent("formEnter"),
      newStmtList(newCall(newIdent(h & "Submit"))))
  copyStmtsInto(body, bodyStmts, @[])
  dest.add routine(nnkProcDef, newIdent(h & "Body"), newEmptyNode(),
    newEmptyNode(), body)

proc emitBodyOnly(dest: var seq[NimNode]; h: string; bodyStmts: NimNode;
                  map: seq[(string, string)]) =
  ## `proc hBody() = <body>` -- the plain dialog's one proc.
  var body = newStmtList()
  copyStmtsInto(body, bodyStmts, map)
  dest.add routine(nnkProcDef, newIdent(h & "Body"), newEmptyNode(),
    newEmptyNode(), body)

proc emitFooter(dest: var seq[NimNode]; h: string; footerStmts: NimNode;
                map: seq[(string, string)]) =
  var body = newStmtList()
  copyStmtsInto(body, footerStmts, map)
  dest.add routine(nnkProcDef, newIdent(h & "Footer"), newEmptyNode(),
    newEmptyNode(), body)

proc emitHandle(dest: var seq[NimNode]; sp: Spec; h: string; hasFooter: bool) =
  ## `let h = defineDialog("<name>", DialogSpec(<fields>, body: hBody
  ## [, footer: hFooter]))`.
  var spec = newTree(nnkObjConstr, newIdent("DialogSpec"))
  for a in sp.args:
    spec.add newTree(nnkExprColonExpr, newIdent(a.key), a.val.copyNimTree())
  spec.add newTree(nnkExprColonExpr, newIdent("body"),
    newIdent(h & "Body"))
  if hasFooter:
    spec.add newTree(nnkExprColonExpr, newIdent("footer"),
      newIdent(h & "Footer"))
  dest.add newLetStmt(newIdent(h),
    newCall(newIdent("defineDialog"), newLit(sp.name), spec))

proc expandDialog(n: NimNode; kind: string): NimNode =
  let isForm = kind == "formDialog"
  let args = n
  # args: [head, body]
  if args.len < 1:
    error(kind & ": expected a definition head", n)
  var headNode = args[0]
  var bodyNode: NimNode = nil
  if args.len >= 2 and args[1].kind == nnkStmtList:
    bodyNode = args[1]
  elif args.len == 1:
    # `dialog Name("...")` with no block: an empty body
    bodyNode = newStmtList()
  if bodyNode == nil:
    error(kind & ": expected a body", n)

  let sp = parseSpec(headNode, isForm)
  if sp.error.len > 0:
    error(kind & " `" & sp.handle & "`: " & sp.error, sp.errorAt)
  let h = sp.handle
  var map: seq[(string, string)] = @[]
  if isForm:
    map.add ("submit", h & "Submit")
    map.add ("valid", h & "Valid")
    map.add ("errors", h & "Errors")
    if sp.draft != "draft":
      map.add ("draft", sp.draft)

  # split the body's statements from its `footer:`/`validate:` sections
  let treeBody = newStmtList()
  let treeFooter = newStmtList()
  let treeValidate = newStmtList()
  var anyFooter = false
  var anyValidate = false
  var splitError = ""
  var splitAt: NimNode = bodyNode
  for c in bodyNode:
    if isSection(c, "footer") or isSection(c, "validate"):
      if c[0].strVal == "validate" and not isForm:
        splitError = "a plain dialog has no validate section (use " &
                     "formDialog)"
        splitAt = c
      else:
        if c[0].strVal == "footer":
          anyFooter = true
          copyStmtsInto(treeFooter, c[1], map)
        else:
          anyValidate = true
          for s in c[1]:
            treeValidate.add rewriteMap(s, map)
    else:
      treeBody.add rewriteMap(c, map)
  if splitError.len > 0:
    error(kind & " `" & h & "`: " & splitError, splitAt)

  result = newStmtList()
  var nodes: seq[NimNode] = @[]
  if isForm:
    emitFormProcs(nodes, sp, h, treeValidate, treeBody)
  else:
    emitBodyOnly(nodes, h, treeBody, map)
  if anyFooter:
    emitFooter(nodes, h, treeFooter, map)
  emitHandle(nodes, sp, h, anyFooter)
  for n2 in nodes:
    result.add n2

macro dialog*(head: untyped, body: untyped): untyped =
  ## Define a dialog: its body proc and a `defineDialog` handle.
  expandDialog(newTree(nnkStmtList, head, body), "dialog")

macro formDialog*(head: untyped, body: untyped): untyped =
  ## Define a form dialog: the record round trip, Enter rule and validation
  ## wired around the author's statements.
  expandDialog(newTree(nnkStmtList, head, body), "formDialog")
