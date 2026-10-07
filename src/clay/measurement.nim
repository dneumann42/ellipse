## Text measurement cache and word-boundary wrapping.
##
## Port of Clay's `Clay__MeasureTextCached` + the wrapping pass inside
## `Clay__CalculateFinalLayout`. Structure is preserved (word lists, newline
## markers, trailing-space handling, the single-line fast path) but the
## arena-backed chained hash map with generation freelists becomes a `Table`
## keyed by the full measurement identity, with periodic eviction.
## This fragment is included by clay.nim; it must not import anything.

func hash*(k: TextKey): Hash =
  result = hash(k.text)
  result = result !& Hash(k.fontId)
  result = result !& Hash(k.fontSize)
  result = result !& Hash(k.letterSpacing)
  result = !$ result

func `==`*(a, b: TextKey): bool =
  a.text == b.text and a.fontId == b.fontId and
    a.fontSize == b.fontSize and a.letterSpacing == b.letterSpacing

proc reportError(ctx: Context; kind: ErrorKind; message: string; id: uint32 = 0) =
  ## Errors are queued, never raised: layout always produces a best-effort
  ## result and the host drains the queue with `takeErrors`.
  ctx.errors.add ErrorData(kind: kind, message: message, elementId: id)

func sliceStr(s: string; start, length: int): string =
  ## `s[start ..< start+length]` without strutils.
  if length <= 0 or start < 0 or start >= s.len:
    return ""
  let last = min(start + length - 1, s.high)
  result = newString(last - start + 1)
  for i in start .. last:
    result[i - start] = s[i]

proc spaceWidth(ctx: Context; cfg: TextConfig): float32 =
  if ctx.measureText == nil:
    return 0
  ctx.measureText(" ", cfg).width

func gridOn*(ctx: Context): bool {.inline.} =
  ## Laying out for a character grid (see `setGrid`).
  ctx.grid.width > 0 and ctx.grid.height > 0

func lineHeightOf(ctx: Context; cfg: TextConfig; measured: float32): float32 =
  ## The pitch of `cfg`'s lines: its `lineHeight` when set, else the measured
  ## line height. On a grid every line is one row, whatever was asked for.
  if cfg.lineHeight > 0 and not gridOn(ctx): float32(cfg.lineHeight)
  else: measured

proc measureTextCached*(ctx: Context; text: string; cfg: TextConfig): Measurement =
  result = Measurement(words: @[])
  ## Cached measurement of `text` under `cfg`: unwrapped size, the widest
  ## single word (the minimum width a wrapped layout may shrink to), and the
  ## measured word list used by the wrapping pass. Word splitting happens on
  ## spaces and newlines, exactly like Clay: a space is folded into the
  ## preceding word's measured width, and every newline contributes a
  ## zero-length marker word that forces a line break.
  let key = TextKey(
    text: text, fontId: cfg.fontId,
    fontSize: cfg.fontSize, letterSpacing: cfg.letterSpacing,
  )
  if ctx.textCache.hasKey(key):
    result = ctx.textCache.getOrDefault(key)
    result.generation = ctx.generation
    ctx.textCache[key] = result
    return

  if ctx.measureText == nil:
    reportError(ctx, measureTextMissing,
      "no measure function installed: call setMeasureText before laying out text")
    return

  var m = Measurement(words: @[], generation: ctx.generation)
  let space = ctx.measureText(" ", cfg).width

  var start = 0
  var stop = 0
  var lineWidth: float32 = 0
  var measuredWidth: float32 = 0
  var measuredHeight: float32 = 0

  while stop < text.len:
    let current = text[stop]
    if current == ' ' or current == '\n':
      let length = stop - start
      var dims = Size()
      if length > 0:
        dims = ctx.measureText(sliceStr(text, start, length), cfg)
      m.minWidth = max(dims.width, m.minWidth)
      measuredHeight = max(measuredHeight, dims.height)
      if current == ' ':
        # The space joins the preceding word: its width is folded into the
        # word so line-fitting accounts for it.
        let wordWidth = dims.width + space
        m.words.add MeasuredWord(
          start: int32(start), length: int32(length + 1), width: wordWidth)
        lineWidth += wordWidth
      else:
        if length > 0:
          m.words.add MeasuredWord(
            start: int32(start), length: int32(length), width: dims.width)
        # Newline marker: zero-length word starting after the '\n'.
        m.words.add MeasuredWord(start: int32(stop + 1), length: 0, width: 0)
        lineWidth += dims.width
        measuredWidth = max(lineWidth, measuredWidth)
        m.containsNewlines = true
        lineWidth = 0
      start = stop + 1
    inc stop

  if stop - start > 0:
    let dims = ctx.measureText(sliceStr(text, start, stop - start), cfg)
    m.words.add MeasuredWord(
      start: int32(start), length: int32(stop - start), width: dims.width)
    lineWidth += dims.width
    measuredHeight = max(measuredHeight, dims.height)
    m.minWidth = max(dims.width, m.minWidth)

  measuredWidth = max(lineWidth, measuredWidth) - float32(cfg.letterSpacing)
  if measuredHeight == 0 and text.len > 0:
    # Only newlines and spaces: no word carried a height, yet every line
    # still needs the font's pitch -- else a run of empty lines collapses
    # to nothing and a caret on them never leaves the top.
    measuredHeight = ctx.measureText(" ", cfg).height
  m.unwrapped = Size(width: measuredWidth, height: measuredHeight)
  result = m
  ctx.textCache[key] = result

proc evictStaleMeasurements(ctx: Context) =
  ## Drop measurements untouched for more than 2 frames: with stable text
  ## the cache only ever holds this frame plus a little slack. Mirrors Clay's
  ## lazy `generation - entry.generation > 2` eviction during lookups.
  var dead: seq[TextKey] = @[]
  for k, m in ctx.textCache:
    if ctx.generation > m.generation and ctx.generation - m.generation > 2:
      dead.add k
  for k in dead:
    ctx.textCache.del(k)

proc wrappedLines*(ctx: Context; text: string; cfg: TextConfig;
                   maxWidth: float32): seq[TextLine] =
  ## Break `text` into the lines Clay would lay out for it in a box of
  ## `maxWidth`: the engine's wrapping pass, exposed so text editors can
  ## place a caret on the very same line grid the renderer draws.
  ## `TextLine.dims.height` is uniform: the line pitch.
  result = @[]
  let m = measureTextCached(ctx, text, cfg)
  let lineHeight = lineHeightOf(ctx, cfg, m.unwrapped.height)

  if not m.containsNewlines and m.unwrapped.width <= maxWidth:
    # Fast path: the whole string is one line, sized to the container box.
    result.add TextLine(start: 0, length: int32(text.len),
                        dims: Size(width: maxWidth, height: lineHeight))
    return

  let space = spaceWidth(ctx, cfg)
  var lineWidth: float32 = 0
  var lineLength: int32 = 0
  var lineStart: int32 = 0
  var wi = 0

  while wi < m.words.len:
    let w = m.words[wi]
    if lineLength == 0 and lineWidth + w.width > maxWidth:
      # A single word wider than the line: emit it overflowing, consume it.
      result.add TextLine(
        start: w.start, length: w.length,
        dims: Size(width: w.width, height: lineHeight))
      lineStart = w.start + w.length
      inc wi
    elif w.length == 0 or lineWidth + w.width > maxWidth:
      # Line full (or explicit newline): flush what we have.
      var dims = Size(width: lineWidth, height: lineHeight)
      var length = lineLength
      let lastIdx = max(lineStart + lineLength - 1, 0)
      if lineLength > 0 and text[lastIdx] == ' ':
        # Trailing spaces are not part of the visual line width.
        dims.width -= space
        length -= 1
      result.add TextLine(start: lineStart, length: length, dims: dims)
      if lineLength == 0 or w.length == 0:
        inc wi ## consume the newline marker; an oversized word that merely
               ## did not fit becomes the first word of the next line instead
      lineWidth = 0
      lineLength = 0
      lineStart = w.start
    else:
      lineWidth += w.width + float32(cfg.letterSpacing)
      lineLength += w.length
      inc wi

  if lineLength > 0:
    result.add TextLine(
      start: lineStart, length: lineLength,
      dims: Size(width: lineWidth - float32(cfg.letterSpacing), height: lineHeight))
  elif text.len > 0 and text[^1] == '\n':
    # A trailing newline opens an empty last line. Clay drops it; an editor
    # needs it laid out, so the box grows when Enter is pressed at the end
    # and the caret below the last newline has a line to sit on.
    result.add TextLine(start: int32(text.len), length: 0,
                        dims: Size(width: 0, height: lineHeight))

proc wrapTextElement*(ctx: Context; el: var LayoutElement) =
  ## Break `el`'s text into lines that fit `el.dims.width`, filling
  ## `el.lines` and updating `el.dims.height`. Clay runs this once per text
  ## element between the horizontal and vertical sizing passes; so do we.
  el.lines = wrappedLines(ctx, el.text, el.textCfg, el.dims.width)
  let m = measureTextCached(ctx, el.text, el.textCfg)
  let lineHeight = lineHeightOf(ctx, el.textCfg, m.unwrapped.height)
  el.dims.height = lineHeight * float32(el.lines.len)
