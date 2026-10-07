## The `ellipse` command line: scaffolding for apps built on the kit.
##
##   ellipse new gui [name]      a new GUI project: Makefile, nimony.paths,
##                               the app's main module and a copy of the fonts
##   ellipse new widget [Name]   a widget in a new module of the project the
##                               current directory is in, imported by the
##                               app's main module
##
## `new` takes what to make next; `game` is reserved for game projects.
##
## Anything left off the command line is asked for, with the default in
## brackets; `--yes` takes every default instead. `ellipse help` lists the
## options.
##
## Generated projects reach the kit through absolute paths (`nimony.paths`
## and the Makefile's `ELLIPSE`), taken from `--ellipse:DIR`, then
## `$ELLIPSE_HOME`, then the checkout this binary was built in
## (`<root>/bin/ellipse`).

import std/[syncio, strutils, os, dirs, envvars]

const
  projectFile = "ellipse.project"
  importsMarker = "# ellipse:imports"

  usageText = """
ellipse -- scaffolding for ellipse apps

Usage:
  ellipse new gui [name] [options]       create a GUI project
  ellipse new widget [Name] [options]    add a widget module to a project
  ellipse help

Values left off the command line are prompted for.

Options for `new gui`:
  --title:TEXT         window title               [Name As Words]
  --desc:TEXT          one-line description
  --dir:DIR            project directory          [./name]
  --width:N            window width               [1280]
  --height:N           window height              [720]

Options for `new widget`:
  --module:NAME        module under src/<app>/    [snake_case of Name]
  --kind:KIND          container, display or focusable   [display]
  --params:LIST        parameters, e.g. "label: string, count: int"
  --desc:TEXT          doc comment for the widget
  --project:DIR        project root               [found from cwd]

Common:
  --ellipse:DIR        the ellipse checkout       [$ELLIPSE_HOME, or this binary's]
  -y, --yes            take defaults, never prompt
  -f, --force          overwrite existing files
"""

type
  Options = object
    command: string
    positional: seq[string]
    keys: seq[string]
    vals: seq[string]
    yes, force: bool

var failMsg = ""

proc fail(msg: string) {.raises.} =
  ## Abort the command; `runCli` prints `msg`.
  failMsg = msg
  raise Failure

## --- arguments ------------------------------------------------------------------

proc parseArgs(args: seq[string]): Options =
  result = Options()
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "-y" or a == "--yes":
      result.yes = true
    elif a == "-f" or a == "--force":
      result.force = true
    elif a == "-h" or a == "--help":
      result.command = "help"
    elif a.startsWith("--"):
      var key = substr(a, 2)
      var val = ""
      var cut = -1
      for j in 0 ..< key.len:
        if key[j] in {':', '='}:
          cut = j
          break
      if cut >= 0:
        val = substr(key, cut + 1)
        key = substr(key, 0, cut - 1)
      elif i + 1 < args.len and not args[i + 1].startsWith("-"):
        inc i
        val = args[i]
      result.keys.add key
      result.vals.add val
    elif result.command.len == 0:
      result.command = a
    else:
      result.positional.add a
    inc i

proc opt(o: Options; key: string): string =
  ## The last value given for `--key`, or "".
  result = ""
  for i in 0 ..< o.keys.len:
    if o.keys[i] == key:
      result = o.vals[i]

proc has(o: Options; key: string): bool =
  result = false
  for k in o.keys:
    if k == key:
      result = true

proc checkKeys(o: Options; allowed: openArray[string]) {.raises.} =
  for k in o.keys:
    var ok = k == "ellipse"
    for a in allowed:
      if k == a:
        ok = true
    if not ok:
      fail("unknown option --" & k & " (see `ellipse help`)")

## --- prompting --------------------------------------------------------------------

proc ask(o: Options; question, def: string): string =
  ## Ask on stdin, showing `def` in brackets; a blank answer (or EOF, or
  ## `--yes`) takes the default.
  if o.yes:
    return def
  stdout.write question
  if def.len > 0:
    stdout.write " [" & def & "]"
  stdout.write ": "
  stdout.flushFile()
  var line = ""
  if not stdin.readLine(line):
    stdout.write "\n"
    return def
  result = line.strip()
  if result.len == 0:
    result = def

proc value(o: Options; key, question, def: string): string =
  ## `--key` when given, else ask.
  if o.has(key): o.opt(key) else: o.ask(question, def)

proc confirm(o: Options; question: string; def: bool): bool =
  if o.yes:
    return def
  let a = o.ask(question & (if def: " (Y/n)" else: " (y/N)"), "").toLowerAscii()
  if a.len == 0: def else: a[0] == 'y'

## --- names ------------------------------------------------------------------------

proc words(s: string): seq[string] =
  ## Split on separators and lower-to-upper case changes:
  ## "statusPill", "status-pill", "Status Pill" -> @["status", "pill"].
  result = @[]
  var cur = ""
  for i in 0 ..< s.len:
    let c = s[i]
    if c in {' ', '-', '_', '.', '\t'}:
      if cur.len > 0:
        result.add cur
        cur = ""
    elif c in {'A'..'Z'} and cur.len > 0 and
         (cur[^1] in {'a'..'z', '0'..'9'} or
          (i + 1 < s.len and s[i + 1] in {'a'..'z'})):
      result.add cur
      cur = $c
    else:
      cur.add c
  if cur.len > 0:
    result.add cur

proc snakeCase(s: string): string =
  result = ""
  for w in words(s):
    if result.len > 0:
      result.add '_'
    result.add w.toLowerAscii()

proc pascalCase(s: string): string =
  result = ""
  for w in words(s):
    result.add capitalizeAscii(w.toLowerAscii())

proc titleCase(s: string): string =
  result = ""
  for w in words(s):
    if result.len > 0:
      result.add ' '
    result.add capitalizeAscii(w)

proc isIdent(s: string): bool =
  ## A Nim identifier that is also a safe module/file name.
  if s.len == 0 or s[0] notin {'a'..'z', 'A'..'Z'} or s[^1] == '_':
    return false
  for i in 0 ..< s.len:
    if s[i] notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      return false
    if s[i] == '_' and i > 0 and s[i - 1] == '_':
      return false
  true

const reserved = ["ellipse", "clay", "owl", "ellipse_ui", "app", "system",
                  "std", "widgets", "ui", "theme"]

proc checkModuleName(what, s: string) {.raises.} =
  if not isIdent(s):
    fail(what & " '" & s & "' isn't usable as a Nim module name " &
         "(letters, digits and single underscores, starting with a letter)")
  for r in reserved:
    if s == r:
      fail(what & " '" & s & "' clashes with an ellipse module")

proc quoteNim(s: string): string =
  ## A Nim string literal.
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    else: result.add c
  result.add '"'

## --- files ------------------------------------------------------------------------

proc fill(tpl: string; keys, vals: openArray[string]): string =
  result = tpl
  for i in 0 ..< keys.len:
    result = result.replace("{{" & keys[i] & "}}", vals[i])

proc writeNew(o: Options; path, content: string; shown = "") {.raises.} =
  ## Write `path`, refusing to clobber a file unless `--force`. `shown` is
  ## the name to report it by.
  let shown = if shown.len > 0: shown else: path
  if fileExists(path) and not o.force:
    fail(shown & " already exists (pass --force to overwrite)")
  try:
    createDir(path(parentDir(path)))
    writeFile(path, content)
  except:
    fail("can't write " & path)
  echo "  created ", shown

proc ellipseRoot(o: Options): string {.raises.} =
  ## The ellipse checkout generated projects build against.
  result = ""
  var cands: seq[string] = @[]
  if o.has("ellipse"):
    cands.add o.opt("ellipse")
  let env = getEnv("ELLIPSE_HOME")
  if env.len > 0:
    cands.add env
  var exe = paramStr(0)
  if '/' notin exe:
    exe = findExe(exe)
  if exe.len > 0:
    cands.add parentDir(parentDir(exe))   # <root>/bin/ellipse
  for c in cands:
    let root = absolutePath(c)
    if fileExists(root / "src" / "ellipse.nim"):
      return root
  fail("can't find the ellipse checkout; pass --ellipse:DIR or set ELLIPSE_HOME")

## --- templates --------------------------------------------------------------------

const mainTpl = """
## {{title}}{{descLine}}
##
## Run:   make run
##        F1 in the window for the debug overlay

import ellipse

{{marker}} -- `ellipse new widget` adds widget modules here

proc view() {.raises.} =
  let t = activeTheme
  clay "root", col(width = grow(), height = grow(), gap = 12,
                   padding = padAll(24)).bg(t.palette.bg):
    heading({{titleLit}}, 1)
    caption("Edit src/{{name}}.nim, then `make run`.")

when isMainModule:
  run App(window: WindowConfig(title: {{titleLit}}, width: {{width}},
                               height: {{height}}),
          view: view)
"""

const makefileTpl = """
# {{title}} -- built against the ellipse checkout below.

ELLIPSE ?= {{root}}
NIMONY  ?= $(ELLIPSE)/build/nimony/bin/nimony

.PHONY: build run clean

build: bin/{{name}}

bin/{{name}}: $(wildcard src/*.nim src/*/*.nim)
	$(NIMONY) --outdir:bin/ c ./src/{{name}}.nim

run: bin/{{name}}
	./bin/{{name}}

clean:
	rm -rf bin nimcache
"""

const pathsTpl = """
{{root}}/build/nimony/src/nimony/lib
{{root}}/src
{{root}}/src/clay
src
"""

const gitignoreTpl = """
bin/
nimcache/
"""

const projectTpl = """
# ellipse project -- read by `ellipse new widget`
app = {{name}}
"""

## --- ellipse new gui ------------------------------------------------------------------

proc newGui(o: Options) {.raises.} =
  o.checkKeys(["title", "desc", "dir", "width", "height"])
  let root = ellipseRoot(o)

  var raw = if o.positional.len > 0: o.positional[0] else: ""
  if raw.len == 0:
    raw = o.ask("App name (module and binary name, e.g. my_notes)", "")
  if raw.len == 0:
    fail("an app name is required")
  let name = snakeCase(raw)
  checkModuleName("app name", name)
  if name != raw:
    echo "  using '", name, "' as the module name"

  let title = o.value("title", "Window title", titleCase(name))
  let desc = o.value("desc", "One-line description", "")
  let dir = o.value("dir", "Project directory", name)
  let width = o.value("width", "Window width", "1280")
  let height = o.value("height", "Window height", "720")
  for (what, v) in [("width", width), ("height", height)]:
    var n = 0
    try:
      n = parseInt(v)
    except:
      n = 0
    if n <= 0:
      fail("window " & what & " must be a positive number, not '" & v & "'")

  if dirExists(dir) and not o.force:
    var empty = true
    for _ in walkDir(path(dir)):
      empty = false
      break
    if not empty and not o.confirm("'" & dir & "' isn't empty. Write into it?", false):
      fail("cancelled")

  echo "Creating ", title, " in ", dir
  let keys = ["name", "title", "titleLit", "descLine", "marker", "width",
              "height", "root"]
  let vals = [name, title, quoteNim(title),
              (if desc.len > 0: " -- " & desc else: ""), importsMarker,
              width, height, root]
  o.writeNew(dir / "src" / (name & ".nim"), fill(mainTpl, keys, vals))
  o.writeNew(dir / "Makefile", fill(makefileTpl, keys, vals))
  o.writeNew(dir / "nimony.paths", fill(pathsTpl, keys, vals))
  o.writeNew(dir / ".gitignore", gitignoreTpl)
  o.writeNew(dir / projectFile, fill(projectTpl, keys, vals))
  createDir(path(dir / "src" / name))

  # The renderer loads assets/fonts/inter relative to the working directory.
  let fonts = root / "assets" / "fonts" / "inter"
  for f in ["Inter-Regular.ttf", "Inter-Medium.ttf", "Inter-SemiBold.ttf",
            "OFL.txt"]:
    if fileExists(fonts / f):
      o.writeNew(dir / "assets" / "fonts" / "inter" / f, readFile(fonts / f))

  echo ""
  echo "Next:"
  echo "  cd ", dir
  echo "  make run"
  echo "  ellipse new widget      # add a widget module"

## --- ellipse new widget ---------------------------------------------------------------

type Param = object
  name, typ: string

proc parseParams(s: string): seq[Param] {.raises.} =
  ## "label: string, count: int" -> the pairs. Commas inside brackets or
  ## parens (`seq[Table[string, int]]`, `proc(a, b: int)`) don't split.
  result = @[]
  var parts: seq[string] = @[]
  var cur = ""
  var depth = 0
  for c in s:
    if c in {'[', '('}: inc depth
    elif c in {']', ')'}: dec depth
    if (c == ',' or c == ';') and depth == 0:
      parts.add cur
      cur = ""
    else:
      cur.add c
  parts.add cur
  for p in parts:
    let t = p.strip()
    if t.len == 0:
      continue
    let colon = t.find(':')
    if colon <= 0:
      fail("parameter '" & t & "' needs a type, like 'label: string'")
    let n = substr(t, 0, colon - 1).strip()
    let ty = substr(t, colon + 1).strip()
    if not isIdent(n) or ty.len == 0:
      fail("can't read parameter '" & t & "'")
    if n == "id" or n == "tabIndex" or n == "body":
      fail("'" & n & "' is supplied by the widget kind; pick another name")
    result.add Param(name: n, typ: ty)

proc findProject(o: Options): string {.raises.} =
  result = ""
  if o.has("project"):
    let p = absolutePath(o.opt("project"))
    if not fileExists(p / projectFile):
      fail(p & " has no " & projectFile & " (create one with `ellipse new gui`)")
    return p
  var d = os.getCurrentDir()
  while true:
    if fileExists(d / projectFile):
      return d
    let up = parentDir(d)
    if up.len == 0 or up == d:
      break
    d = up
  fail("not inside an ellipse project (no " & projectFile &
       " here or above); run `ellipse new gui` or pass --project:DIR")

proc projectApp(dir: string): string {.raises.} =
  result = ""
  for line in readFile(dir / projectFile).splitLines():
    let t = line.strip()
    if t.startsWith("app") and '=' in t:
      result = substr(t, t.find('=') + 1).strip()
  if result.len == 0:
    fail(dir / projectFile & " doesn't name the app (app = <name>)")

proc widgetSource(widget, module, kind, desc: string;
                  params: seq[Param]): string =
  var sig = ""
  for p in params:
    if sig.len > 0: sig.add ", "
    sig.add p.name & ": " & p.typ
  var lines: seq[string] = @[]
  lines.add "## " & module & " -- the `" & widget & "` widget."
  lines.add ""
  lines.add "import ellipse"
  lines.add ""

  # the body paints each string parameter, so the stub shows its inputs
  var shown: seq[string] = @[]
  for p in params:
    if p.typ == "string":
      shown.add p.name

  case kind
  of "container":
    if sig.len > 0: sig.add ", "
    lines.add "widget " & widget & "(" & sig & "body: proc(): void):"
    lines.add "  ## " & (if desc.len > 0: desc else: "A panel around the caller's block:")
    lines.add "  ##"
    lines.add "  ##   " & widget & "(...):"
    lines.add "  ##     text(\"inside\")"
    lines.add "  let t = activeTheme"
    lines.add "  container(col(width = grow(), height = fit(), gap = t.metrics.gapCard,"
    lines.add "      padding = padAll(t.metrics.padCard))"
    lines.add "    .bg(t.palette.panelBg)"
    lines.add "    .border(t.metrics.borderHairline, t.palette.panelBorder)"
    lines.add "    .corner(t.radii.card)):"
    for s in shown:
      lines.add "    text(" & s & ")"
    lines.add "    body()"
  of "focusable":
    lines.add "widget focusable " & widget & "(" & sig & ") -> bool:"
    lines.add "  ## " & (if desc.len > 0: desc else:
      "A focus stop. Returns true in the frame it was clicked or activated " &
      "with Space/Enter.")
    lines.add "  let t = activeTheme"
    lines.add "  let over = pointerOver(id)"
    lines.add "  item(id, row(width = fit(), height = fit(), gap = 8,"
    lines.add "      padding = padAll(t.metrics.padMinor), alignY = centerY)"
    lines.add "    .bg(if over: t.palette.buttonHoverBg else: t.palette.buttonBg)"
    lines.add "    .corner(t.radii.card)"
    lines.add "    .focusRing(id)):"
    if shown.len == 0:
      lines.add "    text(" & quoteNim(widget) & ")"
    for s in shown:
      lines.add "    text(" & s & ")"
    lines.add "  result = clickedIn(id) or keyActivated(id)"
  else:
    lines.add "widget " & widget & "(" & sig & "):"
    lines.add "  ## " & (if desc.len > 0: desc else: widget & ".")
    lines.add "  let t = activeTheme"
    lines.add "  container(col(width = grow(), height = fit(), gap = t.metrics.gapTight,"
    lines.add "      padding = padAll(t.metrics.padMinor))):"
    if shown.len == 0:
      lines.add "    text(" & quoteNim(widget) & ")"
    for s in shown:
      lines.add "    text(" & s & ")"
  result = lines.join("\n") & "\n"

proc usageExample(widget, kind: string; params: seq[Param]): string =
  var args: seq[string] = @[]
  if kind == "focusable":
    args.add "id = hashId(" & quoteNim(snakeCase(widget)) & ")"
  for p in params:
    args.add p.name & " = " & (if p.typ == "string": quoteNim(titleCase(p.name)) else: "...")
  result = widget & "(" & args.join(", ") & ")"
  case kind
  of "container": result.add ":\n      text(\"inside\")"
  of "focusable": result = "if " & result & ":\n      discard"
  else: discard

proc newWidget(o: Options) {.raises.} =
  o.checkKeys(["module", "kind", "params", "desc", "project"])
  let proj = findProject(o)
  let app = projectApp(proj)

  var raw = if o.positional.len > 0: o.positional[0] else: ""
  if raw.len == 0:
    raw = o.ask("Widget name (e.g. StatusPill)", "")
  if raw.len == 0:
    fail("a widget name is required")
  let widget = pascalCase(raw)
  if not isIdent(widget):
    fail("widget name '" & raw & "' isn't a Nim identifier")
  if widget != raw:
    echo "  using '", widget, "' as the widget name"

  let module = snakeCase(o.value("module", "Module (src/" & app & "/<module>.nim)",
                                 snakeCase(widget)))
  checkModuleName("module", module)

  var kind = o.value("kind",
    "Kind: display (no block), container (takes a block), focusable (clickable focus stop)",
    "display").toLowerAscii()
  case kind
  of "d", "display": kind = "display"
  of "c", "container": kind = "container"
  of "f", "focusable": kind = "focusable"
  else: fail("kind must be display, container or focusable, not '" & kind & "'")

  let params = parseParams(o.value("params",
    "Parameters (e.g. label: string, count: int)", "label: string"))
  let desc = o.value("desc", "Description", "")

  let rel = "src" / app / (module & ".nim")
  o.writeNew(proj / rel, widgetSource(widget, module, kind, desc, params), rel)

  # import it from the main module, under the marker `ellipse new gui` wrote
  let mainRel = "src" / (app & ".nim")
  let main = proj / mainRel
  let imp = "import " & app & "/" & module
  if fileExists(main):
    let src = readFile(main)
    if imp in src:
      discard
    elif importsMarker in src:
      # after the marker and the imports already under it
      var outLines: seq[string] = @[]
      var pending = false
      for line in src.splitLines():
        if pending and not line.startsWith("import "):
          outLines.add imp
          pending = false
        outLines.add line
        if line.startsWith(importsMarker):
          pending = true
      if pending:
        outLines.add imp
      try:
        writeFile(main, outLines.join("\n"))
      except:
        fail("can't write " & main)
      echo "  updated ", mainRel
    else:
      echo "  add `", imp, "` to ", mainRel

  echo ""
  echo "Use it in a view:"
  echo "    ", usageExample(widget, kind, params)

proc newThing(o: Options) {.raises.} =
  ## `ellipse new <what> ...`: the first positional says what to make.
  var o = o
  var what = ""
  if o.positional.len > 0:
    what = o.positional[0]
    var rest: seq[string] = @[]
    for i in 1 ..< o.positional.len:
      rest.add o.positional[i]
    o.positional = rest
  else:
    what = o.ask("What to make (gui, widget)", "")
  case what.toLowerAscii()
  of "gui":
    newGui(o)
  of "widget":
    newWidget(o)
  of "game":
    fail("`new game` isn't supported yet")
  of "":
    fail("say what to make: `ellipse new gui` or `ellipse new widget`")
  else:
    fail("can't make '" & what & "'; try `ellipse new gui` or `ellipse new widget`")

## --- entry ------------------------------------------------------------------------

proc runCli*(args: seq[string]): int =
  ## Run the CLI over `args` (without the program name); the exit code.
  let o = parseArgs(args)
  try:
    case o.command
    of "new":
      newThing(o)
    of "", "help":
      stdout.write usageText
    else:
      stdout.write "ellipse: unknown command '" & o.command & "'\n\n"
      stdout.write usageText
      return 2
    result = 0
  except:
    stdout.write "ellipse: " & (if failMsg.len > 0: failMsg else: "failed") & "\n"
    result = 1
