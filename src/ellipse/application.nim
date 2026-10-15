import plugnim, scenes
import platform/[sdl, engine]

export plugnim
export AppConfig

proc createApplication*(cfg: AppConfig): App =
  result = initApp(cfg)

template update*(
  dt {.inject.}: float, 
  sceneStack {.inject.}: var SceneStack, 
  paused {.inject.}: bool
) =
  generatePluginFunctionCalls(earlyUpdate)
  if sceneStack.handleLoads():
    # gui.clearNestUI()
    discard
  generatePluginFunctionCalls(constantUpdate)
  if not paused:
    generatePluginFunctionCalls(update)
    generatePluginFunctionCalls(lateUpdate)

template draw*(app: App) =
  app.renderClear(color(0.0, 0.0, 0.0))

template start*(cfg: AppConfig) =
  generatePluginContext()
  loadDynamicPlugins()
  configureVideoDriver()
  sdl.initialize()

  var 
    app = cfg.createApplication()
    engine = initEngine()
    sceneStack {.inject.} = initSceneStack()
    running {.inject.} = true
    paused {.inject.} = false

  sceneStack.loadSceneStackState()
  generatePluginFunctionCalls(load)
  
  while running:
    sceneStack.handlePushed()
    processEvents(running)
    let frame = engine.beginFrame()
    update(frame.dt, sceneStack, paused)
    sceneStack.handleUnloads()
    app.draw()
    app.render()
    engine.endFrame(running)
