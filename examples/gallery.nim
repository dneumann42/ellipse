## Widget Gallery -- a tour of the ellipse_ui standard widget set.
##
## Every widget the library ships, on one scrolling page that drives
## module-owned state through the immediate-mode round trip, plus a modal
## form (`gallery/memberform`) that puts most of them in a dialog at once,
## and the quick popups of `ellipse_ui/dialogs` -- each of which can open
## over the page or in a window of its own.
##
## Run:   make run_gallery
##        F1 in the window for the debug overlay

import std/[syncio]

import ellipse_ui

import gallery/memberform

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

var themeIndex = 0

var ownWindow = false      ## dialogs open as their own windows
var lastAnswer = ""

var backends: seq[string] = @[]
var moduleNames: seq[string] = @[]
var tabNames: seq[string] = @[]
var themeNames: seq[string] = @[]

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
  themeNames.add "Dark (default)"
  themeNames.add "Light"
  themeNames.add "High contrast"
  themeNames.add "Warm sepia"

# --- themes ------------------------------------------------------------------
# Presets layered over the library default; every widget reads `activeTheme`
# while it renders, so `setTheme` restyles the whole gallery from the next
# declaration on (the next frame repaints everything anyway).

func lightTheme(): Theme =
  var t = defaultTheme()
  t.palette = Palette(
    bg: rgb(244, 245, 248),
    panelBg: rgb(255, 255, 255),
    panelBorder: rgb(208, 212, 222),
    buttonBg: rgb(226, 230, 238),
    buttonHoverBg: rgb(203, 210, 224),
    buttonPressBg: rgb(178, 187, 206),
    fieldBg: rgb(255, 255, 255),
    selectedBg: rgb(206, 221, 248),
    accent: rgb(46, 92, 190),
    textColor: rgb(24, 27, 34),
    dimColor: rgb(116, 122, 138),
    labelColor: rgb(72, 78, 94),
    onAccent: rgb(255, 255, 255),
    shadow: rgb(20, 24, 40, 60),
  )
  t.scrollbar = ScrollbarStyle(
    width: 10.0, margin: 4.0, radius: 5.0, minThumb: 28.0,
    track: rgb(226, 229, 238, 150),
    thumb: rgb(150, 158, 176, 190),
    thumbHot: rgb(112, 122, 145, 230))
  t

func contrastTheme(): Theme =
  var t = defaultTheme()
  t.palette = Palette(
    bg: rgb(0, 0, 0),
    panelBg: rgb(8, 8, 8),
    panelBorder: rgb(255, 255, 255),
    buttonBg: rgb(24, 24, 24),
    buttonHoverBg: rgb(64, 64, 64),
    buttonPressBg: rgb(130, 130, 130),
    fieldBg: rgb(0, 0, 0),
    selectedBg: rgb(0, 0, 128),
    accent: rgb(255, 214, 0),
    textColor: rgb(255, 255, 255),
    dimColor: rgb(208, 208, 208),
    labelColor: rgb(235, 235, 235),
    onAccent: rgb(0, 0, 0),
    shadow: rgb(0, 0, 0, 0),
  )
  t.radii = Radii(  ## sharp edges everywhere -- except the switch pill
    button: 0.0, field: 0.0, check: 0.0, tick: 0.0, inner: 0.0,
    item: 0.0, panel: 0.0,
    popover: 0.0, popoverShadow: 0.0, tab: 0.0, tabPanel: 0.0,
    card: 0.0, pill: 0.0, switch: 12.0, switchKnob: 8.0,
  )
  t.scrollbar = ScrollbarStyle(
    width: 12.0, margin: 4.0, radius: 0.0, minThumb: 32.0,
    track: rgb(24, 24, 24, 200),
    thumb: rgb(255, 214, 0, 230),
    thumbHot: rgb(255, 255, 255, 255))
  t

func warmTheme(): Theme =
  var t = defaultTheme()
  t.palette = Palette(
    bg: rgb(28, 24, 20),
    panelBg: rgb(42, 36, 30),
    panelBorder: rgb(82, 68, 52),
    buttonBg: rgb(72, 60, 46),
    buttonHoverBg: rgb(98, 82, 62),
    buttonPressBg: rgb(46, 38, 29),
    fieldBg: rgb(34, 29, 24),
    selectedBg: rgb(92, 74, 52),
    accent: rgb(224, 164, 78),
    textColor: rgb(240, 230, 214),
    dimColor: rgb(156, 140, 118),
    labelColor: rgb(200, 184, 158),
    onAccent: rgb(26, 22, 18),
    shadow: rgb(0, 0, 0, 80),
  )
  t.scrollbar = ScrollbarStyle(
    width: 10.0, margin: 4.0, radius: 5.0, minThumb: 28.0,
    track: rgb(20, 17, 14, 140),
    thumb: rgb(150, 128, 96, 180),
    thumbHot: rgb(200, 170, 120, 235))
  t

proc applyTheme() =
  case themeIndex
  of 1: setTheme(lightTheme())
  of 2: setTheme(contrastTheme())
  of 3: setTheme(warmTheme())
  else: setTheme(defaultTheme())

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
  themeIndex = 0
  applyTheme()

proc memberLine(m: Member): string =
  result = m.name & "  <" & m.email & ">  " & roleNames[m.role] & ", " &
    teamNames[m.team] & ", " & $m.hours & " h/wk"
  if m.admin: result.add ", admin"
  if m.remote: result.add ", remote"

proc dialogMode(): DialogMode =
  if ownWindow: dmWindow else: dmInline

proc alertDone(r: DialogResult) =
  lastAnswer = "alert closed"

proc confirmDone(yes: bool) =
  lastAnswer = if yes: "confirm: deleted" else: "confirm: kept"

proc askDone(i: int) =
  lastAnswer = "ask: answer #" & $i

proc promptDone(s: string) =
  lastAnswer = "prompt: \"" & s & "\""

proc popupButtons() =
  let m = dialogMode()
  if button(hashId("pop-alert"), "Alert", height = fixedPx(40)):
    alert("The build finished without warnings.", title = "Build",
          detail = "412 files, 3.1 s", mode = m, onDone = alertDone)
  if button(hashId("pop-confirm"), "Confirm", height = fixedPx(40)):
    confirm("Delete the 3 selected files?", confirmDone, title = "Delete",
            yes = "Delete", mode = m)
  if button(hashId("pop-ask"), "Ask", height = fixedPx(40)):
    ask("Save changes to notes.txt before closing?",
        ["Save", "Don't save", "Cancel"], askDone,
        title = "Unsaved changes", cancelIndex = 2, mode = m)
  if button(hashId("pop-prompt"), "Prompt", height = fixedPx(40)):
    prompt("Name the new folder:", promptDone, title = "New folder",
           text = "Untitled", mode = m)
  if button(hashId("pop-toast"), "Toast", height = fixedPx(40)):
    toast("Copied to clipboard")

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
  ## through the accel/glide filter in `ui`). `scrollPanel` attaches the
  ## floating scrollbar that hugs the right edge whenever content overflows.
  scrollPanel "scroll", col(width = grow(), height = grow(), padding = padAll(28))
      .clip(horizontal = false, vertical = true,
            childOffset = currentScrollOffset()):
    clay "content", col(width = grow(max = 820), height = fit(), gap = 10,
                        alignX = centerX):
      body()

# --- the gallery itself -------------------------------------------------------

proc drawGallery() =
  Scroll:
    heading("Widget Gallery", 1)
    overline("ellipse_ui on clay")
    if showIntro:
      bodyText("The standard widget set of the new UI system: toggles, dropdowns, text and number entry, headings and reading text -- all immediate-mode clay layout blocks. Scroll with the wheel or drag the floating scrollbar thumbs; the File and View menus above drive this same state.")

    Section(title = "Theme"):
      clay "throw", row(width = grow(), height = fit(), gap = 16,
                        alignY = top):
        Labeled(label = "Look"):
          let sel = comboBox(hashId("combo-theme"), themeNames, themeIndex,
                             "Pick one")
          if sel != themeIndex:
            themeIndex = sel
            applyTheme()
      caption("One combobox swaps the live theme; every widget -- menus, fields, scrollbars, this very dropdown -- reads its tokens from `activeTheme` as it renders.")

    Section(title = "Toggles & buttons"):
      clay "trow", row(width = grow(), height = fit(), gap = 28,
                       alignY = centerY):
        vsync = checkbox(hashId("cb-vsync"), "VSync", vsync)
        wifi = switch(hashId("sw-wifi"), "Wifi", wifi)
        if button(hashId("btn-inc"), "Increment", height = fixedPx(48)):
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
                                 "Leave a note...", rows = 3, maxLines = 6)
      caption("Enter commits, Escape reverts, a click outside commits too. Caret and selection live in the widget; the text is yours. Notes grows with each new line up to six, then scrolls.")
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
        text($count, counterFontSize())
        clay "buttons", row(gap = 8):
          if button(hashId("dec"), "Decrement", height = fixedPx(44)):
            dec count
          if button(hashId("inc"), "Increment", height = fixedPx(44)):
            inc count

    Section(title = "Tabs & cards"):
      caption("A TabbedView container: the strip swaps whole pages, and cards frame the controls on them.")
      clay "tabwrap", row(width = grow(), height = fixedPx(250)):
        TabbedView(id = hashId("gallery-tabs"), tabs = tabNames):
          let page = tabIndex
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
        scrollPanel "vpanel", col(width = pct(0.5), height = grow(), gap = 2,
            padding = padAll(padItem))
            .bg(fieldBg)
            .border(hairline, panelBorder)
            .corner(panelRadius)
            .clip(horizontal = false, vertical = true,
                  childOffset = currentScrollOffset()):
          var r = 0
          while r < 24:
            listRow("vpanel.row", r):
              text("Module entry " & $r, 16)
            inc r
        clay "hwrap", col(width = grow(), height = grow(), gap = 6):
          label("Horizontal strip")
          scrollPanel "hstrip", row(width = grow(), height = grow(), gap = 10,
              padding = padAll(8))
              .bg(fieldBg)
              .border(hairline, panelBorder)
              .corner(panelRadius)
              .clip(horizontal = true, vertical = false,
                    childOffset = currentScrollOffset()):
            var c = 0
            while c < 10:
              listCard("hstrip.card", c, fixedPx(150)):
                text("Card " & $c)
              inc c

    Section(title = "Dialogs"):
      caption("A modal form: text, combos, a multiselect, number fields, switches and checkboxes in one dialog, validated on submit. Escape, Cancel or a click on the backdrop discards the draft; Enter (outside the bio) submits.")
      caption("With the switch on, every dialog here opens as a window of its own: a child process parented to this window, whose answer comes back serialized.")
      ownWindow = switch(hashId("sw-ownwin"), "Open dialogs in their own window",
                         ownWindow)
      clay "dlgrow", row(width = grow(), height = fit(), gap = 16,
                         alignY = centerY):
        if button(hashId("btn-member"), "Add team member...",
                  height = fixedPx(44)):
          memberform.begin(dialogMode())
        badge($members.len & " added")
      label("Quick popups")
      clay "poprow", row(width = grow(), height = fit(), gap = 10,
                         alignY = centerY):
        popupButtons()
      if lastAnswer.len > 0:
        caption("Last answer -- " & lastAnswer)
      if members.len == 0:
        caption("Nobody yet -- members you add show up here.")
      else:
        var i = 0
        while i < members.len:
          listRow("members.row", i):
            text(memberLine(members[i]), 15)
          inc i

    clay "footer", row(width = grow(), height = fit(), gap = 14,
                       alignY = centerY):
      if textLink(hashId("lnk-intro"), "Toggle intro"):
        showIntro = not showIntro
      badge(if vsync: "vsync on" else: "vsync off")

proc view()  =
  Page:
    Toolbar:
      menu("File") do():
        if menuItem("Increment", "Ctrl++"): inc count
        if menuItem("Decrement", "Ctrl+-"): dec count
        menuSeparator()
        if menuItem("Scroll to top"):
          setScrollPosition(hashId("scroll"), vec2(0.0, 0.0))
        if menuItem("Add team member..."): memberform.begin()
        if menuItem("Reset gallery"): resetAll()
      menu("View") do():
        if menuItem("Intro text"): showIntro = not showIntro
        if menuItem("Large count"): largeCount = not largeCount
    drawGallery()

proc prepare()  =
  ## Every process -- the gallery and its dialog windows -- needs the
  ## form's lists; the dialogs themselves are defined at module level.
  memberform.fillLists()

proc setup()  =
  fillLists()

when isMainModule:
  run App(window: WindowConfig(title: "Widget Gallery"), prepare: prepare,
          setup: setup, view: view)
