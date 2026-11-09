# Hot reloading × the display transport

How a saved file reaches the screen without the window ever blinking.

There are no third-party moving parts here: no Vite, no HMR, no WebSocket.
Two hand-rolled mechanisms do the work, and the second one is what makes the
first invisible:

- **Hot reloading** — `src/ellipse/hotload.nim`, built on an inotify watcher
  (`src/ellipse/platform/fdwatch.nim`). Two flavors: swapping one widget's
  compiled `.so` into the running process, and rebuilding + re-`execv`ing the
  whole application.
- **The display transport** — `src/ellipse/platform/display.nim`. A Unix
  socket between two processes: the *application* (loop, draw commands, all
  state) and a *display server* (the actual SDL window). Frames go up, input
  comes down.

The coupling that matters: **the window lives in the server, not in the app,
so the app can be killed, rebuilt and relaunched under a live window.**
(`hotload.nim:140-143`)

---

## 1. The display transport

POSIX only; on Windows attached mode falls back to local windows
(`display.nim:43-44`).

### Topology

```
┌────────────────────────┐        Unix socket         ┌──────────────────────────┐
│  application process   │  frames up, ticks down,    │   display-server process  │
│  (game loop, widgets,  │  input down, quit down     │   (owns the SDL window)   │
│   all app state)       │ <══════════════════════>   │                           │
└────────────────────────┘                             └──────────────────────────┘
   paint offscreen, mirror                              present on screen,
   snapshots, wait for ticks                            forward input events
```

- Socket path: `ELLIPSE_DISPLAY_SOCKET`, else
  `$XDG_RUNTIME_DIR/ellipse-display.sock`, else `/tmp/ellipse-display-<uid>.sock`
  (`displaySocketPath()`, `display.nim:97-109`).
- Server: `serveDisplay()` (`display.nim:933`) opens the window and listens
  (chmod 0600). **One slot**: one window, one attached client. A second
  attach *takes over* from the incumbent (`attachClient`, `:797-820`) — this
  is precisely what a relaunched app needs, see §4.
- The server is usually self-spawned: `ensureDisplayServer` double-forks the
  *same executable* with `--display-serve` when an attached run finds nobody
  listening (`display.nim:376-435`, `platform.nim:877-882`). `setsid` detaches
  it from the terminal, so one terminal suffices for the whole dev loop. A
  `flock` on `<socket>.lock` keeps two servers from racing (`:937-943`), and a
  self-spawned server polls its owner PID and exits when the app finally dies
  (`:974-981`).
- `Makefile:82-93` wraps both sides as `make run_display` / `run_attached`.

### Wire protocol

Each message is a header line + body (`sendMsg`/`takeMsgAt`, `display.nim:221-279`):

- **Control messages**: `<len>\n` + a JSON body — a flat `WireMsg`
  `{k,t,n,a,b,d}`.
- **Frame messages (raw-v1 fast path)**: `F <w> <h> <pixelFormat> <byteCount>\n`
  immediately followed by binary ARGB8888 pixels (`sendSurfaceSnapshot`,
  `:674-709`). A client talking to an old server that doesn't advertise
  `raw-v1` falls back to base64-in-JSON. The `"display transport: "` line the
  app logs at startup is just which of these two is in use (`frameTransport()`,
  `:213-215`).

Message kinds (`display.nim:66-68`):

```
up (app → server):   msgHello, msgFrame, msgDetach
down (server → app): msgHelloReply, msgTick,
                     evKey, evKeyUp, evMotion, evButton, evWheel,
                     evResize, evQuit
```

### Connection lifecycle

1. **Handshake.** Client sends `msgHello{title}`; server replies
   `msgHelloReply{width, height, refreshNs, data}`. The `data` field carries
   the protocol version token `"raw-v1"` — that's the transport's whole
   versioning story (`:444-459`).
2. **Frames up.** The app paints offscreen and mirrors each finished picture:
   UI-kit apps send surface snapshots from `drawFrame`
   (`platform.nim:1711-1733`); game-kit apps read back their hidden GPU
   swapchain and mirror the pixels (`sdl.nim:174-184`). One frame in flight at
   a time.
3. **Tick pacing.** The server sends one `msgTick` per *presented* frame
   (`pumpClientFrames`, `display.nim:857-892`); the client blocks in
   `beginServedFrame` until its tick arrives (`:576-623`). The socket tick
   exactly replaces a local vsync.
4. **Input down.** The server translates its SDL events to `evKey`/`evMotion`/
   `evButton`/`evWheel`/`evResize` (`forwardEvent`, `:822-855`); the client
   re-materializes them into its *own* SDL event queue (`pushWireEvent`,
   `:526-569`), so widgets and the game loop see ordinary local events.
5. **Close.** The window's close button sends `evQuit` *to the app* — it never
   kills the window (`:926-929`). This is the load-bearing decision for
   hot reload; see §4.
6. **Death.** `msgDetach` on a clean client close; `disp.gone` when the socket
   EOFs. The slot clears and the window shows a "waiting" field
   (`paintWaiting`, `:745-753`) until the next attach.

---

## 2. Hot reloading flavor A: widget `.so` swapping

Scope: changes *inside a marked widget module* while the process keeps
running. Enabled by building with `-d:ellipseHotApp` (`make hot`) and writing
`widget hot Name(...)` (`ellipse new widget --hot`); the marker string is
`"widget hot"` (`hotload.nim:51`, older `# ellipse:hot` also works).

Flow (`startHotLoading`, `hotload.nim:759-804`):

1. **Find** — walk `src/` for files containing the marker (`findModules`, `:539`).
2. **Watch** — one inotify fd (CLOSE_WRITE | MOVED_TO | CREATE) per widget
   directory, fed through `fdwatch`, which wakes SDL's event queue with a user
   event so callbacks run on the main thread between frames
   (`platform/fdwatch.nim`).
3. **Build** — on change, `nim c --app:lib -d:ellipseHotLib --outdir:build/hot`
   for just that module. The app itself links `-Wl,--export-dynamic`
   (`hotload.nim:48`), so the freshly loaded `.so` binds against the *running
   app's* clay, theme and input symbols — new widget code paints into the
   live frame's element tree instead of a private copy.
4. **Version-check** — `build/hot/state.tsv` records
   `source \t srcHash \t libHash \t soPath` using SHA-1 **content** hashes,
   not mtimes: a `git checkout` that rewrites old timestamps still counts as
   a change, and a rebuild that produces identical bytes is detected (a lying
   nimcache gets purged and rebuilt, `:644-659`). This TSV is the manifest.
5. **Load** — copy the `.so` to a fresh path `build/hot/<name>.<seq>.so` so
   dlopen's path cache can't hand back stale code, then `dlopen(RTLD_NOW)`,
   scan `nm -D` for the `ellipseHot_*` exports, `dlsym` the entry points
   (`loadModule`, `:666-701`). Old handles are **never `dlclose`d** — an
   in-flight frame may still be executing them (`:73-75`).
6. **Swap** — `pacing.requestFrame()` (`:707-710`); the next frame renders
   with the new code. Failed build? The previous library keeps serving.

Call sites are generated by the `widget` macro (`ellipse_ui/deps/mwidget.nim`)
into three shapes; at runtime every call goes through `hotWidget`
(`ellipse_ui/widgets/common.nim:1121`) → `hotCall` → a plain C trampoline
`hot_invoke` (`hotload.nim:49`), packing arguments into the widget's
`NameParams` struct. Until a library is loaded, the call site paints a
placeholder panel.

**Interaction with the transport: none needed.** The swapped widget renders
into the app's offscreen surface; that surface travels the normal snapshot
path to the server on the next frame. No reconnect, no handshake, the socket
never notices.

---

## 3. Hot reloading flavor B: whole-app rebuild + `execv`

Scope: everything a `.so` *can't* hold — the app's main, data layouts,
untouched modules, the kit itself. Armed by the UI-kit app shell with
`App(hotApp: true)` (`ellipse_ui/app.nim:112-116`).

Flow (`startProjectWatching`, `hotload.nim:236-419`):

1. **Watch** — recursive inotify over all of `src/` (hidden dirs skipped,
   directories created mid-session picked up on each event), again via
   `fdwatch`.
2. **Debounce** — events only stamp `lastSourceChangeNs`; each frame the loop
   calls `checkProjectSettled()` and builds once the tree has been quiet past
   `quietNs` (default 400 ms, `ELLIPSE_HOT_QUIET` overrides). `IN_MASK_ADD`
   collapses editor save-bursts (`:153-168`, `:351-387`).
3. **Build** — `make build` (or `App.buildCommand`) via `execCmdEx`. Entry
   point comes from `project.owl`'s `main = "..."` or the single
   `src/<name>.nim` (`projectEntryFile`, `:183-210`). Build failure prints the
   log tail and the *old process keeps serving* — you can fix the typo and
   save again.
4. **Persist state** — before restarting, `beforeReload()` hooks run and
   registered widget state is saved through `ellipse_ui/reloadstate.nim`
   (`registerUiState`/`persistUiState`, a JSON envelope) to a temp file whose
   path travels to the child via `ELLIPSE_RELOAD_STATE`; `ELLIPSE_RELOAD_PID`
   is a guard so unrelated children don't consume it.
5. **Become** — the new binary is loaded over the current process with
   **`execv` on the same PID**, replaying the saved argv
   (`app.nim:158-201, 235-251`). The e2e test proves it by watching
   `/proc/<pid>/exe` flip inode while the pid lives
   (`tests/gui/hot_reload_test.sh:47-60`, `make test_hot`).
6. **Restore** — the fresh image calls `restoreReloadState` after `setup`
   and resumes the loop.

---

## 4. Where the two meet: why the screen doesn't blink

This is the heart of the design. With a normal, locally-owned window,
`execv` means the window dies and reappears — focus lost, geometry lost,
visible flash. Whole-app hot reload is *built for the attached case*
(`hotload.nim:377-384` says so): the display transport's window survives the
kill-and-relaunch cycle, which is the entire reason the reload is invisible.

End-to-end sequence of a whole-app reload over the transport:

```
 time →   app (old image)                display server           app (new image)
 ─────────────────────────────────────────────────────────────────────────────────
 edit      inotify stamp ─┐
 save     settle (400ms) ─┤
          rebuild ────────┘  (window untouched; keeps ticking
                               the app so its loop stays alive)
          persist UI state → ELLIPSE_RELOAD_STATE file
          platform.quit() → loop ends
          execv(new binary)
          socket is FD_CLOEXEC ────────▶ recv EOF: disp.gone,
                                        slot clears, waiting field
                                        ──────────────────────▶  new process boots,
                                                                 restoreReloadState
                                                                 connectDisplay → msgHello
                                        attachClient: drop dead
                                        incumbent, hand slot over ◀── msgHelloReply(w,h,
                                        window never blinked         refreshNs,"raw-v1")
                                                                 first snapshot + tick
                                                                 resumes, same window,
                                                                 same geometry
```

The five load-bearing facts:

1. **Window ownership is what's hot-reloaded around.** The window, SDL
   device and input focus live in the server; the reload replaces only the
   client half. (`hotload.nim:140-143`)
2. **The socket is `FD_CLOEXEC`** (`display.nim:320`), so execv closes it
   cleanly with the old image — no inherited-fd confusion, the server just
   sees EOF.
3. **The one-slot "second attach takes over" rule** (`display.nim:39-41,
   805-811`) exists for exactly this: the newcomer evicts the incumbent
   without any renegotiation. Reconnect logic on the client side is *not* an
   auto-retry loop: `disp.gone` ends the attached loop
   (`attachedDied`, `platform.nim:1772`) — the "reconnect" is the whole
   process relaunching and handshaking again.
4. **The server outlives the app** — it was spawned with `setsid` (or by hand
   via `make run_display`), so execv can't take it down. If the app dies for
   good (server it spawned itself was its owner), the server notices
   `kill(owner, 0)` failing and exits too (`display.nim:974-981`).
5. **`evQuit` quits the app, never the window** (`display.nim:25-27,
   926-929`) — which also lets the *reload path* reuse the same trick:
   `checkProjectSettled` ends the app's loop with `platform.quit()`
   (`hotload.nim:385-387`) without disturbing the screen.

### Shared wake plumbing

Both halves of the dev loop need to wake SDL's blocking event wait, and they
share one substrate:

- the **display socket** is registered with `fdwatch`
  (`platform.nim:896`, `watchFd(disp.socketFd(), ...)`), so forwarded input
  or ticks wake the loop;
- the **inotify fds** go through the same layer;
- `waitForWakes` (`platform.nim:1789-1828`) sleeps on the SDL queue ∪ all
  watched fds ∪ the display socket together, and `pumpProjectWakes()`
  (`hotload.nim:335-349`) drains both the display socket and the hot-reload
  callbacks each frame — necessary because the server socket sits outside
  SDL's own wait list.

So a single frame loop does: *wait for wake → pump display events → pump
project/hot wakes → check settle → draw → snapshot up → wait for tick down.*

### Version/identity mechanisms (summary)

| Concern | Mechanism |
|---|---|
| Transport protocol version | handshake `data == "raw-v1"`, else legacy base64/JSON |
| Widget library identity | SHA-1 pair in `build/hot/state.tsv` (source hash + lib hash) |
| Stale-code protection | fresh `<name>.<seq>.so` path per load; never `dlclose` |
| Process identity across reload | same PID (`execv`), `ELLIPSE_RELOAD_PID` guards the state file |

---

## 5. Running it

```sh
make run_display     # terminal 1: the display server (--display-serve)
make run_attached    # terminal 2: the app, attached; edit src/ → reload
make hot             # hot-widget build of the app (also attaches)
make test_hot        # e2e: whole-app reload via /proc/pid/exe
```

`run_attached` alone also works: if nobody is listening,
`ensureDisplayServer` spawns the server from the same binary.

Environment knobs: `ELLIPSE_DISPLAY_SOCKET` (transport),
`ELLIPSE_HOT=0` (opt out of hot loading), `ELLIPSE_HOT_QUIET=<ms>` (settle
debounce), `NIM` (compiler used to rebuild hot modules).

## 6. Limitations

- **POSIX only** — the transport is Unix-domain sockets; Windows falls back
  to local windows, and with it hot-app reload loses its invisible-window
  story. Hot `.so` swapping has no inotify on Windows either: the shell logs
  that hot-loading is unavailable and call sites show placeholders
  (`hotload.nim:41-43`).
- **Detached runs blink** — whole-app reload is "meant for the attached
  case" (`hotload.nim:377-384`); reloading without the display server
  destroys and recreates the window.
- **One attached client** — by design; attaching a second app takes over the
  window from the first.

## See also

- Source header docs are the authoritative spec: `src/ellipse/hotload.nim:1-43`,
  `src/ellipse/platform/display.nim:1-44`.
- `documentation/nim-tutorial.md` §14 — brief intro to hot widgets.
- `Makefile:82-93` — the two-process dev-mode setup.
- Owl has its own live-reload for `.owl` data/config
  (`src/owl/watch.nim`, `documentation/integrating-owl.md`) on the same
  inotify + fdwatch substrate, but it is unrelated to the display transport.
