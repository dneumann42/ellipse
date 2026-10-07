## The gallery's modal form: "Add team member", one dialog holding most of
## the input widget set at once -- text, multiline, combos, a multiselect,
## number fields, switches and checkboxes -- with validation and a
## draft/commit round trip.
##
## The form edits `draft`, a private copy; nothing the gallery shows
## changes until Submit validates it and appends it to `members`. Cancel,
## Escape or a click on the backdrop throw the draft away. Errors stay
## hidden until the first submit attempt, then track every edit live.
##
## The overlay is the same shape as duck's dialogs (apps/duck/session): a
## floating backdrop at the root that captures the pointer, a centred
## panel, and a modal keymap that kills the app's chords while it's up.
## The panel's header and footer stay put; the form between them scrolls
## when the window is too short for it.

import std/strutils

import ellipse

type
  Member* = object
    name*, email*, bio*: string
    role*, team*: int
    access*: Selection
    hours*: int
    rate*: float
    admin*, remote*, welcome*: bool

var
  members*: seq[Member] = @[]

  showing = false
  fresh = false        ## just opened: drop the caret in the first field
  tried = false        ## a submit was attempted: show the errors
  agreed = false
  draft: Member

  roleNames*: seq[string] = @[]
  teamNames*: seq[string] = @[]
  accessNames: seq[string] = @[]

let
  nameId = hashId("mf.name")
  emailId = hashId("mf.email")
  roleId = hashId("mf.role")
  teamId = hashId("mf.team")
  accessId = hashId("mf.access")
  hoursId = hashId("mf.hours")
  rateId = hashId("mf.rate")
  adminId = hashId("mf.admin")
  remoteId = hashId("mf.remote")
  welcomeId = hashId("mf.welcome")
  agreeId = hashId("mf.agree")
  bioId = hashId("mf.bio")
  resetId = hashId("mf.reset")
  cancelId = hashId("mf.cancel")
  submitId = hashId("mf.submit")

proc fillLists() =
  roleNames.add "Engineer"
  roleNames.add "Designer"
  roleNames.add "Product manager"
  roleNames.add "Support"
  roleNames.add "Contractor"
  teamNames.add "Platform"
  teamNames.add "Renderer"
  teamNames.add "Widgets"
  teamNames.add "Tooling"
  accessNames.add "Source code"
  accessNames.add "CI pipelines"
  accessNames.add "Production"
  accessNames.add "Billing"
  accessNames.add "Analytics"

proc blank(): Member =
  Member(role: 0, team: -1, access: bit(0), hours: 40, rate: 85.0,
         welcome: true)

## --- validation ------------------------------------------------------------------

proc isBlank(s: string): bool =
  for c in s:
    if c notin {' ', '\t', '\n', '\r'}:
      return false
  true

proc nameError(): string =
  if isBlank(draft.name): "A name is required." else: ""

proc emailError(): string =
  let at = draft.email.find('@')
  if isBlank(draft.email):
    "An email is required."
  elif at <= 0 or draft.email.find('.', at + 2) < 0 or
       draft.email.find(' ') >= 0 or draft.email[^1] == '.':
    "That doesn't look like an email address."
  else: ""

proc teamError(): string =
  if draft.team < 0: "Pick a team." else: ""

proc accessError(): string =
  if draft.access == 0: "Grant at least one area." else: ""

proc hoursError(): string =
  if draft.role == 4 and draft.hours > 30:
    "Contractors are capped at 30 hours a week."
  else: ""

proc agreeError(): string =
  if not agreed: "Confirm before adding someone." else: ""

proc valid(): bool =
  nameError().len == 0 and emailError().len == 0 and
    teamError().len == 0 and accessError().len == 0 and
    hoursError().len == 0 and agreeError().len == 0

## --- verbs -------------------------------------------------------------------------

proc isOpen*(): bool = showing

proc begin*() =
  ## Open the dialog on a fresh draft.
  draft = blank()
  agreed = false
  tried = false
  showing = true
  fresh = true

proc dismiss*() =
  showing = false
  closeDropdown()

proc submit*() =
  tried = true
  if valid():
    members.add draft
    dismiss()

proc resetForm() =
  draft = blank()
  agreed = false
  tried = false

proc installKeys*() =
  ## The dialog's modal keymap: while it's up nothing installed before it
  ## (the gallery's own chords) sees a key.
  fillLists()
  var esc = Keymap(name: "gallery.form", modal: true,
                   active: proc (): bool {.closure.} = showing)
  esc.bindKey("Escape", dismiss)
  installKeymap(esc)
  # Enter submits -- except in the bio, where it breaks the line.
  var enter = Keymap(name: "gallery.form.enter",
                     active: proc (): bool {.closure.} =
                       showing and focusIdOf() != bioId.id)
  enter.bindKey("Enter", submit)
  installKeymap(enter)

## --- drawing -------------------------------------------------------------------------

let errColor = rgb(232, 96, 96)

proc fieldError(msg: string) =
  if tried and msg.len > 0:
    text(msg, activeTheme.text.caption, errColor)

proc group(title: string) =
  ## A form group's overline-style title.
  let t = activeTheme
  text(title, t.text.label, t.palette.accent)

proc money(v: float): string =
  "$" & formatFloat(v, ffDecimal, 2)

proc formBody() =
  let t = activeTheme
  group("IDENTITY")
  clay "mf.r1", row(width = grow(), height = fit(), gap = 12, alignY = top):
    Labeled(label = "Full name"):
      draft.name = textField(nameId, draft.name, "Grace Hopper")
      fieldError(nameError())
    Labeled(label = "Email"):
      draft.email = textField(emailId, draft.email, "grace@example.com")
      fieldError(emailError())
  clay "mf.r2", row(width = grow(), height = fit(), gap = 12, alignY = top):
    Labeled(label = "Role"):
      draft.role = comboBox(roleId, roleNames, draft.role, "Pick a role")
    Labeled(label = "Team"):
      draft.team = comboBox(teamId, teamNames, draft.team, "Choose a team")
      fieldError(teamError())

  group("ACCESS & SCHEDULE")
  clay "mf.r3", row(width = grow(), height = fit(), gap = 12, alignY = top):
    Labeled(label = "Access areas"):
      draft.access = multiSelect(accessId, accessNames, draft.access,
                                 "No access")
      fieldError(accessError())
    Labeled(label = "Hours / week"):
      draft.hours = intNumberField(hoursId, draft.hours, 1, 1, 60)
      fieldError(hoursError())
    Labeled(label = "Hourly rate"):
      draft.rate = numberField(rateId, draft.rate, 5.0, 0.0, 500.0)
  clay "mf.r4", row(width = grow(), height = fit(), gap = 28,
                    padding = padAll(t.metrics.padMinor), alignY = centerY):
    draft.admin = switch(adminId, "Administrator", draft.admin)
    draft.remote = switch(remoteId, "Remote", draft.remote)
    spacer()
    caption("Weekly cost: " & money(draft.rate * float(draft.hours)))

  group("ABOUT")
  Labeled(label = "Bio"):
    draft.bio = multilineField(bioId, draft.bio,
                               "A few lines for the team page...",
                               rows = 3, maxLines = 6)
  clay "mf.r5", col(width = grow(), height = fit(), gap = 6,
                    padding = padAll(t.metrics.padMinor)):
    draft.welcome = checkbox(welcomeId, "Send a welcome email", draft.welcome)
    agreed = checkbox(agreeId, "I've checked this person's details with them",
                      agreed)
    fieldError(agreeError())

proc footer() =
  clay "mf.foot", row(width = grow(), height = fit(), gap = 10,
                      alignY = centerY):
    if textLink(resetId, "Reset form"):
      resetForm()
    spacer()
    if tried and not valid():
      text("Fix the errors above", activeTheme.text.caption, errColor)
    let fs = activeTheme.text.control
    if button(cancelId, "Cancel", width = fixedPx(110), height = fixedPx(38),
              fontSize = fs):
      dismiss()
    if button(submitId, "Add member", width = fixedPx(130),
              height = fixedPx(38), fontSize = fs):
      submit()

proc draw*() =
  ## The modal overlay. Declare it last so its floating boxes land on top
  ## of the page (zIndex 30000: over scrollbars and menus, under the
  ## dropdowns and carets that float out of its own fields).
  if not showing:
    return
  let t = activeTheme
  let backId = elementId("mf.back")
  let panelId = elementId("mf.panel")
  openElement(backId)
  configureOpenElement(row(width = grow(), height = grow(),
      padding = padAll(24), alignX = centerX, alignY = centerY)
    .bg(rgb(0, 0, 0, 110))
    .floating(attachRoot, zIndex = 30000,
              points = AttachPoints(element: pointLeftTop,
                                    parent: pointLeftTop)))
  if clickedIn(backId) and not pointerOver(panelId):
    dismiss()
  openElement(panelId)
  configureOpenElement(col(width = grow(max = 680), height = fit(max = 680),
      gap = t.metrics.gapCard, padding = padAll(18))
    .bg(panelBg)
    .border(hairline, panelBorder)
    .corner(panelRadius))
  heading("Add team member", 3)
  caption("Everything below is a draft until you press Add member.")
  # the right gutter keeps the floating scrollbar off the fields
  scrollPanel "mf.body", col(width = grow(), height = grow(),
      gap = t.metrics.gapTight,
      padding = Padding(right: t.scrollbar.width.int + 6))
      .clip(horizontal = false, vertical = true,
            childOffset = currentScrollOffset()):
    formBody()
  footer()
  closeElement()   # panel
  closeElement()   # backdrop
  if fresh:
    fresh = false
    focusAt(nameId, draft.name, draft.name.len)
