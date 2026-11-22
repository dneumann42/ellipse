## Hot-loaded widgets: swap a widget's code while the app runs.
##
## A widget marked hot-loadable is compiled -- alone, as the main module --
## into a shared library (everything else is reused from the project's
## nimcache), and the running app watches the widget's source and loads
## the result over the live one.
##
## A build with `-d:ellipseHotApp` -- what the generated project's `make
## hot` (or a `run` aimed at the hot binary) produces -- hot-loads on its
## own: the app shell calls `startHotLoading`, which finds the marked
## modules, builds and loads each once, and watches their directories for
## the rest of the session. `NIM` names the compiler to rebuild with;
## without it the loader finds nim in the checkout the project's
## `nim.paths` points into. `ELLIPSE_HOT=0` opts out. Widgets
## written `widget hot Name(...)` (`ellipse new widget --hot`, or by hand)
## then take three shapes, chosen by the `widget` macro
## (`ellipse_ui/deps/mwidget`):
##
##   the app    each call site packs its arguments into the widget's
##              `NameParams` and goes through `hotWidget`
##              (`ellipse_ui/widgets`), which invokes the loaded library's
##              entry through a plain C trampoline -- or paints a
##              placeholder until one is loaded
##   the library `nim c --app:lib -d:ellipseHotLib <module>.nim` builds
##              `lib<module>.so`: the widget's draw proc plus its exported
##              entries. The entry names are the library's `exportc`
##              symbols -- `ellipse/hotload` scans the built `.so` to know
##              which function pointers to dlsym
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
{.push gcsafe.}


import std/[syncio, os, dirs, strutils, envvars, osproc, sha1]
import ./platform/[fdwatch, pacing, platform]

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
  modules {.threadvar.}: seq[HotModule]
  enabled = false
  loadSeq = 0
  watch {.threadvar.}: Watch
  watchOk = false
modules = @[]

proc hotInvokeFn(fn: pointer; args: pointer): cint {.importc: "hot_invoke".}

when not defined(windows):
  type
    InotifyEvent = object
      ## The C `struct inotify_event` (fixed part): the name bytes follow it
      ## in the buffer. Declared plain (not `importc`) so `sizeof` works.
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

when defined(posix):
  import std/posix

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
    discard rawWrite(2'i32, s.cstring, int32(s.len))

proc hotEnabled*: bool = enabled

# --- whole-app reload: watch, build, become -----------------------------------
## Hot-loading a `widget hot` module swaps code into the running process.
## That covers what a `.so` can hold; it cannot cover the app's own main,
## its data layouts or anything outside a marked module. For those, a host
## loop (`ellipse_ui.run`'s) watches the sources itself: when one changes,
## rebuild the *program* and re-exec over this process (see
## `restartProcess`). The window lives in the display server, so nothing on
## screen blinks -- the new image dials the same socket and takes over.

var
  watchingWholeApp = false
  restartRequested = false
  restartArgs* {.threadvar.}: seq[string]
  buildCmd {.threadvar.}: string
  srcDirs {.threadvar.}: seq[string]  ## directories under watch, re-walked for
                                      ## subdirectories created since we started
  lastSourceChangeNs = 0'i64      ## monotonic ns of the newest change event
  quietNs = (if getEnv("ELLIPSE_HOT_QUIET").len > 0:
               parseInt(getEnv("ELLIPSE_HOT_QUIET")) * 1_000_000'i64
             else: 400_000_000'i64)  ## this long with no news means the editor
                                     ## settled: build now
  projectWatchFd = -1'i32         ## the whole-app watcher's descriptor
  restarting = false              ## a rebuild landed; re-exec at the next
                                  ## safe moment (the host loop reads it)
  restartedAlready = false        ## set when `takeRestart` is honoured, stays
  buildStartedOnce = false          ## a rebuild has begun (a test's seam)
restartArgs = @[]
srcDirs = @[]
buildCmd = ""

when not defined(windows):
  const
    inMaskAdd = 0x00004000'u32    ## merge into a pending event, do not queue
                                  ## another: a burst of saves is still one
                                  ## quiet settle at the end of them all
    wholeWatchMask = inCloseWrite or inMovedTo or inCreate or inMaskAdd

proc stampNowNs(): int64 =
  ## Monotonic nanoseconds, through the pacer's clock: two saves in the same
  ## second are still two moments apart.
  pacing.monoNow()

proc noteSourceChange() =
  lastSourceChangeNs = stampNowNs()

proc dirTail(path: string): string =
  ## The last part of a directory path, for the hidden-name test.
  let at = path.rfind('/')
  if at >= 0: path.substr(at + 1) else: path

proc projectEntryFile(): string =
  ## The program to rebuild. An ellipse project has `project.owl` naming it
  ## (`main = "nest"`); failing that, the single `.nim` directly under
  ## `src/`; failing that, nothing to rebuild and the watcher stays off.
  var main = ""
  if fileExists("project.owl"):
    let text = try: readFile("project.owl") except: ""
    main = "main"
    for line in text.splitLines():
      let t = line.strip()
      if t.startsWith("main"):
        let eq = t.find('=')
        if eq >= 0:
          var name = t.substr(eq + 1).strip()
          if name.len > 1 and (name[0] == '"' or name[0] == '\''):
            name = name.substr(1, name.high - 1)
          if name.len > 0: main = name
  let guess = "src/" & (if main.len > 0: main else: "") & ".nim"
  if main.len > 0 and fileExists(guess):
    return guess
  var found = ""
  if dirExists("src"):
    for kind, full in walkDir("src"):
      if kind == pcFile and full.endsWith(".nim"):
        if found.len > 0:
          return ""               # more than one entry candidate: don't guess
        found = full
  found

proc copyParam(s: string): string =
  ## A fresh heap copy of an argument. Under ARC, `paramStr` can hand back a
  ## view whose payload dies with the temporary; `execv` then dials whatever
  ## bytes survived -- observed as ENOENT against a path that exists.
  result = s & ""

proc saveRestartArgs*() =
  ## Remember how this process was launched, so a restart replays it exactly
  ## (the display-attach flag included) under the new image.
  if restartArgs.len == 0:
    restartArgs.add(copyParam(paramStr(0)))
    for i in 1 .. paramCount():
      restartArgs.add(copyParam(paramStr(i)))

proc addSrcWatch(fd: int32, dir: string) =
  ## Watch `dir`, and every visible directory below it.
  if dir.len == 0 or not dirExists(dir):
    return
  discard inotifyAdd(fd, dir.cstring, wholeWatchMask)
  if dir notin srcDirs:
    srcDirs.add dir
  var fresh: seq[string] = @[]
  for kind, full in walkDir(dir):
    if kind == pcDir and dirTail(full)[0] != '.' and full notin srcDirs:
      fresh.add full
  for f in fresh:
    addSrcWatch(fd, f)

proc onProjectWatchReady()
  ## Forward declaration; the body follows below.

proc startProjectWatching*(command: string = "") =
  ## Arm the whole-app watcher: inotify over `src/` (hidden names skipped),
  ## fed to `fdwatch` like the widget loader's, plus the rebuild recipe.
  ## `command` defaults to `make build`; whatever it is, it runs in the
  ## project root. Call once at startup (the shell does, behind `--hot-app`
  ## or an explicit request); events land between frames, where rebuilding
  ## is safe.
  when defined(windows):
    discard command
    hotMsg("whole-app reload needs inotify; not supported on Windows")
  else:
    if getEnv("ELLIPSE_HOT", "") == "0":
      hotMsg("disabled (ELLIPSE_HOT=0)")
      return
    let entry = projectEntryFile()
    if entry.len == 0:
      hotMsg("no single src/<name>.nim entry to rebuild: not watching ",
             "(add `widget hot` modules instead)")
      return
    buildCmd = if command.len > 0: command else: "make build"
    saveRestartArgs()
    let fd = inotifyInit(cint(0x800 or 0x80000))  # O_NONBLOCK | O_CLOEXEC
    if fd < 0:
      hotMsg("could not open inotify")
      return
    projectWatchFd = fd
    addSrcWatch(fd, "src")
    if not watchFd(fd, proc () = onProjectWatchReady()):
      hotMsg("could not watch for file changes")
      return
    watchingWholeApp = true
    hotMsg("watching src/ (fd " & $fd & "), will run `" & buildCmd & "` on a change")

proc onProjectWatchReady() =
  ## The watcher's callback: mark the moment, and come back soon to see
  ## whether the project has gone quiet. Events are hints; the deadline
  ## decides, so one burst of saves (an editor's temp-file dance across
  ## several files) builds once. A directory created since the last look
  ## gets watched too -- new source folders join without a restart.
  when not defined(windows):
    var buf = default(array[8192, char])
    let n = readFd(projectWatchFd, addr buf[0], int32(buf.len))
    if n <= 0:
      noteSourceChange()
    else:
      const hdr = int(sizeof(InotifyEvent))
      var pos = 0
      var touchedName = false
      while pos + hdr <= int(n):
        let e = cast[ptr InotifyEvent](addr buf[pos])[]
        var name = ""
        let nameStart = pos + hdr
        var k = 0
        while k < int(e.len) and buf[nameStart + k] != '\0':
          name.add buf[nameStart + k]
          inc k
        pos += int(e.len) + hdr
        if name.len > 0 and not name.startsWith(".") and
            (e.mask and (inCloseWrite or inMovedTo or inCreate)) != 0:
          touchedName = true
      if touchedName:
        noteSourceChange()
      var fresh: seq[string] = @[]
      for d in srcDirs:
        for kind, full in walkDir(d):
          if kind == pcDir and dirTail(full)[0] != '.' and full notin srcDirs:
            fresh.add full
      for f in fresh:
        addSrcWatch(projectWatchFd, f)
    # ask for a frame soon: its pump checks whether the project settled;
    # `wake` first so the loop even looks at the deadline instead of sleeping
    # past every timer until some other event turns up
    pacing.wake()
    pacing.requestFrameIn(quietNs)

proc rebuildProject(): bool =
  ## Run the build recipe. Success means the binary on disk is new code;
  ## failure prints the tail of the compiler's noise and returns false, so
  ## this process keeps serving until the next save.
  hotMsg("rebuilding: ", buildCmd)
  buildStartedOnce = true
  let (outp, code) = try: execCmdEx(buildCmd & " 2>&1") except: ("", 1)
  if code != 0:
    hotMsg("build failed, keeping this build alive")
    var why = outp.strip()
    let lines = why.splitLines()
    let first = max(0, lines.len - 5)
    for i in first ..< lines.len:
      hotMsg("  | ", lines[i])
    return false
  true

proc pumpProjectWakes*() =
  ## The attached app's other beat: the display server's socket is outside
  ## SDL's queue, and `SDL_WaitEventTimeout` never sees it -- without this,
  ## an idle attached app stops pumping entirely once its deadlines run out.
  ## Draining the socket (input, quits) and the watched descriptors (the
  ## hot-reload callback) keeps both alive; paired with `pumpEvents`.
  when not defined(ellipseNoSdl):
    if displayAttached():
      pumpEvents()
      return
  if fdsReady():
    ## An unattached host (a scripted test, an offscreen run) that sleeps in
    ## its own loop instead of `start`: no one else takes the fdwake event,
    ## so run what is ready right here — the watcher's callback lands between
    ## frames exactly as in the paced loop.
    runReadyFds()

proc checkProjectSettled*() =
  ## Called by the host loop each frame (the shell does): a change is
  ## pending and the project has been quiet past `quietNs`? Build. Success
  ## asks for the process to become the new binary; failure keeps serving
  ## the old one until the next save.
  if not watchingWholeApp or restarting:
    return
  if lastSourceChangeNs == 0:
    ## Nothing pending — but a previous build may have finished without this
    ## process being replaced (a scripted host runs on, or an attached
    ## client's execv failed while the display server kept its slot). Arm a
    ## periodic deadline so the loop keeps checking for a late save instead
    ## of sleeping forever on stale state.
    pacing.requestFrameIn(quietNs * 4)
    return
  let age = stampNowNs() - lastSourceChangeNs
  if age < quietNs:
    ## Keep asking: re-arm a deadline right after the settle window closes,
    ## so the loop wakes exactly when the project has gone quiet instead of
    ## sleeping on whatever older deadline it happens to hold.
    pacing.requestFrameIn(quietNs - age + 1_000_000'i64)
    return
  lastSourceChangeNs = 0
  if rebuildProject():
    ## The new image is on disk: end this loop so the shell's `run` seam
    ## re-execs into it (`takeRestart` -> `relaunch`). Without quitting, the
    ## paced loop would keep running frames from the old build and only
    ## restart when the window closed. Attached to a display server, the
    ## window never notices: the close-on-exec socket dies with the old
    ## image, the new one dials fresh, and the server hands it the screen.
    ## A detached (in-house) window *does* close between old quit and new
    ## attach -- so an attached request with nobody serving raises a server
    ## first (see `platform/display.ensureDisplayServer`); whole-app reload
    ## is meant for the attached case.
    restartRequested = true
    platform.quit()
    platform.askToQuitExternally()   # a scripted host must still see the ask

proc takeRestart*(): bool =
  ## True once a whole-app rebuild finished: the host loop ends itself and
  ## `run` turns that into a fresh `execv`. Only ever answered between
  ## frames -- that is what makes replacing the image safe.
  result = restartRequested
  if result:
    restartedAlready = true   # tests look at this: the flag stays set past `run`

proc restartSeen*(): bool =
  ## Whether a restart was claimed since this process began (a test's seam:
  ## `run` re-execs over itself, so the flag would otherwise vanish with the
  ## old image before an assertion could read it).
  restartedAlready

proc restartPending*(): bool =
  ## A rebuild has landed and the restart is pending or done: stop poking the
  ## watcher (a test's seam; production saves arrive on their own).
  restartRequested

proc buildStarted*(): bool =
  ## Whether a rebuild has ever begun in this process (a test's seam).
  buildStartedOnce

proc lastSeen*(): int64 =
  ## The monotonic stamp of the change being waited on, 0 when nothing is
  ## pending (a test's seam: did the watcher take my save?).
  lastSourceChangeNs

proc requestRestart*() =
  ## Ask for the process to become the new binary at the next safe moment.
  restartRequested = true

proc nimExe(): string =
  ## The compiler to rebuild with: the Makefile hands its `NIM` down
  ## through the environment, else whatever `nim` is on PATH; and else
  ## the ellipse checkout the project's `nim.paths` points into, since
  ## the kit ships nim under `build/nim/bin/`.
  result = getEnv("NIM", "")
  if result.len == 0:
    result = findExe("nim")
  if result.len == 0 and fileExists("nim.paths"):
    let marker = "/build/nim/lib"
    let paths = try: readFile("nim.paths") except: ""
    for line in paths.splitLines():
      let t = line.strip()
      if t.endsWith(marker):
        let cand = t.substr(0, t.len - marker.len) / "build/nim/bin/nim"
        if fileExists(cand):
          return cand
  if result.len == 0:
    result = "nim"

proc nimFlags(): string =
  ## Search paths for a library build, from the project's `nim.paths`
  ## (one directory per line), if it has one.
  result = ""
  if fileExists("nim.paths"):
    let paths = try: readFile("nim.paths") except: ""
    for line in paths.splitLines():
      let t = line.strip()
      if t.len > 0 and not t.startsWith("#"):
        result.add " --path:" & quoteShell(t)

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

proc soExports(soPath: string): seq[string] =
  ## What the compiled library actually offers: every `exportc` proc of
  ## the module is a dynamic symbol, so the `.so` itself is the
  ## authoritative list of entry points the library can be asked for.
  result = @[]
  if not fileExists(soPath):
    return
  let (outp, code) = try: execCmdEx("nm -D --defined-only " &
                                    quoteShell(soPath))
    except: ("", 1)
  if code != 0:
    return
  for line in outp.splitLines():
    for word in line.splitWhitespace():
      if word.startsWith("ellipseHot_") and word notin result:
        result.add word

proc exportsOf(module: HotModule): seq[string] =
  ## The entry symbols a hot module offers: the compiled library's dynamic
  ## symbols first; the source (`widget hot Name`, or a hand-written
  ## `exportc: "ellipseHot_..."`) when the library has not been read.
  result = soExports(module.soPath)
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
  ## Every .nim under `dir`, recursing into subdirectories.
  for kind, full in walkDir(dir):
    case kind
    of pcFile:
      if full.endsWith(".nim"):
        acc.add full
    of pcDir:
      walkNim(full, acc)
    else:
      discard

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
  for kind, d in walkDir(dir):
    if kind == pcDir and fileExists(joinPath(d, want)):
      result = joinPath(d, want)
      break

proc findSo(module: HotModule): string =
  ## The library the last build produced. `runNim` directs it into
  ## `build/hot`; look it up by file name.
  result = ""
  let want = "lib" & splitFile(module.source).name & ".so"
  let staged = "build/hot" / want
  if fileExists(staged):
    result = staged
  elif dirExists("nimcache"):
    result = firstDirWith("nimcache", want)

proc runNim(module: HotModule): bool =
  ## One compiler run building the module's library; false (with a line on
  ## stderr) when it fails.
  hotMsg("building ", module.source)
  let stem = splitFile(module.source).name
  let cmd = quoteShell(nimExe()) &
    " c --app:lib -d:ellipseHotLib --outdir:build/hot" &
    " --nimcache:" & quoteShell("build/hot/nimcache-" & stem) &
    nimFlags() & " " & quoteShell(module.source) &
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
  ## Recompile one hot module into a shared library. The module compiles
  ## alone (its imports come from the kit), with its own nimcache
  ## (`build/hot/nimcache-<module>`) so only the changed translation units
  ## and the link step redo work.
  ##
  ## Whether a rebuild is needed is content, not mtime: the library is
  ## reused only when its bytes hash exactly what the state file recorded
  ## building from this very source's bytes. A change always rebuilds,
  ## never a clock.
  try: createDir("build/hot")
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
  if not runNim(module):
    return false
  var so = if existing.len > 0 and fileExists(existing): existing else: findSo(module)
  if so.len == 0 or not fileExists(so):
    hotMsg("no library found for ", module.source)
    return false
  var lib = hashFile(so)
  if curLib.len > 0 and lib == curLib:
    ## The compiler "succeeded" but the library bytes are unchanged from
    ## the ones that served a different source: its cache is lying. Purge
    ## this module's nimcache and rebuild once. A second identical result
    ## is accepted: then the change truly does not affect codegen.
    let cacheDir = "build/hot/nimcache-" & splitFile(module.source).name
    hotMsg("build changed nothing; clearing ", cacheDir)
    discard try: execCmdEx("rm -rf " & quoteShell(cacheDir) &
                           " " & quoteShell(so)) except: ("", 1)
    if not runNim(module):
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
    ## library. `dlopen` caches by path and the rebuild overwrites the same
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
    let handle = dlopenLib(soName.cstring, 2)   # RTLD_NOW
    if handle == nil:
      hotMsg("could not load ", dest)
      return false
    module.handles.add handle
    var loaded: seq[HotEntry] = @[]
    for name in exportsOf(module):
      var nm = name
      let fn = dlsymSym(handle, nm.cstring)
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
      let wd = inotifyAdd(watch.fd, d.cstring,
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
  ## hot binary against its own stale copy); `NIM` tells the loader
  ## which compiler to rebuild with, exactly as the Makefile's `hot`
  ## target passes it. An attached or otherwise host-driven app that wants
  ## *whole-project* reload calls `startProjectWatching` instead (see that).
  when not defined(ellipseHotApp):
    return                          # plain builds never hot-load
  else:
    if getEnv("ELLIPSE_HOT", "") == "0":
      hotMsg("disabled (ELLIPSE_HOT=0)")
      return
    if watchingWholeApp:
      return                        # `startProjectWatching` already armed this
                                    # process; the shell must not double-watch
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
