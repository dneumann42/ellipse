## The look of a late-nineties console: the scene drawn into a small
## picture -- the PlayStation's 240 lines unless asked otherwise -- and
## blown up to the window with every pixel kept square and hard-edged, and
## every texture sampled without a filter, so texels show as the blocks
## they are near and far. Only the scene takes the look: the backdrop, the
## shapes and the overlay picture laid over it stay at the window's own
## resolution.

type
  RetroOptions* = object
    enabled*: bool ## whether the scene is drawn small and blown up
    lines*: int ## rows of the picture the scene is drawn into
    columns*: int ## ... and its columns; 0 follows the window's shape,
    ## so the pixels stay square whatever the window is
    nearestTextures*: bool ## textures sampled without a filter: each
    ## texel a hard-edged block, mip levels picked whole, never blended

const
  PsxLines* = 240 ## the PlayStation's usual picture: 320 by 240
  PsxColumns* = 320

func newRetroOptions*(enabled = false, lines = PsxLines, columns = 0,
                      nearestTextures = true): RetroOptions =
  ## Off unless asked for. `lines` and `columns` are the picture's size;
  ## with `columns` left at 0 a 4:3 window gets the PlayStation's 320 by
  ## 240 exactly, and a wider one as many more columns as keep the pixels
  ## square. Explicit columns stretch to the window as a television
  ## stretched the console's picture -- the frustum still follows the
  ## window, so nothing is squashed, only the pixels widened.
  RetroOptions(
    enabled: enabled,
    lines: max(lines, 1),
    columns: max(columns, 0),
    nearestTextures: nearestTextures,
  )

func pictureSize*(o: RetroOptions,
                  width, height: uint32): tuple[width, height: uint32] =
  ## The size of the picture the scene is drawn into for a window of
  ## `width` by `height`: never larger than the window itself.
  if width == 0 or height == 0:
    return (0'u32, 0'u32)
  let
    rows = min(o.lines.uint32, height)
    cols =
      if o.columns > 0:
        o.columns.uint32
      else:
        uint32(rows.float64 * width.float64 / height.float64 + 0.5)
  (max(min(cols, width), 1'u32), max(rows, 1'u32))

func pixelatedTextures*(o: RetroOptions): bool =
  ## Whether the scene's textures go unfiltered this frame.
  o.enabled and o.nearestTextures
