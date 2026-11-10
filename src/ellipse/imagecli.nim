## `ellipse image` -- the image tool of the command line: renders an Aseprite
## file with the engine's own loader (see aseprite.nim) and writes it out as
## PNG, to a file or to stdout, so other programs -- editors, previewers,
## shell pipelines -- can show sprites without touching the window backend:
##
##   ellipse image export sprite.aseprite --format png --output sprite.png
##   ellipse image export sprite.aseprite --format png > sprite.png
##
## The frame is composited by `renderFrameRgba`: visible layers in order,
## honouring cel and layer opacity and the palette, so the PNG matches what
## the engine would paint. `--scale` upscales the picture with nearest
## neighbours, which is what pixel art wants and what a small sprite preview
## in a terminal or an editor window usually needs.

{.push raises: [CatchableError].}

import std/[os, strformat, strutils]

import aseprite
import drawing/snapshot

const
  imageCommand* = "image" ## The subcommand that routes a run to this tool.
  usageText = """usage: ellipse image export FILE --format png [OPTIONS]

Export a frame of an Aseprite file (.ase/.aseprite) as PNG, written to
stdout or to the path --output names.

options:
  --format png    the output format; only png is supported
  --output FILE   where to write, or - for stdout (default: stdout)
  --frame N       the frame to render, counting from 0 (default: 0)
  --scale N       nearest-neighbour upscaling, 1 keeps the original size
  --help          show this text
"""

proc imageCommandRequested*(): bool =
  ## `ellipse image ...`: this run is the image tool, not an application.
  ## Checked before anything boots, so no window, GPU or input is opened.
  paramCount() >= 1 and paramStr(1) == imageCommand

type
  ImageOptions = object
    input: string
    output = "-"
    format = "png"
    frame = 0
    scale = 1

  ParseStatus = enum
    psRun ## a command to run
    psHelp ## --help: print usage, succeed
    psError ## a bad command line: report and fail

proc takeValue(args: seq[string]; i: var int; flag: string; value: var string): string =
  ## The value of `--flag VALUE`, advancing `i` past it.
  ## Returns an error message when there is none.
  if i >= args.len:
    return &"{flag} expects a value"
  value = args[i]
  inc i
  ""

proc parseArgs(args: seq[string]; opts: var ImageOptions): ParseStatus =
  ## Parse `image`'s own arguments, after the `image` word. The first word
  ## must be the subcommand; one file is expected.
  if args.len == 0:
    stderr.writeLine usageText
    return psError
  if args[0] in ["--help", "-h", "help"]:
    return psHelp
  if args[0] != "export":
    stderr.writeLine &"ellipse image: unknown subcommand '{args[0]}'"
    return psError

  var i = 1
  while i < args.len:
    let flag = args[i]
    inc i
    case flag
    of "--format":
      var value: string
      let err = takeValue(args, i, flag, value)
      if err.len > 0:
        stderr.writeLine &"ellipse image: {err}"
        return psError
      opts.format = value
    of "--output", "-o":
      var value: string
      let err = takeValue(args, i, flag, value)
      if err.len > 0:
        stderr.writeLine &"ellipse image: {err}"
        return psError
      opts.output = value
    of "--frame":
      var value: string
      let err = takeValue(args, i, flag, value)
      if err.len > 0 or value.parseInt < 0:
        stderr.writeLine &"ellipse image: {flag} expects a frame number"
        return psError
      opts.frame = value.parseInt
    of "--scale":
      var value: string
      let err = takeValue(args, i, flag, value)
      if err.len > 0 or value.parseInt < 1:
        stderr.writeLine &"ellipse image: {flag} expects a scale of 1 or more"
        return psError
      opts.scale = value.parseInt
    of "--help", "-h":
      return psHelp
    elif flag.startsWith("--"):
      let eq = flag.find('=')
      if eq < 0 or flag[0 ..< eq] notin ["--format", "--output", "--frame", "--scale"]:
        stderr.writeLine &"ellipse image: unknown option '{flag}'"
        return psError
      # --format=..., --output=..., --frame=..., --scale=...
      let name = flag[0 ..< eq]
      let value = flag[eq + 1 .. ^1]
      case name
      of "--format": opts.format = value
      of "--output": opts.output = value
      of "--frame", "--scale":
        var number = 0
        try:
          number = value.parseInt
        except ValueError:
          stderr.writeLine &"ellipse image: {name} expects a number, got '{value}'"
          return psError
        if name == "--frame" and number < 0 or name == "--scale" and number < 1:
          stderr.writeLine &"ellipse image: {name} out of range: {value}"
          return psError
        if name == "--frame": opts.frame = number else: opts.scale = number
    elif opts.input.len == 0:
      opts.input = flag
    else:
      stderr.writeLine &"ellipse image: unexpected argument '{flag}'"
      return psError

  if opts.input.len == 0:
    stderr.writeLine "ellipse image: no input file"
    stderr.writeLine usageText
    return psError
  if opts.format.toLowerAscii != "png":
    stderr.writeLine &"ellipse image: unsupported format '{opts.format}'; only png is exported"
    return psError
  psRun

proc scaledRgba(pixels: seq[uint8]; width, height, scale: int): seq[uint8] =
  ## Nearest-neighbour upscale of an RGBA8 buffer, pixel art's own scaling.
  if scale == 1:
    return pixels
  let scaledWidth = width * scale
  result = newSeq[uint8](scaledWidth * height * scale * 4)
  for y in 0 ..< height * scale:
    for x in 0 ..< scaledWidth:
      let src = ((y div scale) * width + (x div scale)) * 4
      let dst = (y * scaledWidth + x) * 4
      for channel in 0 .. 3:
        result[dst + channel] = pixels[src + channel]

proc runExport(opts: ImageOptions): int =
  let sprite = loadAseprite(opts.input)
  let raw = sprite.renderFrameRgba(opts.frame)
  let png = encodePng(
    int(sprite.width) * opts.scale, int(sprite.height) * opts.scale,
    scaledRgba(raw, int(sprite.width), int(sprite.height), opts.scale))
  if png.len == 0:
    stderr.writeLine &"ellipse image: the frame came out empty ({sprite.width}x{sprite.height})"
    return 1
  if opts.output == "-":
    discard stdout.writeBytes(png, 0, png.len)
    stdout.flushFile()
  else:
    writeFile(opts.output, png)
  0

proc runImageCli*(): int =
  ## Run the `image` subcommand over the process's own arguments and return
  ## the exit status: parse, render the frame, encode, write. Nothing here
  ## touches SDL: `loadAseprite` and the PNG encoder are pure Nim.
  let args = commandLineParams()[1 .. ^1] # past the program; [0] is `image`
  var opts = ImageOptions()
  case parseArgs(args, opts)
  of psHelp:
    stdout.writeLine usageText
    0
  of psError:
    1
  of psRun:
    try:
      runExport(opts)
    except AsepriteError as e:
      stderr.writeLine &"ellipse image: {e.msg}"
      1
    except ValueError as e:
      stderr.writeLine &"ellipse image: bad option: {e.msg}"
      1
    except IOError as e:
      stderr.writeLine &"ellipse image: {e.msg}"
      1
