import plugnim
import platform/[sdl, engine]

proc createApplication*(cfg: AppConfig): App =
  result = initApp(cfg)
