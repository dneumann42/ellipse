## The gallery's modal form: "Add team member", one dialog holding most of
## the input widget set at once -- text, multiline, combos, a multiselect,
## number fields, switches and checkboxes -- with validation and a
## draft/commit round trip.
##
## It is a `formDialog` -- the definition macro over the `ellipse_ui/dialogs`
## forms helpers: `beginForm` and the record round trip (`fieldsOf`/
## `fillFrom`), the Enter rule, the `validate:` list behind `valid`/`submit`,
## and `fieldId` namespaced widgets. The macro adds those; what is written
## here is the form proper.
##
## It opens either over the gallery or in a window of its own (a child
## process): `begin(mode)`. The form edits `draft`, a private copy seeded
## from the opener's record on the dialog's first frame; nothing the
## gallery shows changes until Submit validates it. The accepted draft
## travels back as `Fields` -- across the process boundary in window mode
## -- and is appended to `members`. Cancel, Escape or a click on the
## backdrop throw the draft away. Errors stay hidden until the first
## submit attempt, then track every edit live. The title and footer stay
## put; the form between them scrolls when the window is too short for it.

import std/strutils

import ellipse_ui

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

  agreed = false       ## the "checked with them" box: not part of the record
  draft: Member

  roleNames*: seq[string] = @[]
  teamNames*: seq[string] = @[]
  accessNames: seq[string] = @[]

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

## --- verbs -------------------------------------------------------------------------

proc resetForm() =
  draft = blank()
  agreed = false
  formTried = false

## --- drawing -------------------------------------------------------------------------

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
      draft.name = textField(fieldId("name"), draft.name, "Grace Hopper")
      fieldError(nameError())
    Labeled(label = "Email"):
      draft.email = textField(fieldId("email"), draft.email,
                              "grace@example.com")
      fieldError(emailError())
  clay "mf.r2", row(width = grow(), height = fit(), gap = 12, alignY = top):
    Labeled(label = "Role"):
      draft.role = comboBox(fieldId("role"), roleNames, draft.role,
                            "Pick a role")
    Labeled(label = "Team"):
      draft.team = comboBox(fieldId("team"), teamNames, draft.team,
                            "Choose a team")
      fieldError(teamError())

  group("ACCESS & SCHEDULE")
  clay "mf.r3", row(width = grow(), height = fit(), gap = 12, alignY = top):
    Labeled(label = "Access areas"):
      draft.access = multiSelect(fieldId("access"), accessNames, draft.access,
                                 "No access")
      fieldError(accessError())
    Labeled(label = "Hours / week"):
      draft.hours = intNumberField(fieldId("hours"), draft.hours, 1, 1, 60)
      fieldError(hoursError())
    Labeled(label = "Hourly rate"):
      draft.rate = numberField(fieldId("rate"), draft.rate, 5.0, 0.0, 500.0)
  clay "mf.r4", row(width = grow(), height = fit(), gap = 28,
                    padding = padAll(t.metrics.padMinor), alignY = centerY):
    draft.admin = switch(fieldId("admin"), "Administrator", draft.admin)
    draft.remote = switch(fieldId("remote"), "Remote", draft.remote)
    spacer()
    caption("Weekly cost: " & money(draft.rate * float(draft.hours)))

  group("ABOUT")
  Labeled(label = "Bio"):
    draft.bio = multilineField(fieldId("bio"), draft.bio,
                               "A few lines for the team page...",
                               rows = 3, maxLines = 6)
  clay "mf.r5", col(width = grow(), height = fit(), gap = 6,
                    padding = padAll(t.metrics.padMinor)):
    draft.welcome = checkbox(fieldId("welcome"), "Send a welcome email",
                             draft.welcome)
    agreed = checkbox(fieldId("agree"),
                      "I've checked this person's details with them", agreed)
    fieldError(agreeError())

formDialog memberDialog("gallery.member",
                        title = "Add team member", width = 680,
                        maxHeight = 680, scroll = true,
                        header = DialogHeader(enabled: true, fullscreen: true),
                        answer = "add", enter = "bio"):
  if dialogOpened():
    agreed = false
    focusField("name", draft.name)
  caption("Everything below is a draft until you press Add member.")
  formBody()
  footer:
    if formLink("Reset form", "reset"):
      resetForm()
    spacer()
    if formTried and not valid():
      errorText("Fix the errors above")
    if formButton("Cancel", "cancel"):
      cancel()
    if formButton("Add member", "submit", width = 130.0'f32):
      submit()
  validate:
    nameError()
    emailError()
    teamError()
    accessError()
    hoursError()
    agreeError()

proc begin*(mode = dmInline) =
  ## Open the form -- over the gallery, or in a window of its own.
  memberDialog.open(args = formArgs(blank()), mode = mode,
    onDone = proc (r: DialogResult) {.closure.} =
      if r.accepted:
        members.add blank().withFields(r.fields))
