import std/[syncio]

import clay
import ellipse/logger
import ellipse/platform/platform
import ellipse/platform/renderer
import ellipse_ui/ui
import ellipse_ui/widgets

addHandler initStandardLogger()

# --- demo state: every value below is owned by this app, mutated through
# the immediate-mode round trip of the widget calls in `drawGallery` --------

var count = 0
var largeCount = false
var showIntro = true

var vsync = true
var wifi = false

var backend = 1
var modules: Selection = bit(0) or bit(2)

var artist = "Ada Lovelace"
var notes = ""

var quantity = 2
var volume = 0.5

var backends: seq[string] = @[]
var moduleNames: seq[string] = @[]
var tabNames: seq[string] = @[]

proc fillLists() =
  backends.add "OpenGL"
  backends.add "Vulkan"
  backends.add "Software"
  moduleNames.add "Render"
  moduleNames.add "Audio"
  moduleNames.add "Input"
  moduleNames.add "Networking"
  moduleNames.add "Logging"
  tabNames.add "Stats"
  tabNames.add "Session"
  tabNames.add "Actions"

proc resetAll() =
  count = 0
  largeCount = false
  showIntro = true
  vsync = true
  wifi = false
  backend = 1
  modules = bit(0) or bit(2)
  artist = "Ada Lovelace"
  notes = ""
  quantity = 2
  volume = 0.5

proc tabActions() =
  if button(hashId("btn-tab-reset"), "Reset all"):
    resetAll()

proc counterFontSize(): uint16 =
  if largeCount:
    return 96.uint16
  return 48.uint16

# --- page scaffolding -------------------------------------------------------

widget Page(body: proc(): void):
  clay "app", col(width = grow(), height = grow(), alignX = centerX)
      .bg(bgColor):
    body()

widget Toolbar(body: proc(): void):
  toolBar("toolbar", body)

widget Scroll(body: proc(): void):
  ## Wheel-scrollable page body: a vertical clip container whose children
  ## ride the engine's current scroll offset (`updateUI` feeds it the wheel,
  ## through the accel/glide filter in `ui`). A floating scrollbar hugs the
  ## right edge whenever the content overflows.
  clay "scroll", col(width = grow(), height = grow(), padding = padAll(28))
      .clip(horizontal = false, vertical = true,
            childOffset = currentScrollOffset()):
    clay "content", col(width = grow(max = 820), height = fit(), gap = 10,
                        alignX = centerX):
      body()
    scrollbar(hashId("page.bar"), hashId("scroll"))

# --- the gallery itself -------------------------------------------------------

proc drawGallery() =
  Scroll:
    heading("Widget Gallery", 1)
    overline("ellipse_ui on clay")
    if showIntro:
      bodyText("The standard widget set of the new UI system: toggles, dropdowns, text and number entry, headings and reading text -- all immediate-mode clay layout blocks. Scroll with the wheel or drag the floating scrollbar thumbs; the File and View menus above drive this same state.")

    Section(title = "Toggles & buttons"):
      clay "trow", row(width = grow(), height = fit(), gap = 28,
                       alignY = centerY):
        vsync = checkbox(hashId("cb-vsync"), "VSync", vsync)
        wifi = switch(hashId("sw-wifi"), "Wifi", wifi)
        if button(hashId("btn-inc"), "Increment", height = fixedPx(40)):
          inc count
        badge("beta")

    Section(title = "Dropdowns"):
      clay "drow", row(width = grow(), height = fit(), gap = 16,
                       alignY = top):
        Labeled(label = "Renderer backend"):
          backend = comboBox(hashId("combo-backend"), backends, backend,
                             "Pick one")
        Labeled(label = "Engine modules"):
          modules = multiSelect(hashId("multi-modules"), moduleNames,
                                modules, "None selected")

    Section(title = "Text entry"):
      clay "trow2", row(width = grow(), height = fit(), gap = 16,
                        alignY = top):
        Labeled(label = "Artist"):
          artist = textField(hashId("tf-artist"), artist, "Your name")
        Labeled(label = "Notes"):
          notes = multilineField(hashId("tf-notes"), notes,
                                 "Leave a note...", rows = 3)
      caption("Enter commits, Escape reverts, a click outside commits too. Caret and selection live in the widget; the text is yours.")
      caption("Emacs bindings: C-a/C-e line edges, C-b/C-f chars, M-b/M-f words, Up/Down and C-p/C-n lines, C-k/C-u/C-w/M-d kill, C-y yank, C-d/C-h delete, Enter commit, C-g or Escape cancel.")

    Section(title = "Numbers"):
      clay "nrow", row(width = grow(), height = fit(), gap = 16,
                       alignY = top):
        Labeled(label = "Quantity"):
          quantity = intNumberField(hashId("nf-qty"), quantity, 1)
        Labeled(label = "Volume (0..1, step 0.05)"):
          volume = numberField(hashId("nf-vol"), volume, 0.05, 0.0, 1.0)
      label("Counter -- driven by the File menu, too")
      clay "counter", row(width = grow(), height = fit(), gap = 12,
                          alignY = centerY):
        textElement($count, TextConfig(fontSize: counterFontSize(),
                                       color: textColor))
        clay "buttons", row(gap = 8):
          if button(hashId("dec"), "Decrement", height = fixedPx(44)):
            dec count
          if button(hashId("inc"), "Increment", height = fixedPx(44)):
            inc count

    Section(title = "Tabs & cards"):
      caption("A TabbedView container: the strip swaps whole pages, and cards frame the controls on them.")
      clay "tabwrap", row(width = grow(), height = fixedPx(250)):
        TabbedView(id = hashId("gallery-tabs"), tabs = tabNames):
          let page = activeTab(hashId("gallery-tabs"))
          if page == 0:
            CardRow:
              StatCard(label = "Count", value = $count, hint = "menu or buttons")
              StatCard(label = "Quantity", value = $quantity, hint = "")
              StatCard(label = "Modules", value = $countSelected(modules),
                       hint = "of " & $moduleNames.len)
          elif page == 1:
            Card(title = "Session", actions = emptySlot):
              bodyText("Cards hug their content; the empty `actions` slot costs nothing.")
              wifi = switch(hashId("sw-tab"), "Wifi", wifi)
          else:
            Card(title = "Actions", actions = tabActions):
              bodyText("The header's right edge is the `actions` slot -- here a button that resets the gallery.")

    Section(title = "Scrolling containers"):
      caption("Clip containers with floating scrollbars: grab a thumb and drag, click a bare track to jump, or spin the wheel -- the feel ramps up with velocity, glides to a stop, and springs at the ends.")
      clay "scrow", row(width = grow(), height = fixedPx(240), gap = 16,
                        alignY = top):
        clay "vpanel", col(width = pct(0.5), height = grow(), gap = 2,
                           padding = padAll(6))
            .bg(fieldBg)
            .border(1, panelBorder)
            .corner(10)
            .clip(horizontal = false, vertical = true,
                  childOffset = currentScrollOffset()):
          var r = 0
          while r < 24:
            openElement(localIdWithIndex("vpanel.row", uint32(r)))
            configureOpenElement(row(width = grow(), height = fit(),
                padding = padAll(6), alignY = centerY)
              .bg(if hovered(): buttonHoverBg else: panelBg)
              .corner(6))
            textElement("Module entry " & $r,
              TextConfig(fontSize: 16, color: textColor))
            closeElement()
            inc r
          scrollbar(hashId("vbar"), hashId("vpanel"))
        clay "hwrap", col(width = grow(), height = grow(), gap = 6):
          label("Horizontal strip")
          clay "hstrip", row(width = grow(), height = grow(), gap = 10,
                             padding = padAll(8))
              .bg(fieldBg)
              .border(1, panelBorder)
              .corner(10)
              .clip(horizontal = true, vertical = false,
                    childOffset = currentScrollOffset()):
            var c = 0
            while c < 10:
              openElement(localIdWithIndex("hstrip.card", uint32(c)))
              configureOpenElement(col(width = fixedPx(150), height = grow(),
                  alignX = centerX, alignY = centerY, padding = padAll(10))
                .bg(if hovered(): buttonHoverBg else: buttonBg)
                .corner(8)
                .border(1, panelBorder))
              textElement("Card " & $c,
                TextConfig(fontSize: 18, color: textColor))
              closeElement()
              inc c
            scrollbar(hashId("hbar"), hashId("hstrip"))

    clay "footer", row(width = grow(), height = fit(), gap = 14,
                       alignY = centerY):
      if textLink(hashId("lnk-intro"), "Toggle intro"):
        showIntro = not showIntro
      badge(if vsync: "vsync on" else: "vsync off")

proc update() {.raises.} =
  updateUI()

  layout:
    Page:
      Toolbar:
        menu("File") do():
          if menuItem("Increment", "Ctrl++"): inc count
          if menuItem("Decrement", "Ctrl+-"): dec count
          menuSeparator()
          if menuItem("Scroll to top"):
            setScrollPosition(hashId("scroll"), vec2(0.0, 0.0))
          if menuItem("Reset gallery"): resetAll()
        menu("View") do():
          if menuItem("Intro text"): showIntro = not showIntro
          if menuItem("Large count"): largeCount = not largeCount
      drawGallery()

proc render() {.raises.} =
  drawCommands()

when isMainModule:
  try:
    fillLists()
    initialize()
    initializeRenderer()
    let (w, h) = windowPixelSize()
    setCurrentContext(initContext(size(w, h)))
    setMeasureText(measureText)
    start(update, render)
  except ErrorCode:
    discard
