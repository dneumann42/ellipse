## Hot-loaded widgets: swap a widget's code while the app runs.
##
## The power of the nimony toolchain is that a single module is a unit of
## compilation (NIF is its IR, and the build cache is per-module). A widget
## marked hot-loadable leans on that: the running app watches the widget's
## source, asks nimony to compile *just that module* into a shared library
## (everything else is reused from the project's nimcache), and loads the
## result over the live one.
##
## A build with `-d:ellipseHotApp` -- what the generated project's `make
## hot` (or a `run` aimed at the hot binary) produces -- hot-loads on its
## own: the app shell calls `startHotLoading`, which finds the marked
## modules, builds and loads each once, and watches their directories for
## the rest of the session. `NIMONY` names the compiler to rebuild with;
## without it the loader finds nimony in the checkout the project's
## `nimony.paths` points into. `ELLIPSE_HOT=0` opts out. Widgets
## written `widget hot Name(...)` (`ellipse new widget --hot`, or by hand)
## then take three shapes, chosen by the `mwidget` plugin:
##
##   the app    each call site packs its arguments into the widget's
##              `NameParams` and goes through `hotWidget`
##              (`ellipse_ui/widgets`), which invokes the loaded library's
##              entry through a plain C trampoline -- or paints a
##              placeholder until one is loaded
##   the library `nimony c --app:lib -d:ellipseHotLib <module>.nim` builds
##              `lib<module>.so`: the widget's draw proc plus its exported
##              entries. The entry names are what the module's NIF records
##              as `(exportc "...")` -- `ellipse/hotload` scans exactly
##              those records to know which function pointers to dlsym
##   plain      the body is compiled into the app whole, exactly like a
##              widget written without the modifier
##
## The library binds to the running app, not to a copy of the kit: the app
## links with `-Wl,--export-dynamic` (below), so the library's references to
## clay's element store, the theme, the input state and the allocator all
## resolve to the app's definitions -- new widget code paints into the live
## frame's element tree.
##
## One file watcher for the whole project: a single inotify descriptor, fed
## by `fdwatch`, whose callback rebuilds the changed module, dlopens the new
## `.so`, re-resolves its entries and asks for a frame. A failed build keeps
## the previous library serving. Windows has no inotify: the shell logs that
## hot-loading is unavailable, and `hotCall` reports "not loaded", which the
## generated call sites answer with a placeholder panel.

import std/[syncio, os, dirs, strutils, envvars, osproc, sha1]
import ./platform/[fdwatch, pacing]

{.passL: "-Wl,--export-dynamic".}
{.emit: "int hot_invoke(void* fn, void* args){ return ((int(*)(void*))fn)(args); }".}

const hotSignal* = "widget hot"
  ## what marks a source as holding hot-loadable widgets: a `widget hot`
  ## definition (the older `# ellipse:hot` header works too)

const hotState = "build/hot/state.tsv"
  ## What each module was last built from: `source \t srcHash \t libHash \t
  ## soPath`, tab-separated. Content hashes, not mtimes -- a file rewritten
  ## with an old timestamp (git checkout, some editors' backups) is still
  ## seen as changed, and one saved within the same second is still seen
  ## as changed.

type
  HotEntry = object
    name: string    ## the exportc symbol, e.g. "ellipseHot_status_pill"
    fn: pointer     ## proc(args: pointer): cint {.cdecl.} in the library

  HotModule = ref object
    source: string  ## project-relative .nim path
    soPath: string  ## the built library, empty until the first success
    srchash: string ## hash of the source the library was built from
    libhash: string ## hash of that library's bytes
    entries: seq[HotEntry]
    handles: seq[pointer]   # dlopen handles, kept: frames still rendering
                            # from the previous library must not lose its
                            # code and string literals under them

  Watch = object
    fd: int32
    dirs: seq[string]   # directories watched, parallel to `wds`
    wds: seq[int32]

var
  modules: seq[HotModule] = @[]
  enabled = false
  loadSeq = 0
  watch: Watch
  watchOk = false

proc hotInvokeFn(fn: pointer; args: pointer): cint {.importc: "hot_invoke".}

when not defined(windows):
  type
    InotifyEvent {.importc: "struct inotify_event", header: "<sys/inotify.h>",
                   pure, final.} = object
      wd: int32
      mask: uint32
      cookie: uint32
      len: uint32

  const
    inCloseWrite = 0x00000008'u32
    inMovedTo = 0x00000080'u32
    inCreate = 0x00000100'u32

  proc inotifyInit(flags: cint): int32 {.importc: "inotify_init1", header: "<sys/inotify.h>".}
  proc inotifyAdd(fd: int32; path: cstring; mask: uint32): int32 {.
    importc: "inotify_add_watch", header: "<sys/inotify.h>".}
  proc readFd(fd: int32; buf: ptr char; count: int32): int32 {.
    importc: "read", header: "<unistd.h>".}
  proc rawWrite(fd: int32; buf: cstring; count: int32): int32 {.
    importc: "write", header: "<unistd.h>".}
  proc dlopenLib(path: cstring; mode: cint): pointer {.importc: "dlopen".}
  proc dlsymSym(handle: pointer; name: cstring): pointer {.importc: "dlsym".}

proc hotMsg(a: string = ""; b: string = ""; c: string = "") =
  ## Report straight to stderr: `dlopen` runs the library's module inits,
  ## which re-create the (interposed, shared) syncio stream buffers and drop
  ## whatever was pending -- the logger's stdout would swallow these very
  ## messages, and fd 2 is unbuffered anyway.
  var s = "hot: "
  s.add a
  if b.len > 0: s.add b
  if c.len > 0: s.add c
  s.add '\l'
  when defined(windows):
    echo s
  else:
    discard rawWrite(2'i32, s.toCString, int32(s.len))

proc hotEnabled*: bool = enabled

proc nimonyExe(): string =
  ## The compiler to rebuild with: the Makefile hands its `NIMONY` down
  ## through the environment, else whatever `nimony` is on PATH; and else
  ## the ellipse checkout the project's `nimony.paths` points into, since
  ## the kit ships nimony under `build/nimony/bin/`.
  result = getEnv("NIMONY", "")
  if result.len == 0:
    result = findExe("nimony")
  if result.len == 0 and fileExists("nimony.paths"):
    let marker = "/build/nimony/src/nimony/lib"
    let paths = try: readFile("nimony.paths") except: ""
    for line in paths.splitLines():
      let t = line.strip()
      if t.endsWith(marker):
        let cand = t.substr(0, t.len - marker.len) / "build/nimony/bin/nimony"
        if fileExists(cand):
          return cand
  if result.len == 0:
    result = "nimony"

proc hotWidgetsIn(text: string): seq[string] =
  ## Widget names defined `widget hot [focusable] Name` in a source.
  result = @[]
  var pos = 0
  while true:
    let at = text.find("widget hot", pos)
    if at < 0: break
    pos = at + len("widget hot")
    var i = pos
    while i < text.len and text[i] in {' ', '\t'}: inc i
    if text.substr(i, i + len("focusable") - 1) == "focusable":
      i += len("focusable")
      while i < text.len and text[i] in {' ', '\t'}: inc i
    var name = ""
    while i < text.len and text[i] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      name.add text[i]
      inc i
    if name.len > 0:
      result.add "ellipseHot_" & name

proc nifExports(soPath: string): seq[string] =
  ## What the compiled module actually offers, read from its NIF: nimony
  ## records every `exportc` proc of the main module in the module's
  ## `.x.nif` as `(exportc "name")` -- the authoritative list of entry
  ## points the library can be asked for.
  result = @[]
  let dir = parentDir(soPath)
  let nif = dir / splitFile(dir).name & ".x.nif"
  if not fileExists(nif):
    return
  var text = ""
  try: text = readFile(nif) except: return
  var pos = 0
  while true:
    let at = text.find("exportc", pos)
    if at < 0: break
    pos = at + len("exportc")
    let q1 = text.find('"', pos)
    if q1 < 0: break
    let q2 = text.find('"', q1 + 1)
    if q2 < 0: break
    let name = substr(text, q1 + 1, q2 - 1)
    if name.startsWith("ellipseHot_") and name notin result:
      result.add name
    pos = q2

proc exportsOf(module: HotModule): seq[string] =
  ## The entry symbols a hot module offers: the compiled library's NIF
  ## export records first; the source (`widget hot Name`, or a hand-written
  ## `exportc: "ellipseHot_..."`) when the library has not been read.
  result = nifExports(module.soPath)
  if result.len > 0:
    return
  var text = ""
  try: text = readFile(module.source) except: discard
  for name in hotWidgetsIn(text):
    if name notin result: result.add name
  var pos = 0
  while true:
    let at = text.find("exportc: \"", pos)
    if at < 0: break
    let start = at + len("exportc: \"")
    let till = text.find('"', start)
    if till < 0: break
    let name = substr(text, start, till - 1)
    if name.startsWith("ellipseHot_") and name notin result:
      result.add name
    pos = till

proc walkNim(dir: string; acc: var seq[string]) =
  ## Every .nim under `dir`, recursing into subdirectories. Built on the
  ## raw DirWalker -- `walkDir`'s tuple iterator trips an assertion in
  ## this nimony.
  var w = tryOpenDir(path(dir))
  var e = default(DirEntry)
  while tryNextDir(w, e):
    let full = joinPath(dir, $e.path)
    case e.kind
    of pcFile:
      if full.endsWith(".nim"):
        acc.add full
    of pcDir:
      walkNim(full, acc)
    else:
      discard
  discard tryCloseDir(w)

proc sha1hex(text: string): string =
  ## SHA-1 over the text, lowercase hex.
  var ctx = newSha1State()
  ctx.update(text)
  let d = ctx.finalize()
  const H = "0123456789abcdef"
  result = ""
  for i in 0 ..< d.len:
    result.add H[int(d[i]) shr 4]
    result.add H[int(d[i]) and 15]

proc hashFile(p: string): string =
  ## `sha1hex` over a file's bytes; "" when it can't be read.
  try: sha1hex(readFile(p)) except: ""

proc findModules(): seq[string] =
  ## Every source under src/ marked `# ellipse:hot`.
  result = @[]
  var files: seq[string] = @[]
  if dirExists("src"):
    walkNim("src", files)
  for f in files:
    try:
      let text = readFile(f)
      if hotSignal in text or "# ellipse:hot" in text:
        result.add f
    except:
      discard

proc firstDirWith(dir: string; want: string): string =
  ## The first subdirectory of `dir` holding the file `want`.
  result = ""
  var w = tryOpenDir(path(dir))
  var e = default(DirEntry)
  while result.len == 0 and tryNextDir(w, e):
    if e.kind == pcDir and fileExists(joinPath(joinPath(dir, $e.path), want)):
      result = joinPath(joinPath(dir, $e.path), want)
  discard tryCloseDir(w)

proc findSo(module: HotModule): string =
  ## The library the last build produced. `nimony --app:lib` writes it into
  ## a nimcache directory keyed by module hash; look it up by file name.
  result = ""
  let want = "lib" & splitFile(module.source).name & ".so"
  if dirExists("nimcache"):
    result = firstDirWith("nimcache", want)

proc runNimony(module: HotModule): bool =
  ## One compiler run building the module's library; false (with a line on
  ## stderr) when it fails.
  hotMsg("building ", module.source)
  let cmd = quoteShell(nimonyExe()) &
    " c --app:lib -d:ellipseHotLib " & quoteShell(module.source) &
    " > " & quoteShell("build/hot/last-build.log") & " 2>&1"
  let (outp, code) = try: execCmdEx(cmd) except: ("", 1)
  if code != 0:
    var why = outp.strip()
    let lines = why.splitLines()
    if lines.len > 0: why = lines[^1]
    hotMsg("build failed (see build/hot/last-build.log): ", why)
    return false
  true

proc saveState() =
  ## Persist what every module was last built from, so a boot with no
  ## changes reuses the libraries without consulting mtimes or the compiler.
  var text = ""
  for m in modules:
    if m.srchash.len > 0:
      text.add m.source & "\t" & m.srchash & "\t" & m.libhash & "\t" & m.soPath & "\n"
  try: writeFile(hotState, text) except: discard

proc loadStateInto(module: HotModule) =
  ## Recover a past session's build record for this source, if any.
  var text = ""
  try: text = readFile(hotState) except: return
  for line in text.splitLines():
    let cols = line.split('\t')
    if cols.len == 4 and cols[0] == module.source:
      module.srchash = cols[1]
      module.libhash = cols[2]
      module.soPath = cols[3]
      return

proc buildModule(module: HotModule): bool =
  ## Recompile one hot module into a shared library. nimony's per-module
  ## cache means only the widget's own translation unit and the link step
  ## redo work -- the incremental path the toolchain is built for.
  ##
  ## Whether a rebuild is needed is content, not mtime: the library is
  ## reused only when its bytes hash exactly what the state file recorded
  ## building from this very source's bytes. A change always rebuilds,
  ## never a clock.
  try: createDir(path("build/hot"))
  except: discard
  let src = hashFile(module.source)
  if src.len == 0:
    hotMsg("cannot read ", module.source)
    return false
  var existing = module.soPath
  if existing.len == 0 or not fileExists(existing):
    existing = findSo(module)
  let curLib = if existing.len > 0: hashFile(existing) else: ""
  if existing.len > 0 and src == module.srchash and curLib == module.libhash and
      curLib.len > 0:
    module.soPath = existing
    return true                         # the library is exactly what this
                                        # source produced last time
  if not runNimony(module):
    return false
  var so = if existing.len > 0 and fileExists(existing): existing else: findSo(module)
  if so.len == 0 or not fileExists(so):
    hotMsg("no library found for ", module.source)
    return false
  var lib = hashFile(so)
  if curLib.len > 0 and lib == curLib:
    ## The compiler "succeeded" but the library bytes are unchanged from
    ## the ones that served a different source: its cache is lying (this
    ## is the stale lib that used to need a manual `rm *.so`). Purge this
    ## module's cache directory and rebuild once. A second identical
    ## result is accepted: then the change truly does not affect codegen.
    hotMsg("build changed nothing; clearing ", parentDir(so))
    let cacheDir = parentDir(so)
    ## nimony keys its caches by module hash: the module's directory plus
    ## root-level `<hash>.p.nif`/`<hash>.s.nif`/... files. The parse cache
    ## is mtime-checked, so a source with an old timestamp (git checkout,
    ## restored backups) keeps feeding stale parses through that file
    ## alone -- purge the whole prefix, not just the directory.
    discard try: execCmdEx("rm -rf " & quoteShell(cacheDir) &
                           " " & cacheDir & "*") except: ("", 1)
    if not runNimony(module):
      return false
    so = findSo(module)
    if so.len == 0 or not fileExists(so):
      hotMsg("no library found for ", module.source)
      return false
    lib = hashFile(so)
  module.soPath = so
  module.srchash = src
  module.libhash = lib
  saveState()
  true

when not defined(windows):
  proc loadModule(module: HotModule): bool =
    ## Replace the module's entries with ones resolved from the built
    ## library. `dlopen` caches by path and nimony overwrites the same
    ## nimcache file, so the new build is first copied to a fresh path:
    ## that mapping is one the loader has never seen and its entries are
    ## guaranteed to be the new code. Old handles stay alive (never
    ## dlclose'd) -- frames still rendering from the previous library must
    ## not lose its code and string literals under them.
    let dest = "build/hot/" & splitFile(module.source).name & "." & $loadSeq & ".so"
    inc loadSeq
    let cp = try: execCmdEx("cp " & quoteShell(module.soPath) & " " & quoteShell(dest))
      except: ("", 1)
    if cp[1] != 0 or not fileExists(dest):
      hotMsg("could not stage ", dest)
      return false
    var soName = dest
    let handle = dlopenLib(soName.toCString, 2)   # RTLD_NOW
    if handle == nil:
      hotMsg("could not load ", dest)
      return false
    module.handles.add handle
    var loaded: seq[HotEntry] = @[]
    for name in exportsOf(module):
      var nm = name
      let fn = dlsymSym(handle, nm.toCString)
      if fn == nil:
        hotMsg(name, " missing from ", module.soPath)
      else:
        loaded.add HotEntry(name: name, fn: fn)
    if loaded.len == 0:
      hotMsg("no entries in ", module.source)
      return false
    module.entries = loaded
    hotMsg("loaded ", $loaded.len, " entries from " & dest)
    true
else:
  proc loadModule(module: HotModule): bool = false

proc dirOf(source: string): string = parentDir(source)

proc refresh(module: HotModule) =
  if buildModule(module):
    if loadModule(module):
      pacing.requestFrame()

proc moduleDir(wd: int32): string =
  for i in 0 ..< watch.wds.len:
    if watch.wds[i] == wd:
      return watch.dirs[i]
  ""

proc onWatchReady() =
  ## inotify fired: rebuild the module whose *file* changed -- a save to
  ## one widget recompiles one module, nothing else. The callback runs
  ## between frames (see `platform/fdwatch`), so rebuilding here is as
  ## safe as in a `before` hook.
  when not defined(windows):
    var buf = default(array[8192, char])
    let n = readFd(watch.fd, addr buf[0], int32(buf.len))
    if n <= 0:
      return
    const hdr = int(sizeof(InotifyEvent))
    var pos = 0
    var touched: seq[int] = @[]
    while pos + hdr <= int(n):
      let e = cast[ptr InotifyEvent](addr buf[pos])[]
      var name = ""
      let nameStart = pos + hdr
      var k = 0
      while k < int(e.len) and buf[nameStart + k] != '\0':
        name.add buf[nameStart + k]
        inc k
      pos += int(e.len) + hdr
      if (e.mask and (inCloseWrite or inMovedTo)) != 0 and name.len > 0:
        for i, m in modules:
          if splitFile(m.source).name & ".nim" == name and i notin touched:
            touched.add i
    for i in touched:
      refresh(modules[i])

proc addWatchDir(dir: string) =
  when not defined(windows):
    if watchOk:
      var d = dir
      let wd = inotifyAdd(watch.fd, d.toCString,
                          inCreate or inCloseWrite or inMovedTo)
      if wd >= 0:
        watch.dirs.add dir
        watch.wds.add wd
      else:
        hotMsg("cannot watch ", dir)

proc startHotLoading*() =
  ## Called by the app shell. A build with `-d:ellipseHotApp` is a hot
  ## app: the widget modules' call sites are dispatchers, and finding
  ## their libraries is the only way they can paint -- so hot-loading
  ## starts automatically. `ELLIPSE_HOT=0` turns it off (e.g. to run the
  ## hot binary against its own stale copy); `NIMONY` tells the loader
  ## which compiler to rebuild with, exactly as the Makefile's `hot`
  ## target passes it.
  when not defined(ellipseHotApp):
    return                          # plain builds never hot-load
  else:
    if getEnv("ELLIPSE_HOT", "") == "0":
      hotMsg("disabled (ELLIPSE_HOT=0)")
      return
    when defined(windows):
      hotMsg("hot-loading needs inotify; not supported on Windows")
    else:
      enabled = true
      let found = findModules()
      for source in found:
        let m = HotModule(source: source)
        loadStateInto(m)
        modules.add m
      if modules.len == 0:
        hotMsg("no `widget hot` modules under src/ ",
               "(add one with `ellipse new widget --hot`)")
      else:
        watch.fd = inotifyInit(cint(0x800 or 0x80000))  # O_NONBLOCK | O_CLOEXEC
        if watch.fd >= 0 and watchFd(watch.fd, onWatchReady):
          watchOk = true
        else:
          hotMsg("could not watch for file changes")
        let (o, c) = try: execCmdEx("rm -f build/hot/*.so") except: ("", 1)
        discard c                            # last session's staged copies
        var seen: seq[string] = @[]
        for m in modules:
          let d = dirOf(m.source)
          if d notin seen:
            seen.add d
            addWatchDir(d)
        for m in modules:
          refresh(m)

proc hotCall*(exportName: string; args: pointer): cint =
  ## What a hot call site in the app runs: invoke `exportName`'s entry in
  ## the loaded library. Returns its result (the activation flag for
  ## focusables, ignored otherwise), or -1 when nothing is loaded yet --
  ## the generated call sites answer that with a placeholder panel.
  if not enabled:
    return -1
  for m in modules:
    for e in m.entries:
      if e.name == exportName:
        return hotInvokeFn(e.fn, args)
  -1
