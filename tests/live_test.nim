import std/[syncio, strutils, options]
import owl/[objects, reader, evaluator, modules]
import owl/libraries/[base, math, io, fs, loader]
import ./testutils

captureStdio()

# The live layer and projects, loaded from the tree the way owl.nim embeds
# them, against a scratch project on disk.
const dir = "nimcache/owl_live_test"

proc write(path, text: string) =
  try:
    writeFile(path, text)
  except:
    quit "cannot write " & path

proc newLib(): Library {.raises.} =
  result = newLibrary("live-test")
  add(result, baseModule())
  add(result, mathModule())
  add(result, ioModule())
  add(result, fsModule())
  add(result, loaderModule(result))
  add(result, newModule("strings").addFile("src/owl/libraries/strings.owl"))
  add(result, newModule("source").addFile("src/owl/libraries/source.owl"))
  add(result, newModule("live").addFile("src/owl/libraries/live.owl"))
  add(result, newModule("projects").addFile("src/owl/libraries/projects.owl"))
  evaluate(result)

proc forms(src: string): seq[Object] =
  let r = parseOwl(src)
  expect r.isOk, "parse ok: " & r.error("")
  result = r.get(@[])

proc run(lib: Library, src: string): ref Environment =
  clearCaptured()
  try:
    result = runProgram(lib, forms("use io\nuse base\nuse math\nuse fs\nuse modules\nuse source\nuse live\nuse projects\n" & src))
  except:
    expect false, "program should run: " & lastError() & "\n" & src
    result = newEnvironment()

proc run(env: ref Environment, src: string) =
  try:
    discard evalForms(env, forms(src))
  except:
    expect false, "should run: " & lastError() & "\n" & src

proc num(env: ref Environment, name: string): float64 =
  let v = lookup(env, symbol(name))
  expect v.isSome, name & " is bound"
  result = toNumber(v.get(nothing()))

proc text(env: ref Environment, src: string): string =
  result = ""
  try:
    result = stringify(evalForms(env, forms(src)))
  except:
    expect false, "should run: " & lastError() & "\n" & src

proc sourceOf(lib: Library, name: string): string =
  let m = findModule(lib, name)
  result = if m == nil: "" else: m.source

proc patchIn(doc: ref Environment, code: string) =
  try:
    let call = list(@[symbol("patch-module"), str("doc"), str(code)])
    discard eval(call, doc)
  except:
    expect false, "patch should work: " & lastError() & "\n" & code

proc setup() =
  try:
    let lib = newLibrary("setup")
    add(lib, baseModule())
    add(lib, fsModule())
    let env = runProgram(lib, forms("use fs\nmake-dir \"" & dir & "/src\""))
    discard env
  except:
    quit "cannot make " & dir & ": " & lastError()
  write(dir & "/project.owl", "name = \"demo\"\nsource = \"src\"\nmain = \"main\"\n")
  write(dir & "/src/shapes.owl", """use io
use base
use math

count = 0

fun area w h:
    * w h

fun gone:
    1

export:
    area = area
    count = count
""")
  write(dir & "/src/report.owl", """use shapes

fun report w h:
    area w h

export:
    report = report
""")
  write(dir & "/src/main.owl", "use report\n")
  write(dir & "/src/tracker.owl", """use base

unloaded = 0

fun on-unload:
    set unloaded 1

export:
    unloaded = unloaded
""")

setup()

proc projectWorks() {.raises.} =
  let lib = newLib()
  let env = run(lib, """
project = open-project "nimcache/owl_live_test/src"
name = project.name
mods = project-modules project
""")
  expect text(env, "name") == "demo", "the project is found from a directory below it"
  expect text(env, "mods") == "[] main report shapes tracker", "project modules: " & text(env, "mods")
  expect text(env, "parent-dir \"a/b/c.owl\"") == "a/b", "parent-dir"
  expect text(env, "base-name \"a/b/c.owl\"") == "c.owl", "base-name"
  run(env, "load-module \"report\"")
  expect findModule(lib, "shapes") != nil, "use loads a project module from the search path"
  expect sourceOf(lib, "shapes").startsWith("use io"), "the module keeps its text"

proc reloadWorks() {.raises.} =
  let lib = newLib()
  addPath(lib, dir & "/src")
  let env = run(lib, """
load-module "report"
use report
use shapes
before = report 2 3
set count 5
seen = ([])
fun saw s:
    append seen s.defined
on-module "shapes" "reload" saw
""")
  expect num(env, "before") == 6.0, "before the reload"
  write(dir & "/src/shapes.owl", """use io
use base
use math

count = 1
fresh = 42

fun area w h:
    + w h

export:
    area = area
    count = count
    fresh = fresh

echo "ran"
""")
  run(env, "s = reload-module \"shapes\"")
  expect text(env, "s.defined") == "[] area", "changed definitions: " & text(env, "s.defined")
  expect text(env, "s.bound") == "[] fresh", "new bindings are evaluated"
  expect text(env, "s.kept") == "[] count", "a changed binding keeps its value"
  expect text(env, "s.removed") == "[] gone", "a definition the text dropped is unbound"
  expect text(env, "s.ran") == "1", "a new statement runs"
  expect outputLines == @["ran"], "the statement's output: " & outputLines.join("|")
  run(env, "after = report 2 3")
  expect num(env, "after") == 5.0, "a module that uses the reloaded one sees the new definition"
  expect num(env, "count") == 5.0, "state survives the reload"
  expect num(env, "fresh") == 42.0, "a new export reaches users at once"
  expect text(env, "seen") == "[] ([] area)", "an outside hook sees the summary"
  run(env, "rerun-item \"shapes\" \"count\"")
  expect num(env, "count") == 1.0, "rerun-item re-evaluates one binding"
  run(env, "s2 = reload-module \"shapes\"")
  expect text(env, "s2.ran") == "0", "a statement that was there already does not run again"
  expect text(env, "s2.defined") == "[]", "nothing changed"

proc patchWorks() {.raises.} =
  let lib2 = newLib()
  let doc = run(lib2, "new-module \"doc\"")
  patchIn(doc, "use base")
  patchIn(doc, "use math")
  patchIn(doc, "fun sq x:\n    * x x\n")
  patchIn(doc, "hooked = 0\n\nfun on-reload s:\n    set hooked (+ hooked 1)\n")
  patchIn(doc, "sq 4")
  patchIn(doc, "limit = 1")
  patchIn(doc, "limit = 2")
  patchIn(doc, "use io")
  patchIn(doc, "fun sq x:\n    + x x\n")
  expect sourceOf(lib2, "doc") == """use base
use math
use io

fun sq x:
    + x x

hooked = 0

fun on-reload s:
    set hooked (+ hooked 1)

limit = 2
""", "the document text (sq 4 is a query, so it is not recorded):\n" & sourceOf(lib2, "doc")
  patchIn(doc, "fun limit:\n    3\n")
  expect sourceOf(lib2, "doc").endsWith("set hooked (+ hooked 1)\n\nfun limit:\n    3\n"),
    "a binding redefined as a fun is replaced:\n" & sourceOf(lib2, "doc")
  let m = findModule(lib2, "doc")
  if m != nil:
    expect num(m.env, "hooked") >= 5.0, "on-reload runs after each patch"
    run(doc, "drop-item \"doc\" \"sq\"")
    expect not hasOwn(m.env, symbol("sq")), "drop unbinds"
    expect find(m.source, "fun sq") < 0, "and removes the text"
    run(doc, "drop-item \"doc\" \"#3\"")
    expect find(m.source, "use io") < 0, "a use is dropped by position"

proc failedPatchKeepsText() {.raises.} =
  let lib = newLib()
  let doc = run(lib, "new-module \"doc\"")
  var failed = false
  try:
    discard eval(list(@[symbol("patch-module"), str("doc"), str("nope 1")]), doc)
  except:
    failed = true
  expect failed, "a failing statement fails the patch"
  expect sourceOf(lib, "doc") == "", "and is not recorded"

proc switchWorks() {.raises.} =
  let lib = newLib()
  let env = run(lib, """
abs = absolute-path "nimcache/owl_live_test/./src/../"
dotted = absolute-path "/a/b/../../.."
home = absolute-path "~/x"
home-alone = absolute-path "~"
tilde-later = "kept"
try (absolute-path "a/~/b"):
    set tilde-later "refused"
project = project-at "nimcache/owl_live_test"
inside = in-project project (concat project.source "/shapes.owl")
outside = in-project project "/elsewhere/shapes.owl"
use-project project
load-module "tracker"
tracker-scope = module-scope "tracker"
gone = close-project project
paths = (module-paths)
""")
  expect text(env, "abs").endsWith("/nimcache/owl_live_test") and text(env, "abs").startsWith("/"),
    "absolute-path resolves . and .. and drops the trailing slash: " & text(env, "abs")
  expect text(env, "dotted") == "/", ".. never climbs above the root"
  expect text(env, "home") == text(env, "concat (env-var \"HOME\") \"/x\""), "a leading ~ is the home directory"
  expect text(env, "home-alone") == text(env, "env-var \"HOME\""), "~ alone too"
  expect text(env, "tilde-later") == "refused", "a ~ later in a path is refused, never made into a directory"
  expect text(env, "inside") == "true" and text(env, "outside") == "false", "in-project"
  expect text(env, "gone") == "[] tracker", "close-project unloads the project's modules"
  expect findModule(lib, "tracker") == nil, "and forgets them"
  expect text(env, "eval-in tracker-scope (quote unloaded)") == "1", "each gets its on-unload"
  expect text(env, "paths") == "[]", "the source directory leaves the search paths"
  var refused = false
  clearCaptured()
  try:
    discard evalForms(env, forms("project-at \"nimcache\""))
  except:
    refused = true
  expect refused and lastError().contains("no project.owl in"), "project-at needs project.owl in the directory itself"

check("project", projectWorks)
check("switch", switchWorks)
check("reload", reloadWorks)
check("patch", patchWorks)
# A statement is recorded by what it changed in the module, not as history.
proc statementsWork() {.raises.} =
  let lib = newLib()
  let doc = run(lib, "new-module \"doc\"")
  patchIn(doc, "use base")
  patchIn(doc, "tasks = ([])")
  patchIn(doc, "fun add-task t:\n    append tasks ({} (title = t))\n")
  patchIn(doc, "tasks")
  patchIn(doc, "add-task \"a\"")
  patchIn(doc, "add-task \"b\"")
  patchIn(doc, "tasks")
  expect sourceOf(lib, "doc") == """use base

tasks = [] ({} (title = "a")) ({} (title = "b"))

fun add-task t:
    append tasks ({} (title = t))
""", "queries leave no trace; a changed binding is written back as data:\n" & sourceOf(lib, "doc")
  patchIn(doc, "handler = nothing")
  patchIn(doc, "set handler add-task")
  patchIn(doc, "set handler add-task")
  expect sourceOf(lib, "doc").endsWith("handler = nothing\n\nset handler add-task\n"),
    "a change to-code cannot write back keeps the statement, once:\n" & sourceOf(lib, "doc")

check("failed patch", failedPatchKeepsText)
check("statements", statementsWork)

finish "live"
