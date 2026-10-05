## Theming for the ellipse_ui widget set.
##
## A `Theme` collects every visual decision the standard widgets make:
## colours (`Palette`), the type scale (`TextSizes`), corner radii
## (`Radii`), sizes/paddings/borders/gaps (`Metrics`) and the default
## scrollbar style. Widgets read the live theme *while they render*, so
## pushing a change takes effect from the next widget declaration on --
## the immediate-mode way to customise a control or apply an effect:
##
##   activeTheme.palette.accent = rgb(220, 60, 60)  ## onward for the frame
##
##   pushTheme()                                    ## snapshot ..
##   activeTheme.radii.button = 0.0                 ## .. square buttons ..
##   discard button(id, "Square")
##   popTheme()                                     ## .. and restore
##
##   withTheme:                                     ## scoped: only the
##     activeTheme.palette.buttonBg = rgb(150, 40, 40) ## widgets in the block
##     discard button(id, "Delete")
##
## `pushTheme(t)` swaps in a whole theme, `popTheme()` restores the one
## underneath it; `setTheme(t)` replaces the current theme without a
## snapshot, and `setTheme(defaultTheme())` resets everything.
##
## `defaultTheme()` reproduces the widget set's original hard-coded look
## token for token. The colour tokens keep the old exported constant
## names (`bgColor`, `panelBg`, `accent`, `textColor`, ...) as zero-
## argument templates over the live theme, so existing call sites like
## `col(...).bg(panelBg)` now read the theme instead of a const.

import clay

type
  Palette* = object
    ## Every colour a standard widget paints with. Alpha 0 means
    ## "no rectangle" (clay's rule), so e.g. `panelBorder` can be
    ## muted to nothing by dropping its alpha.
    bg*: Color           ## app/root backdrop
    panelBg*: Color      ## panels, popovers, cards, active tab
    panelBorder*: Color  ## hairlines and idle borders everywhere
    buttonBg*: Color     ## raised surfaces: buttons, combo fields, steppers
    buttonHoverBg*: Color ## and their hover/open variant
    buttonPressBg*: Color ## the compressed fill while a press is held
    fieldBg*: Color      ## text-field and tick-box interiors
    selectedBg*: Color   ## the chosen row in an option list
    accent*: Color       ## focus rings, checked boxes, links, badges
    textColor*: Color    ## primary text
    dimColor*: Color     ## placeholders, captions, hints
    labelColor*: Color   ## field labels and secondary text
    onAccent*: Color     ## text sitting on an accent fill (badges)
    shadow*: Color       ## drop behind menus and popovers

  TextSizes* = object
    ## The type scale, in points. `control` is the default size of any
    ## interactive widget's label; `option` its compact sibling.
    h1*, h2*, h3*, h4*, h5*, h6*: uint16
    button*: uint16      ## `ui.button` label
    menu*: uint16        ## menu bar, items and shortcuts
    control*: uint16     ## fields, checkboxes, switches, body copy
    option*: uint16      ## tab labels, dropdown rows
    chevron*: uint16     ## dropdown arrows
    cardTitle*: uint16
    statLabel*, statValue*, statHint*: uint16
    label*, caption*, overline*, badge*: uint16

  Radii* = object
    ## Corner rounding, in pixels.
    button*: float32     ## buttons, combo fields, checkbox hover pill
    field*: float32      ## text/number fields
    check*: float32      ## tick boxes
    tick*: float32       ## the filled square inside a checked box
    inner*: float32      ## menu items, list rows, steppers
    item*: float32       ## `ui.listRow` hover rows
    panel*: float32      ## framed scroll panels (`scrollbars.scrollPanel`)
    popover*: float32    ## dropdown/menu panels
    popoverShadow*: float32 ## the shadow behind them
    tab*: float32        ## tab buttons (top corners)
    tabPanel*: float32   ## the tab content panel (bottom corners)
    card*: float32
    pill*: float32       ## badges
    switch*: float32     ## switch track
    switchKnob*: float32

  Metrics* = object
    ## Sizes, paddings, gaps and border widths, in pixels.
    # control sizes
    controlHeight*: float32   ## text fields, combos, multiselects
    toolbarHeight*: float32   ## the menu/tool bar strip
    checkSize*: float32       ## checkbox tick-box edge
    tickSize*: float32        ## inner filled square
    checkSizeSm*: float32     ## multiselect rows' smaller boxes
    tickSizeSm*: float32
    switchWidth*, switchHeight*, switchKnob*: float32
    stepperSize*: float32     ## the +/- squares in number fields
    listMaxHeight*: float32   ## combo dropdown scroll height cap
    multiListMaxHeight*: float32
    textRowHeight*: float32   ## multiline field row unit
    popoverOffset*: float32   ## gap between anchor and floating panel

    # paddings
    padButton*, padMenuItem*, padOption*, padList*, padFieldX*, padFieldY*: int
    padCheckRow*, padCard*, padStat*, padPanel*, padToolbar*, padSwitch*: int
    padTabX*, padTabTop*, padTabBottom*: int
    padMinor*: int            ## small insets (labels, footers)
    padItem*: int             ## `ui.listRow` rows

    # gaps between siblings
    gapCard*, gapCardRow*, gapProse*, gapTight*, gapList*: int

    # border widths
    borderRaised*: int        ## buttons
    borderHairline*: int      ## panels, fields, idle everything
    borderTab*: int           ## active-tab underline

    # pressed state
    pressOffset*: int         ## px the content of a held control shifts down

    # heading spacing
    headingPadH1*, headingPadH2*, headingPadH3*, headingPadMinor*: int
    headingPadBottom*: int

  ScrollbarStyle* = object
    ## A floating scrollbar's geometry and colours (see
    ## `ellipse_ui/widgets/scrollbars`).
    width*: float32      ## bar thickness
    margin*: float32     ## inset from the container's edge
    radius*: float32     ## corner radius of track and thumb
    minThumb*: float32   ## shortest thumb, in pixels
    track*: Color
    thumb*: Color
    thumbHot*: Color     ## hovered or dragged thumb

  Theme* = object
    palette*: Palette
    text*: TextSizes
    radii*: Radii
    metrics*: Metrics
    scrollbar*: ScrollbarStyle

## --- the default theme ---------------------------------------------------------
##
## One dark baseline; every value matches what the widgets hardcoded
## before theming existed.

func defaultPalette*(): Palette =
  Palette(
    bg: rgb(12, 12, 16),
    panelBg: rgb(28, 30, 38),
    panelBorder: rgb(60, 64, 78),
    buttonBg: rgb(52, 56, 72),
    buttonHoverBg: rgb(84, 90, 116),
    buttonPressBg: rgb(38, 41, 53),
    fieldBg: rgb(20, 22, 28),
    selectedBg: rgb(64, 70, 92),
    accent: rgb(96, 130, 220),
    textColor: rgb(230, 232, 238),
    dimColor: rgb(130, 134, 150),
    labelColor: rgb(180, 184, 196),
    onAccent: rgb(12, 12, 16),
    shadow: rgb(0, 0, 0, 70),
  )

func defaultTextSizes*(): TextSizes =
  TextSizes(
    h1: 42, h2: 32, h3: 26, h4: 21, h5: 18, h6: 16,
    button: 28, menu: 18, control: 18, option: 17, chevron: 16,
    cardTitle: 19, statLabel: 14, statValue: 26, statHint: 13,
    label: 15, caption: 14, overline: 13, badge: 13,
  )

func defaultRadii*(): Radii =
  Radii(
    button: 8.0, field: 8.0, check: 5.0, tick: 3.0, inner: 6.0,
    item: 6.0, panel: 10.0,
    popover: 10.0, popoverShadow: 14.0, tab: 8.0, tabPanel: 10.0,
    card: 12.0, pill: 12.0, switch: 12.0, switchKnob: 8.0,
  )

func defaultMetrics*(): Metrics =
  Metrics(
    controlHeight: 40.0, toolbarHeight: 48.0,
    checkSize: 20.0, tickSize: 10.0, checkSizeSm: 18.0, tickSizeSm: 9.0,
    switchWidth: 44.0, switchHeight: 24.0, switchKnob: 16.0,
    stepperSize: 26.0,
    listMaxHeight: 240.0, multiListMaxHeight: 260.0,
    textRowHeight: 26.0, popoverOffset: 6.0,
    padButton: 8, padMenuItem: 8, padOption: 6, padList: 4,
    padFieldX: 10, padFieldY: 8, padCheckRow: 4, padCard: 14, padStat: 12,
    padPanel: 12, padToolbar: 4, padSwitch: 3, padTabX: 14, padTabTop: 7,
    padTabBottom: 6, padMinor: 4, padItem: 6,
    gapCard: 10, gapCardRow: 12, gapProse: 8, gapTight: 6, gapList: 2,
    borderRaised: 2, borderHairline: 1, borderTab: 2, pressOffset: 2,
    headingPadH1: 28, headingPadH2: 20, headingPadH3: 14,
    headingPadMinor: 10, headingPadBottom: 6,
  )

func defaultScrollbarStyle*(): ScrollbarStyle =
  ScrollbarStyle(
    width: 10.0, margin: 4.0, radius: 5.0, minThumb: 28.0,
    track: rgb(6, 6, 9, 120),
    thumb: rgb(118, 124, 148, 170),
    thumbHot: rgb(168, 176, 205, 235))

func defaultTheme*(): Theme =
  Theme(
    palette: defaultPalette(),
    text: defaultTextSizes(),
    radii: defaultRadii(),
    metrics: defaultMetrics(),
    scrollbar: defaultScrollbarStyle(),
  )

## --- the live theme --------------------------------------------------------------
##
## Widgets resolve their tokens against `activeTheme` at declaration
## time, so anything that mutates it -- direct field writes, the stack
## below, or `withTheme` -- takes effect from the *next* widget on.

var activeTheme*: Theme = defaultTheme()

var themeStack: seq[Theme] = @[]

proc setTheme*(theme: sink Theme) =
  ## Replace the live theme outright (no snapshot; `setTheme(defaultTheme())`
  ## resets to the built-in look).
  activeTheme = theme

proc pushTheme*(theme: sink Theme) =
  ## Snapshot the live theme and swap in `theme` for the widgets that follow.
  themeStack.add activeTheme
  activeTheme = theme

proc pushTheme*() =
  ## Snapshot the live theme so the caller can mutate it freely;
  ## `popTheme()` puts the snapshot back.
  themeStack.add activeTheme

template withTheme*(body: untyped) =
  ## Run `body` against a temporarily patched theme: mutate `activeTheme`
  ## freely inside the block and every widget declared there picks the
  ## changes up; the theme is restored on the way out.
  ##
  ##   withTheme:
  ##     activeTheme.palette.buttonBg = rgb(150, 40, 40)
  ##     discard button(id, "Delete")
  block:
    let savedTheme = activeTheme
    body
    activeTheme = savedTheme

proc popTheme*() =
  ## Restore the theme `pushTheme` snapshotted; a no-op on an empty stack.
  if themeStack.len > 0:
    activeTheme = themeStack.pop()

## --- token readers ---------------------------------------------------------------
##
## Colour accessors keep the names the widget set shipped before theming
## (`bgColor`, `panelBg`, `accent`, ...) -- now zero-argument templates
## over the live palette, usable exactly like the old constants:
## `col(...).bg(panelBg)`. Sizes are read as `activeTheme.text.control`,
## `activeTheme.radii.button`, `activeTheme.metrics.padButton` and
## friends, often via a `let t = activeTheme` at the top of a widget proc.

template bgColor*(): Color = activeTheme.palette.bg
template panelBg*(): Color = activeTheme.palette.panelBg
template panelBorder*(): Color = activeTheme.palette.panelBorder
template buttonBg*(): Color = activeTheme.palette.buttonBg
template buttonHoverBg*(): Color = activeTheme.palette.buttonHoverBg
template buttonPressBg*(): Color = activeTheme.palette.buttonPressBg
template fieldBg*(): Color = activeTheme.palette.fieldBg
template selectedBg*(): Color = activeTheme.palette.selectedBg
template accent*(): Color = activeTheme.palette.accent
template textColor*(): Color = activeTheme.palette.textColor
template dimColor*(): Color = activeTheme.palette.dimColor
template labelColor*(): Color = activeTheme.palette.labelColor
template onAccentColor*(): Color = activeTheme.palette.onAccent
template shadowColor*(): Color = activeTheme.palette.shadow

## A few numeric tokens share the shortcut treatment where call sites keep
## needing them (list styling, framed panels): the rest read naturally as
## `activeTheme.radii.card` and friends.

template itemRadius*(): float32 = activeTheme.radii.item
template panelRadius*(): float32 = activeTheme.radii.panel
template padItem*(): int = activeTheme.metrics.padItem
template hairline*(): int = activeTheme.metrics.borderHairline
