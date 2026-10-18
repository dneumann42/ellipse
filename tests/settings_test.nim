import std/[os, syncio, strutils, unittest]
import owl/settings
import ./testutils

captureStdio()

# A settings file is an owl file whose value is the data. `add` registers a
# type against a path, writing defaults when the file is not there yet, and
# `get` hands back the stored value. A hot repository watches its files:
# the file is the source of truth, and a reload replaces the data to match
# it. Files run in a restricted sandbox: arithmetic, strings, lists and the
# files' own definitions, and nothing with hands.

type
  Theme = object
    dark*: bool
    accent*: string
    size*: int
  App = object
    title*: string
    width*: int
    theme*: Theme
    recent*: seq[string]

const dir = "build/settings-test"
removeDir(dir)
createDir(dir)

template failed(needle: string, body: untyped) =
  ## A registration that must not land. `body` is a statement form, since the
  ## borrow a successful one hands back has to be used or discarded.
  var message = ""
  try:
    body
  except ValueError as e:
    message = e.msg
  check message.len > 0, "the file was refused"
  check needle in message, "\"" & needle & "\" in the error: " & message

suite "owl/settings":
  test "add writes the missing file with defaults":
    var repo = newSettings()
    discard repo.add(dir / "app.owl", App)
    check fileExists(dir / "app.owl"), "the absent file is written"
    let text = readFile(dir / "app.owl")
    check text.startsWith("; App -- owl settings\n"), "the file says what it holds"
    check "title = \"\"" in text and "width = 0" in text, "defaults land in the file"
    check not fileExists(dir / "app.owl.owl-tmp"), "the write leaves no step behind"
    repo.close()

  test "get borrows the stored data and save writes it back":
    var repo = newSettings()
    discard repo.add(dir / "app.owl", App)
    repo.get(App).title = "ellipse"
    repo.get(App).width = 1024
    repo.get(App).theme.accent = "#e8b339"
    repo.get(App).recent = @["a.owl", "b.owl"]
    repo.save(App)
    let text = readFile(dir / "app.owl")
    check "title = \"ellipse\"" in text and "width = 1024" in text,
      "the save reached the file"
    check "accent = \"#e8b339\"" in text and "a.owl" in text,
      "nested records and lists reached it too"
    var fresh = newSettings()
    discard fresh.add(dir / "app.owl", App)
    check fresh.get(App).title == "ellipse" and fresh.get(App).width == 1024,
      "another repository reads the same file back"
    check fresh.get(App).theme.accent == "#e8b339" and fresh.get(App).recent.len == 2,
      "the whole shape comes back"
    repo.close()
    fresh.close()

  test "a settings file runs its own definitions":
    writeFile(dir / "expr.owl", """
fun scale x pct:
    / (* x pct) 100

{}:
    dark = true
    accent = "#151219"
    size = scale 1024 75
""")
    var repo = newSettings()
    discard repo.add(dir / "expr.owl", Theme, "expr-theme")
    check repo.get(Theme, "expr-theme").size == 768, "the record computed itself"
    check repo.get(Theme, "expr-theme").dark, "a bare boolean reads as true"
    repo.close()

  test "the file is the source of truth":
    var repo = newSettings(hot = true)
    discard repo.add(dir / "hot.owl", App)
    check repo.descriptor() > -1, "a hot repository has a descriptor to wait on"
    repo.get(App).title = "in memory"
    repo.save(App)
    writeFile(dir / "hot.owl", """{}:
    title = "changed by hand"
    width = 640
    theme = {} (dark = false) (accent = "#fff") (size = 12)
    recent = ([])
""")
    check repo.checkForChanges() == 1, "the changed file reloads"
    check repo.get(App).title == "changed by hand" and repo.get(App).width == 640,
      "the data now matches the file"
    writeFile(dir / "hot.owl", "{} (width = \"wide\")")
    clearCaptured()
    check repo.checkForChanges() == 0, "a file that stopped reading reloads none"
    check repo.get(App).title == "changed by hand", "the old data keeps serving"
    check "width" in repo.errorOf("App"), "the reason is where it belongs"
    check errorLines.len() > 0, "the report reached the screen"
    repo.close()
    check repo.descriptor() == -1, "close gives the watching up"

  test "a quiet repository keeps its failures to itself":
    var repo = newSettings(hot = true, quiet = true)
    discard repo.add(dir / "quiet.owl", App)
    writeFile(dir / "quiet.owl", "{} (width = \"wide\")")
    clearCaptured()
    check repo.checkForChanges() == 0, "the file was still refused"
    check repo.errorOf("App").len > 0, "still on record"
    check errorLines.len() == 0, "quiet prints nothing"
    repo.close()

  test "hotReload starts and stops watching":
    var repo = newSettings()
    discard repo.add(dir / "late.owl", App)
    check repo.descriptor() == -1, "a plain repository watches nothing"
    repo.hotReload()
    check repo.descriptor() > -1, "watching started"
    writeFile(dir / "late.owl", "{} (title = \"late\")")
    check repo.checkForChanges() == 1, "and changes reload"
    check repo.get(App).title == "late"
    repo.hotReload(false)
    check repo.descriptor() == -1, "and stopped"
    discard repo.add(dir / "later.owl", App, "later-app")
    check repo.descriptor() == -1, "files added after the stop watch nothing"
    repo.close()

  test "a settings file cannot reach the machine":
    var repo = newSettings()
    writeFile(dir / "fs.owl", "use fs\n{}")
    failed "cannot use module fs":
      discard repo.add(dir / "fs.owl", Theme, "fs")
    writeFile(dir / "net.owl", "use net\n{}")
    failed "cannot use module net":
      discard repo.add(dir / "net.owl", Theme, "net")
    writeFile(dir / "read.owl", "{} (size = read-file \"/etc/hostname\")")
    failed "read-file":
      discard repo.add(dir / "read.owl", Theme, "read")
    writeFile(dir / "shell.owl", "{} (accent = run \"echo out\")")
    failed "run":
      discard repo.add(dir / "shell.owl", Theme, "shell")
    check repo.errorOf("fs").len > 0, "the refusal is on record"
    check repo.get(Theme, "read").size == 0, "and the data holds the defaults"
    repo.close()

  test "a wrong value and a misspelled name are both refused":
    var repo = newSettings()
    writeFile(dir / "bad.owl", """{}:
    title = "x"
    width = "wide"
""")
    failed "width":
      discard repo.add(dir / "bad.owl", App, "bad")
    check repo.get(App, "bad").width == 0, "the defaults stay in place"
    check "width" in repo.errorOf("bad"), "and the reason is kept"
    writeFile(dir / "typo.owl", "{} (titel = \"x\")")
    failed "titel":
      discard repo.add(dir / "typo.owl", App, "typo")
    repo.close()

  test "the registry keeps one file per name":
    var repo = newSettings()
    discard repo.add(dir / "reg.owl", Theme, "first")
    check repo.has(Theme, "first"), "it knows the name"
    check repo.count() == 1 and repo.names() == @["first"], "and how many there are"
    check repo.pathOf("first") == dir / "reg.owl", "pathOf gives the file back"
    failed "already registered":
      discard repo.add(dir / "other.owl", Theme, "first")
    repo.add(dir / "reg.owl", Theme, "first").dark = true
    check repo.get(Theme, "first").dark,
      "the same name and path hand back the data, not a reload"
    discard repo.add(dir / "mis.owl", Theme, "mis")
    failed "not a App":
      discard repo.get(App, "mis")
    repo.remove("first")
    check not repo.has(Theme, "first"), "remove forgets the name"
    check fileExists(dir / "reg.owl"), "but leaves the file"
    failed "nothing registered":
      discard repo.get(Theme)
    repo.close()

  test "reloadAll and saveAll reach every file":
    var repo = newSettings()
    discard repo.add(dir / "one.owl", Theme, "one")
    repo.get(Theme, "one").size = 11
    writeFile(dir / "two.owl", "{} (size = 5)")
    discard repo.add(dir / "two.owl", Theme, "two")
    repo.saveAll()
    var fresh = newSettings()
    check fresh.add(dir / "one.owl", Theme, "one").size == 11, "saveAll wrote every file"
    writeFile(dir / "one.owl", "{} (size = 1)")
    writeFile(dir / "two.owl", "{} (size = 2)")
    check repo.reloadAll() == 2, "reloadAll takes them all"
    check repo.get(Theme, "one").size == 1 and repo.get(Theme, "two").size == 2,
      "and the data says what the files say now"
    repo.close()
    fresh.close()

  test "shared modules come from a module path":
    createDir(dir / "shared")
    writeFile(dir / "shared" / "twice.owl",
      "use base\nuse math\nfun twice x:\n    (* x 2)\n\nexport:\n    twice = twice\n")
    writeFile(dir / "uses.owl", "use twice\n{} (size = twice 21)")
    var repo = newSettings()
    repo.addModulePath(dir / "shared")
    discard repo.add(dir / "uses.owl", Theme, "uses")
    check repo.get(Theme, "uses").size == 42, "a module off the path runs in the sandbox"
    writeFile(dir / "still.owl", "use twice\n{} (accent = read-file \"/etc/hostname\")")
    failed "read-file":
      discard repo.add(dir / "still.owl", Theme, "still")
    repo.close()

  test "a plain SettingsRepository prepares itself":
    var repo: SettingsRepository
    check repo.add(dir / "zero.owl", Theme).dark == false, "add works on a fresh record"
    check repo.get(Theme).size == 0 and fileExists(dir / "zero.owl"),
      "and the file it wrote"
