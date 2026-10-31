import std/macros

import plugnim, scenes
import platform/[sdl, engine]

export plugnim
export AppConfig

type
  NoGame* = tuple

  Application*[G] = ref object
    ## The whole running application: the loop's state plus the game's own
    ## state, so plugins can reach every field by name.
    app*: App
    engine*: Engine
    sceneStack*: SceneStack
    running*: bool
    paused*: bool
    dt*: float
    game*: G

proc createApplication*[G](cfg: AppConfig, game: G): Application[G] =
  Application[G](
    app: initApp(cfg),
    engine: initEngine(),
    sceneStack: initSceneStack(),
    running: true,
    paused: false,
    dt: FixedUpdateSeconds,
    game: game,
  )

proc createApplication*(cfg: AppConfig): Application[NoGame] =
  createApplication(cfg, ())

const
  reservedAliases = [
    "state", "load", "unload", "ui", "update", "lateUpdate", "earlyUpdate",
    "constantUpdate", "draw", "loadScene",
  ]

proc fieldName(def: NimNode): string =
  let n = def[0]
  if n.kind == nnkPostfix: n[1].strVal else: n.strVal

proc resolveType(t: NimNode): NimNode =
  case t.kind
  of nnkRefTy, nnkPtrTy, nnkVarTy: resolveType(t[0])
  of nnkObjectTy, nnkTupleTy, nnkRecList: t
  of nnkStmtList: resolveType(t[^1])
  of nnkBracketExpr:
    if t.len == 2 and t[0].kind == nnkSym and t[0].strVal == "typeDesc":
      resolveType(t[1]) # typeof(x) arrives wrapped in typeDesc[...]
    elif t[0].kind == nnkSym and t[0].strVal == "tuple":
      nnkTupleTy.newTree() # tuple[] -- an empty game state
    else:
      resolveType(t.getTypeImpl())
  else:
    let impl =
      if t.kind in {nnkSym, nnkIdent, nnkAccQuoted, nnkTypeOfExpr}: t.getTypeImpl()
      else: t.getType() # a value expression: read its type instead
    resolveType(impl)

proc objectRecList(t: NimNode): NimNode =
  let ty = resolveType(t)
  case ty.kind
  of nnkObjectTy: ty[^1]
  of nnkTupleTy, nnkRecList: ty
  else: error("injectFields: expected an object type, got " & t.repr, t)

macro injectFields*(state: untyped, gameType: typed): untyped =
  ## Define one alias template per field of the application state, and per
  ## top-level field of its game, so plugin parameters bind by name straight
  ## into the state object -- mutable in place, no copies.
  result = newStmtList()
  let st = ident(state.strVal) # fresh ident: resolves where the aliases are called

  var names: seq[string]
  for fname in ["app", "engine", "sceneStack", "running", "paused", "dt", "game"]:
    let
      name = ident(fname)
      body = newDotExpr(st, name)
    names.add fname
    result.add quote do:
      template `name`(): untyped = `body`

  for def in objectRecList(gameType):
    if def.kind != nnkIdentDefs or def.len < 2:
      continue
    let
      fname = fieldName(def)
      name = ident(fname)
      body = newDotExpr(newDotExpr(st, ident"game"), name)
    if fname in names or fname in reservedAliases:
      error("injectFields: game field '" & fname & "' collides with the " &
        "application's own state; rename the field", def)
    names.add fname
    result.add quote do:
      template `name`(): untyped = `body`

template update*[G](state: var Application[G]) =
  generatePluginFunctionCalls(earlyUpdate)
  if state.sceneStack.handleLoads():
    # gui.clearNestUI()
    discard
  generatePluginFunctionCalls(constantUpdate)
  if not state.paused:
    generatePluginFunctionCalls(update)
    generatePluginFunctionCalls(lateUpdate)

template draw*[G](state: var Application[G]) =
  generatePluginFunctionCalls(draw)

template start*[G](cfg: AppConfig, game: G) =
  generatePluginContext()
  loadDynamicPlugins()
  configureVideoDriver()
  sdl.initialize()

  var appCfg = cfg
  if displayServerRequested():
    # `--display-serve`: this run *is* the display server -- no game loop,
    # just the window every attached game mirrors into. Never returns.
    when not defined(windows):
      serveDisplay(cfg.appname, cfg.width.int32, cfg.height.int32)
  if displayAttachedRequested():
    appCfg.displayMode = DisplayAttached

  var state {.inject.} = appCfg.createApplication(game)
  injectFields(state, G)

  state.sceneStack.loadSceneStackState()
  generatePluginFunctionCalls(load)

  while state.running:
    state.sceneStack.handlePushed()
    processEvents(state.running)
    let tick = state.engine.beginFrame()
    state.dt = tick.dt
    update(state)
    state.sceneStack.handleUnloads()
    draw(state)
    # Attached mode: the display server (or a dead connection) asks for the
    # app to stop; local apps never see one. Frames went out through the
    # artists' `present`, which mirrors them when attached (see platform/sdl).
    if servedQuitAsked(app):
      state.running = false
    state.engine.endFrame(state.running)

template start*(cfg: AppConfig) =
  start(cfg, ())
