import plugnim
export plugnim
import ellipse/scenes

import ellipse/entities/entities

include ellipse/application

import ellipse/imagecli

export scenes, entities

when isMainModule:
  if imageCommandRequested():
    # `ellipse image ...`: the image tool, no application boots for it.
    quit runImageCli()
  var cfg = AppConfig(appname: "Ellipse", appversion: "v0.1.0")
  cfg.start()
