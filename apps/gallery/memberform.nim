## The gallery's modal form: "Add team member", one dialog holding most of
## the input widget set at once -- text, multiline, combos, a multiselect,
## number fields, switches and checkboxes -- with validation and a
## draft/commit round trip.
##
## It is an `ellipse_ui/dialogs` dialog, so it opens either over the
## gallery or in a window of its own (a child process): `begin(mode)`.
## The form edits `draft`, a private copy seeded on the dialog's first
## frame; nothing the gallery shows changes until Submit validates it.
## The accepted draft travels back as `Fields` (`toFields`/`fromFields`)
## -- across the process boundary in window mode -- and is appended to
## `members`. Cancel, Escape or a click on the backdrop throw the draft
## away. Errors stay hidden until the first submit attempt, then track
## every edit live. The title and footer stay put; the form between them
## scrolls when the window is too short for it.

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

proc fillLists*() =
  ## The choice lists. Run from the app's `prepare`: a dialog process
  ## needs them too.
  if roleNames.len > 0:
    return
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

proc toFields(m: Member): Fields =
  result = Fields()
  result.put("name", m.name)
  result.put("email", m.email)
  result.put("bio", m.bio)
  result.put("role", m.role)
  result.put("team", m.team)
  result.put("access", int(m.access))
  result.put("hours", m.hours)
  result.put("rate", m.rate)
  result.put("admin", m.admin)
  result.put("remote", m.remote)
  result.put("welcome", m.welcome)

proc fromFields(f: Fields): Member =
  Member(name: f.get("name"), email: f.get("email"), bio: f.get("bio"),
         role: f.getInt("role"), team: f.getInt("team", -1),
         access: Selection(f.getInt("access")), hours: f.getInt("hours"),
         rate: f.getFloat("rate"), admin: f.getBool("admin"),
         remote: f.getBool("remote"), welcome: f.getBool("welcome"))

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

proc submit() =
  tried = true
  if valid():
    accept(toFields(draft), "add")

proc resetForm() =
  draft = blank()
  agreed = false
  tried = false

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

proc body() {.raises.} =
  if dialogOpened():
    draft = blank()
    agreed = false
    tried = false
    focusAt(nameId, draft.name, draft.name.len)
  # Enter submits -- except in the bio, where it breaks the line
  if focusIdOf() == bioId.id:
    passEnter()
  if dialogEnter():
    submit()
  caption("Everything below is a draft until you press Add member.")
  formBody()

proc footer() {.raises.} =
  if textLink(resetId, "Reset form"):
    resetForm()
  spacer()
  if tried and not valid():
    text("Fix the errors above", activeTheme.text.caption, errColor)
  let fs = activeTheme.text.control
  if button(cancelId, "Cancel", width = fixedPx(110), height = fixedPx(38),
            fontSize = fs):
    cancel()
  if button(submitId, "Add member", width = fixedPx(130),
            height = fixedPx(38), fontSize = fs):
    submit()

let memberDialog = defineDialog("gallery.member", DialogSpec(
  title: "Add team member", width: 680, maxHeight: 680, scroll: true,
  header: DialogHeader(enabled: true, fullscreen: true),
  body: body, footer: footer))

proc begin*(mode = dmInline) =
  ## Open the form -- over the gallery, or in a window of its own.
  memberDialog.open(mode = mode,
    onDone = proc (r: DialogResult) {.closure.} =
      if r.accepted:
        members.add fromFields(r.fields))
