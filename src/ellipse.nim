import plugnim
export plugnim
import ellipse/scenes

import ellipse/entities/entities

include ellipse/application

export scenes, entities

when isMainModule:
  var cfg = AppConfig(appname: "Ellipse", appversion: "v0.1.0")
  cfg.start()
