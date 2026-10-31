# Integrating Owl into a Nim project

Owl is not only a language and a CLI: the interpreter is a handful of plain Nim
modules you can link into any program. Embed it and your app gets a scripting
layer -- a `Library` of modules, some written in Owl and loaded from disk or
embedded at compile time, some bound directly to Nim procs. Owl calls your
Nim functions through *builtins*; you call Owl's functions back through
`invoke`. Data crosses the border as `Object` values, by hand or automatically
through `owl/serde`.

Companions: [owl-examples.md](owl-examples.md) (the language itself, in Owl),
[nim-tutorial.md](nim-tutorial.md) (the GUI toolkit the `gui` module wraps),
[reference-widgets.md](reference-widgets.md) (widget signatures).

- [0. The mental model](#0-the-mental-model)
- [1. Getting Owl into your build](#1-getting-owl-into-your-build)
- [2. A minimal host](#2-a-minimal-host)
- [3. Native modules: binding Nim functions](#3-native-modules-binding-nim-functions)
- [4. Arguments, blocks and commands](#4-arguments-blocks-and-commands)
- [5. Loading Owl code: paths, files, embedding](#5-loading-owl-code-paths-files-embedding)
- [6. Calling Owl from Nim](#6-calling-owl-from-nim)
- [7. Values by hand: the Object API](#7-values-by-hand-the-object-api)
- [8. Conversion for free: owl/serde](#8-conversion-for-free-owlserde)
- [9. Errors across the border](#9-errors-across-the-border)
- [10. A complete integration](#10-a-complete-integration)

---

## 0. The mental model

Four types carry the whole embedding surface:

- **`Object`** (`owl/objects`) -- one Owl value. All numbers are `float64`;
  strings, symbols, booleans, lists, records, pairs, and *commands* (anything
  callable, including your bound Nim procs) are Objects too.
- **`Environment`** (`owl/objects`) -- a scope: a chain of name-to-`Object`
  bindings plus imported module exports. Programs run inside one; builtins
  receive the caller's.
- **`Module`** (`owl/modules`) -- a namespace. It holds an `Environment`, a
  list of forms, and a set of exports. A module is native when Nim fills its
  environment with builtins, and scripted when Owl source is added to it --
  often both.
- **`Library`** (`owl/modules`) -- the registry of modules `use` lines resolve
  against, plus the search paths for `.owl` files.

The loop an embedded host lives in:

```
build Library ──► runProgram(lib, forms) ──► read bindings / invoke functions
        ▲                                            │
        └──── native modules ◄─── Owl code calls builtins, which call Nim
```

`runProgram` evaluates every module the program `use`s (dependencies first,
each module exactly once), hoists its `fun`/`command` definitions, imports the
`use`d modules into a fresh environment, and evaluates the rest of the
program's forms there. It hands you back that environment -- read it, drive it
from your frame loop, and Owl's code drives you through the builtins you
installed.

---

## 1. Getting Owl into your build

The interpreter lives in `src/owl/` and is plain Nim -- no nimble package of
its own yet. Point your build at the tree that holds it:

```nim
# config.nims of your project
when withDir(thisDir(), system.fileExists("../ellipse/src/owl/owl.nim")):
  switch("path", thisDir() & "/../ellipse/src")
```

or pass the flag per invocation, exactly as this repo's Makefile does:

```sh
nim --path:../ellipse/src c my_app.nim
```

Owl needs `nim >= 2.4.0`. Import the pieces you use:

```nim
import owl/[objects, reader, evaluator, modules, serde, errors]
import owl/libraries/[base, math, io, term]
```

Which modules to import matters for your dependencies:

- `owl/objects`, `owl/reader`, `owl/evaluator`, `owl/modules` -- the core:
  values, the reader, the evaluator, libraries and modules. No third-party
  links.
- `owl/serde` -- Nim-to-Owl conversion (§ 8).
- `owl/errors` -- source places and the rendered error box.
- `owl/libraries/*` -- the native side of the standard modules: `base`,
  `math`, `io`, `fs`, `net`, `term`, `loader`, `gui`. Each is a separate
  module file, so you pay only for what you add. **`gui` is the exception**:
  it bridges the `ellipse_ui` toolkit and links SDL3 -- see § 10 for wiring
  it up.
- `owl/library` -- `owlLibrary()`, the whole set the `owl` CLI ships,
  including the embedded Owl-written modules (`strings`, `iterators`, `tui`,
  `repl`, ...). Convenient, and it pulls `gui` (and the toolkit) in with it.
  Hand-assemble your `Library` when you want a lean binary.

Import the `Object` type with care in modules that also use `strutils`: Owl's
constructors are `str`, `number`, `symbol`, and friends. Qualifying as
`owl.Object` / `owl.str`, as `ellipse/scenes` does, avoids the collisions.

---

## 2. A minimal host

This is the smallest useful embedding: a library with the two core native
modules, a script that computes a value, and Nim reading it back.

```nim
import std/[options, syncio]
import owl/[objects, reader, evaluator, modules, errors]
import owl/libraries/[base, math]

proc main() =
  let lib = newLibrary("my-app")
  lib.add baseModule()
  lib.add mathModule()

  let source = """
use base
use math

fun double x:
    (* x 2)

total = (double (+ 10 32))
"""
  let env = runProgram(lib, readSource(source, "main.owl"))
  echo "total = ", lookup(env, symbol("total")).get().stringify

when isMainModule:
  colorErrors = stderrIsTerminal()   # from owl/libraries/term
  try:
    main()
  except:
    flushFile(stdout)
    reportError()
    quit 1
```

The language is uniformly prefix: every call is a line whose head is the
callee -- `(+ 10 32)`, and `(double (+ 10 32))` when a call feeds another
call -- so there is no infix arithmetic like `x * 2`.

- `newLibrary(name)` starts an empty registry. `owlLibrary()` gives you the
  full CLI set instead (§ 1).
- `readSource(source, name)` is the reader: text to `seq[Object]` forms,
  raising a `ReadError` on bad syntax. `readForms` is the non-raising cousin,
  returning `Result[seq[Object], OwlError]`.
- `runProgram(lib, forms): ref Environment` evaluates the library's modules
  and then the program's forms, and returns the program's scope.
- `lookup(env, symbol("total"))` finds the binding -- `Option[Object]`,
  visible through imports too. `define(env, name, value)` is the setter,
  `has(env, name)` the guard.
- The `try / except / reportError` wrapper is what the `owl` CLI itself uses:
  every Owl failure is a `ValueError` whose message was already recorded as an
  `OwlError` with a source place. `reportError()` prints the error box with
  file, line, column and call trace. § 9 covers the variants.

To feed the interpreter arguments, bind names *before* running:

```nim
define(env, symbol("input-file"), str(getParamStr(1)))
```

and the program reads `input-file` as a plain binding. There is also
`evalForms(env, forms)` for evaluating a snippet in a scope you already hold,
and `eval(form, env)` for a single form -- what every builtin uses on its
arguments (§ 4).

---

## 3. Native modules: binding Nim functions

A native module is a `Module` whose environment Nim fills. The unit of binding
is a **builtin**: a `CommandProc`.

```nim
type CommandProc* = proc (env: ref Environment, args: seq[Object], bodyStart: int): Object
```

A builtin receives the *caller's* environment, the call's raw argument forms,
and the index where a `:` block starts. It evaluates what it needs and returns
an `Object`. Bind one with `addBuiltin`:

```nim
import std/[strutils]
import owl/[objects, evaluator, modules]

proc upperBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  if args.len != 1:
    err("upper needs one string")
  let value = eval(args[0], env)          # arguments arrive un-evaluated
  if not isString(value):
    errAt(args[0], "upper needs a string, got " & stringify(value))
  str(toStr(value).toUpperAscii())

proc textModule*(): Module =
  result = newModule("text")
  result = result
    .addBuiltin("upper", upperBuiltin, true)   # isFun: true
    .addExport("greeting", str("hello"))
```

`addBuiltin(name, proc, isFun)` defines `<name>` in the module's environment
and exports it; `addExport(name, value)` exports any value -- constants,
prebuilt records, commands. All the builder procs (`addBuiltin`, `addExport`,
`addSource`, `addForm`, ...) return the module, so they chain. Owl side:

```owl
use io
use text

print (upper "shout")     # SHOUT
print greeting            # hello
```

The `isFun` flag marks the builtin as a `fun` (a value-producing call, usable
anywhere an expression is expected, a `&block` parameter becomes a closure) or
a `command` (a statement: called bare, arguments stay lazy, a trailing `:`
block arrives as raw forms). The builtins in the standard library follow the
language's own split: `+`, `concat`, `find`, `slice` are funs; `while`,
`cond`, `set`, `try` are commands; the `gui` module binds layout elements like
`row` and `button` as commands and interaction checks like `hovered` as funs.
Arguments and blocks in either flavor -- § 4.

**The install pattern.** The standard modules define into a bare environment
and then export everything, which is what `baseModule()` does:

```nim
proc installBase*(env: ref Environment) =
  define(env, symbol("argv"), argvValue())
  define(env, symbol("nothing"), nothing())
  define(env, symbol("concat"), newBuiltin("concat", concatBuiltin, true))
  define(env, symbol("while"), newBuiltin("while", whileBuiltin, false))
  # ...

proc baseModule*(): Module =
  result = newModule("base")
  installBase(result.env)
  exportAllBindings(result)
```

Use `define(env, symbol(name), newBuiltin(name, proc, isFun))` plus
`exportAllBindings(module)` when you have many bindings: `exportAll` makes the
module's exports *dynamic*, so names defined later -- by Owl source or by
Nim -- are visible to importers too. Plain `addExport` registers one explicit
name.

**Native plus Owl source.** A module can hold both: builtins installed in its
environment *and* Owl forms that use them. That is how `gui` ships its Nim
bridge and its Owl-level widget layer as one `use gui`:

```nim
proc guiModule*(source: string): Module =
  # The Nim builtins and gui.owl in one module: `use gui` gives both.
  result = newModule("gui")
  installGui(result.env)
  exportAllBindings(result)
  result = addLibrarySource(result, source)
```

The Owl forms see the builtins in the shared `env`; importers see all of it.

---

## 4. Arguments, blocks and commands

Three rules explain every builtin in the tree:

1. **Arguments are forms, not values.** The evaluator hands you the call's
   operands unevaluated and lets you choose when and where to evaluate:
   `let v = eval(args[0], env)`. A `fun` builtin normally evaluates all of
   them; a `command` builtin like `when` or `try` evaluates only the branch it
   takes -- that laziness is exactly why the signature works this way.
   `numberIn(env, form, "floor")` and `numbersIn(env, args, "arithmetic")`
   are evaluator helpers that evaluate and type-check numbers in one step.
2. **`bodyStart` splits arguments from the `:` block.** In a call
   `name arg0 (key = arg1): block-forms`, `args` holds everything after the
   head; the forms from `bodyStart` on (when `bodyStart >= 0 and bodyStart <
   args.len`) are the block's contents. Without a block, `bodyStart` equals
   `args.len`.
3. **`(name = value)` pairs are options.** A Pair whose head is a symbol is a
   named argument; anything else is positional.

The canonical unpacker is the `Args` struct from `gui` -- copy the shape:

```nim
import std/tables

type
  Args = object
    pos: seq[Object]                 # positional values, evaluated
    named: Table[string, Object]     # (name = value) options, evaluated
    blk: seq[Object]                 # the `:` block's raw forms
    env: ref Environment

proc parseArgs(env: ref Environment, args: seq[Object], bodyStart: int): Args =
  result = Args(pos: @[], named: initTable[string, Object](), blk: @[], env: env)
  let stop = if bodyStart >= 0 and bodyStart < args.len: bodyStart else: args.len
  for i in 0 ..< stop:
    let a = args[i]
    if isPair(a) and isSymbol(car(a)):
      result.named[toSymbol(car(a))] = eval(cdr(a), env)
    else:
      result.pos.add eval(a, env)
  for i in stop ..< args.len:
    result.blk.add args[i]
```

A complete command builtin with options and a block -- say, a repeat N times:

```nim
proc timesBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  let a = parseArgs(env, args, bodyStart)
  if a.pos.len != 1:
    err("times needs a count")
  if not isNumber(a.pos[0]):
    err("times needs a number, got " & stringify(a.pos[0]))
  let n = int(toNumber(a.pos[0]))
  for i in 0 ..< n:
    # Run the block in a child of the caller's scope: the block sees the
    # caller's bindings, its own definitions stay local.
    discard evalForms(newEnvironment(a.env), a.blk)
  nothing()
```

```owl
use io
use base
# (with `times` installed as a command builtin)

times 3:
    print "again"
```

The two ways to *do* something with a block:

- **Run it now**: `evalForms(newEnvironment(a.env), a.blk)`. The `env` you
  were handed is the caller's scope.
- **Keep it for later**: wrap it in a closure with `newCommand`:

  ```nim
  let fun = newCommand("", newSeq[Object](), a.blk, a.env, true)
  # ... stored, then invoked on a later frame:
  discard invoke(fun, @[])
  ```

  This is `blockFn`/`slotOf` in the `gui` bridge: a widget's block becomes a
  fun over the caller's scope, re-invoked every frame. Because it evaluates
  lazily, later definitions in the caller's environment are visible when it
  finally runs -- hot-reload-friendly.

Returning values: every builtin returns an `Object`; `nothing()` is the
statement answer. To return a fresh list/record/pair, build it with the
constructors from § 7.

---

## 5. Loading Owl code: paths, files, embedding

Modules get their Owl forms from three places.

**From disk, on demand.** `lib.addPath(dir)` appends a search path; any
`use name` -- in a program or in another module -- finds `name.owl` in those
directories, adds it as a module, reads its own `use` lines for dependencies,
and evaluates it before the importer runs.

```nim
let lib = newLibrary("my-app")
lib.add baseModule()
lib.add mathModule()
lib.addPath "scripts"        # `use helpers` now finds scripts/helpers.owl
```

`require(lib, name)` is the same pipeline from the Nim side: ensure loaded,
ensure evaluated, hand back the `Module`. `unload(lib, name)` runs the
module's `on-unload` command and drops it; requiring it again re-reads the
file -- this is the hot-reload lever (the `live` module and `owl/watch`'s file
watchers are what the REPL builds on it).

**From a file, eagerly.** `newModule("cfg").addFile("config.owl")` reads at
build-of-library time. Good for app-level scripts that should exist under a
known name regardless of search paths.

**From a string, at compile time.** `embedFile(path)` (from `owl/embedfile`)
inlines a file's contents as a Nim string literal, resolved relative to the
importing `.nim` file, so the binary carries its scripts:

```nim
import owl/embedfile

lib.add newModule("cli").addLibrarySource(embedFile("scripts/cli.owl"))
```

The `owl` CLI embeds its whole standard library this way -- the language does
not depend on files at runtime.

`addSource(module, text)` vs `addLibrarySource(module, text)`: identical
parse, different marking. Library source is `internal`, and `renderError`
skips internal frames when the user's own file is in the trace -- library code
that throws points at the user's call, not at a line inside `base.owl`. Use
`addLibrarySource` for anything shipped inside your binary, `addSource` for
app scripts the user edits.

**Module lifecycle.** After a module's forms evaluate, `runHook(m, "on-load",
@[])` runs its `on-load` command if defined; `unload` runs `on-unload` first.
Owl-side, a module just defines them:

```owl
use base

command on-load:
    print "hello from" "helpers"

command on-unload:
    print "bye"
```

`evaluateModule` runs deps first, and each module evaluates exactly once;
`runProgram` and `require` both go through it.

---

## 6. Calling Owl from Nim

You have three doors into Owl code, all in `owl/evaluator` and `owl/modules`.

**Read a binding.** After `runProgram` returns the program's environment:

```nim
var count = 0.0
let found = lookup(env, symbol("count"))
if found.isSome:
  count = toNumber(found.get())
```

`lookup` walks the scope chain and imports; `hasOwn` / `allBindings` are there
when you need to enumerate or avoid inherited names. `assign(env, name, value)`
updates an existing binding wherever it lives; `define` creates one in `env`.

**Call an exported function.** Get the module, pull the export out, invoke it
with *values*:

```nim
let m = require(lib, "ui")
let view = m.exportValue("view")          # Option[Object]
if view.isSome and isCommand(view.get()):
  discard invoke(view.get(), @[number(frameTime), str("tick")])
```

`invoke(cmd, values)` is the callback entry point: it packs already-evaluated
Objects into a scratch environment and applies the command, so the callee
sees its parameters bound to your values. `values` is a `seq[Object]`; pass
`@[]` for no arguments. Calling something that is not a command raises
through the Owl error machinery ("cannot call ..., it is not a command").
`m.exportNames()` lists what a module offers; `runHook(m, "on-load", args)`
calls a lifecycle-style command by name if it exists, silently otherwise.

**Evaluate a snippet.** Build a scope, install what it needs, run forms:

```nim
let env = newEnvironment()
installBase(env)
installMath(env)
let value = evalForms(env, readSource("(+ 1 2)", "<snippet>"))
```

That is how `serde`'s tests evaluate data, how the settings module reads a
file, and a fine way to run one-shot expressions. `newEnvironment(up)` also
chains scopes when you want a child environment over a module's or program's.

The round trip, one picture:

```
Nim state ──define/encode──► Environment ──lookup/exportValue──► invoke ──► Object ──decode──► Nim state
   ▲                                                                                          │
   └──────────────── builtins: Owl code calls back, same env, same values ◄──────────────────┘
```

---

## 7. Values by hand: the Object API

`Object` is a tagged union over the ten kinds Owl's reader produces. For
gluing one or two values across the border, use the constructors and accessors
in `owl/objects` directly.

| | build (Nim → Owl) | read (Owl → Nim) |
|---|---|---|
| absence | `nothing()` | `isNothing(o)` |
| number | `number(2.5)` | `toNumber(o)` (numbers and `true` convert; else 0.0) |
| text | `str("hello")` | `toStr(o)` (empty for non-strings) |
| bare name | `symbol("x")` | `toSymbol(o)` (empty for non-symbols) |
| truth | `boolean(true)` | `toBool(o)` (only `nothing` and `false` are false) |
| list | `list(@[number(1), number(2)])` | `toSeq(o)`, `itemCount(o)`, `itemAt(o, i)` |
| pair | `pair(symbol("key"), number(1))` | `car(o)`, `cdr(o)` |
| record | `record(@[pair(symbol("w"), number(80))])` | `field(o, "w")`, `hasField(o, "w")`, `recordFields(o)` |
| callable | `newCommand(name, params, body, env, isFun)` | `cmdName`, `cmdParams`, `cmdBody`, `isCommand`, `isBuiltin` |
| any, kind | `objectKind(o)` | `kindName(o)` → `"number"`, `"list"`, ... |

Two renderings of any Object:

- `stringify(o)` -- display text (`"hello"`, `80`, `true`, `fun name` prints
  as `<fun name>`); what `print` shows and `to-string` returns.
- `toCode(o, width = 80)` -- valid Owl source, line-wrapped: what `owlText`
  uses (§ 8), and what the `live`/repl machinery round-trips values through.

A worked hand conversion, from `ellipse/scenes` -- persisting a scene stack
through an Owl file. `serde` covers plain shapes; a `HashSet` is not a shape
it knows, so this module writes `toOwl`/`fromOwl` overloads:

```nim
proc toOwl(ids: HashSet[SceneID]): owl.Object =
  var xs: seq[owl.Object] = @[]
  for id in ids:
    xs.add str(id)
  result = list(xs)

proc fromOwl*(v: owl.Object, sceneStack: var SceneStack) =
  doAssert v.isRecord
  v.field("load").fromOwl(sceneStack.load)
  v.field("push").fromOwl(sceneStack.push)
  # ...
```

and the record itself is built one `pair(symbol(...), ...)` at a time. The
pattern: one `toOwl` overload per type, pairs of (field name, value) for
records, `field("name")` on the way back.

For *tolerant* reads of user-supplied data, prefer serde's `want*` accessors
(§ 8) over the raw `to*` ones: `toStr` silently returns `""` when given a
number, while `wantText` raises a positioned error.

---

## 8. Conversion for free: owl/serde

Hand-building pays when a value is ad-hoc. When the thing crossing the border
is a Nim `object`, `tuple`, `seq`, `Table`, or a plain scalar, use
`owl/serde`: `encode` turns *any Nim value* into an `Object` the way an Owl
program would hold it, and `decode` reads it back into a Nim value of your
type.

```nim
import std/tables
import owl/serde

type
  Colour = enum red, green, blue
  Monitor = object
    name: string
    width: int
    scale: float
  Layout = object
    monitors: seq[Monitor]
    selected: Option[int]
    tags: Table[string, int]

let cfg = Layout(
  monitors: @[Monitor(name: "main", width: 1920, scale: 1.0)],
  selected: some(0),
  tags: {"work": 1}.toTable)

let data = encode(cfg)                  # Layout  --> Object
var back = decode(data, Layout)          # Object  --> fresh Layout
```

`decode(data, T)` is the fresh-value form; `decode(data, var x)` fills an
existing `x` and **leaves whatever `x` already held for the fields the data
does not carry** -- so loading an older file into a newer type keeps the new
fields' defaults, and `decodeValue(data, T)`/`decode(data, T)` are the same
thing from either spelling.

The shape mapping (from the module header, worth knowing exactly):

| Nim | Owl data |
|---|---|
| `bool` | `true` / `false` |
| `enum`, `char` | quoted string (`"red"`, `"a"`) |
| integers, floats | number -- *or* a string, when Owl cannot spell the value back (huge integers, `1.0e20`, `nan`) |
| `string` | string |
| `distinct T` | whatever the base type encodes to |
| `Option[T]` | the value, or `nothing` |
| `set[T]`, `seq`, `array`, unnamed tuples | list |
| named tuples, `object`, `ref object` | record: `{}` with `name = value` fields; a nil ref is `nothing` |
| `Table`/`OrderedTable` | record while every key spells an Owl name; otherwise a list of `[key value]` pairs |

Reading is forgiving in exactly the places files differ from their writer:
numbers from text (big integers parsed digit-exact), enums from any spelling
that matches, characters from a one-character string, and bare names read
into any field that holds text -- hand-written files load. Unknown field
names fail, listing the type they were looked for in.

Case objects work: decoding fills the discriminant, and a file that asks for
another branch rebuilds the object, carrying over the fields both branches
share.

**Writing and reading files.** `owlText(cfg, width = 80)` renders an encoded
value as Owl source -- the whole settings file:

```nim
import std/syncio          # readFile / writeFile
# installBase lives in owl/libraries/base: import it here like § 2.

writeFile("layout.owl", owlText(cfg))

# ... next start: evaluate the file in a scope that can spell records,
# then decode. `installBase` is what defines `{}` and `[]` as the data shapes.
var cfg2 = Layout()                        # defaults stay in for absent fields
let data = newEnvironment()
installBase(data)
let forms = readSource(readFile("layout.owl"), "layout.owl")
decode(evalForms(data, forms), cfg2)
```

Note what this means: `{}` and `[]` in the reader output are calls to the
`base` module's record and list builders, so even a pure-data file evaluates
only where those names are visible -- a `use base` in a program, or
`installBase(env)` in a scope like the one above. `owl/settings` runs files
in exactly such a restricted environment (base's names and none more), with
file watching (`owl/watch`) and hot reload folded in: edit the file, the
decoded config updates live.

**Custom shapes.** A type that wants different data overrides the two hooks,
the way jsony uses `objectToJson`/`jsonToObject`:

```nim
proc asOwl*(t: Theme): Object =
  record(@[pair(symbol("color"), str(t.colorHex))])

proc asNim*(o: Object, t: var Theme) =
  t.colorHex = wantText(o.field("color"))
```

and two field-level hooks trim the default code instead of replacing it:
`fieldName*(obj, name)` renames a field in the file, `ignoreField*(obj, name)`
drops it. **The catch**, straight from the module header: the hooks are found
by `compiles` *where `encode`/`decode` is called*. Define them next to the
type and import the module that holds them at every call site -- otherwise
the generic mapping silently wins and you wonder why `asOwl` never runs.

**Failures.** Bad data raises through the Owl error machinery with the place
of the offending value, and serde keeps a path trail while it walks, so the
message says where: `monitors/0/width: expected a number, got the string
"wide"`. Catch at the top (§ 9) or locally with `try` -- the conversion
functions also answer to the `want*` helpers when you need them for a single
field read: `wantNumber`, `wantText`, `wantBool`.

---

## 9. Errors across the border

Every failure in Owl-land -- reader, evaluator, `err` from your builtin, a
failed `decode` -- is an `OwlError` recorded in module state *and* a raised
`ValueError`. The types (in `owl/errors`): `ErrorKind` of `ReadError` /
`CompileError` / `RuntimeError`, a `Place` (source file, offset, length), and
a call trace of up to 12 frames.

Raising from a builtin:

```nim
if not isNumber(value):
  errAt(args[0], "times needs a number, got " & stringify(value))
```

`err(msg)` is a bare runtime error; `errAt(form, msg)` anchors it at the
form's source position so the report shows the line and column with a `^^^`
caret inside the user's file. Don't `echo` and return `nothing()` -- raise,
and the machinery puts your message in the right box with the right place.

Catching at the top, the CLI's own shape:

```nim
when isMainModule:
  colorErrors = stderrIsTerminal()          # owl/libraries/term
  try:
    start()
  except:
    flushFile(stdout)
    reportError()                           # writes the error box to stderr
    quit 1
```

Variants: `errorText(color)` returns the rendered box as a string instead of
printing it; `errorReport = proc(msg: string) = ...` redirects where
`reportError` sends it -- a GUI host points it at its log pane or status bar.
`stderrIsTerminal()` lives in `owl/libraries/term`, the same module that
binds terminal queries for Owl code.
`currentError` holds the raw `OwlError` (kind, message, place, trace) when
you want to inspect rather than render, and `lastErrorMessage` its text.
`sealError()` stops the evaluator from filling in a closer place -- the
library calls it when a module boundary or `runProgram` already knows where
the failure belongs.

Errors thrown *from* Owl into Nim and re-thrown back are a hazard in frame
loops: a Nim callback that invokes an Owl fun catches the `ValueError` far
from the evaluator, and the recorded place can get overwritten before the
report renders. The `gui` bridge fixes this with a stash/rethrow pair:

```nim
var pending = owlError(RuntimeError, "")
var hasPending = false

proc stash() =
  if not hasPending:
    hasPending = true
    pending = currentError

proc rethrow() =
  if hasPending:
    hasPending = false
    raiseError(pending)

proc runQuietly(fn: Object) =
  try:
    discard invoke(fn, @[])
  except:
    stash()
```

Every per-frame Nim->Owl call is wrapped in `runQuietly`, and the next time
control returns into Owl code -- the builtin that drove the frame -- it calls
`rethrow()` so the original error, with its original place, surfaces through
the evaluator. Copy this pattern whenever your loop calls `invoke` outside a
builtin.

On the Owl side, `try` handles errors without unwinding to Nim:

```owl
report = try (risky):
    (error-report)
```

the block runs when the call raises, and `error-report` yields the rendered
error text.

---

## 10. A complete integration

Everything at once: a host that builds a library (native + embedded Owl),
feeds it config through `serde`, calls an Owl `view` each frame, binds state
back in, and reports failures. The `gui` module from the `owl` CLI is one
ready-made instance of exactly this host -- its source (`owl/libraries/gui.nim
+ gui.owl`) is the largest worked example in the tree; `library.nim` is the
library-composition example; `owl.nim` is the host-shell example.

```nim
import std/[options, syncio]
import owl/[objects, reader, evaluator, modules, serde, errors]
import owl/libraries/[base, math, io, term]
import owl/embedfile

type
  GameState = object
    ticks: int
    label: string

proc sleepBuiltin(env: ref Environment, args: seq[Object], bodyStart: int): Object =
  # (sleep 1.5)  -- hand the duration to a Nim timer; here, just acknowledge.
  if args.len != 1:
    err("sleep needs one number")
  let ms = numberIn(env, args[0], "sleep")
  echo "scheduled sleep of ", ms, " seconds"
  nothing()

proc gameModule*(): Module =
  result = newModule("game")
    .addBuiltin("sleep", sleepBuiltin, false)
    .addExport("game-name", str("demo"))

const scriptSource = embedFile("game.owl")
  # game.owl:
  #   use base
  #   use math
  #   use io
  #   use game
  #   state = {} (ticks = 0) (label = "boot")
  #   fun tick st:
  #     {} (ticks = (+ st.ticks 1)) (label = "running")
  #   sleep 0.5

proc main() =
  let lib = newLibrary("host")
  lib.add baseModule()
  lib.add mathModule()
  lib.add ioModule()
  lib.add gameModule()

  let env = runProgram(lib, readSource(scriptSource, "game.owl"))

  # Nim state in: serde encodes it as a record the script can read.
  var gs = GameState(ticks: 0, label: "from-nim")
  define(env, symbol("nim-state"), encode(gs))

  # Owl state out: read the binding, decode the record it holds.
  let tickFun = lookup(env, symbol("tick"))
  var st = decode(lookup(env, symbol("state")).get(), GameState)
  if tickFun.isSome:
    let next = invoke(tickFun.get(), @[encode(st)])
    decode(next, st)
  echo "ticks now: ", st.ticks

when isMainModule:
  colorErrors = stderrIsTerminal()
  try:
    main()
  except:
    reportError()
    quit 1
```

Notes on what this leaves out, deliberately: the real frame loop would keep
`tickFun` as a stored command and call `invoke` from a loop wrapped in the
stash/rethrow pattern (§ 9); a real config file would load through `owlText`
and `readSource` (§ 8); a GUI host would add `guiModule(embedFile("libraries/
gui.owl"))` -- SDL3 and `ellipse_ui` linking aside, nothing about the border
changes. The pieces are the ones above.
