import plugnim
export plugnim
import ellipse/scenes

include ellipse/application

export scenes

when isMainModule:
  var cfg = AppConfig(appname: "Ellipse", appversion: "v0.1.0")
  cfg.start()
