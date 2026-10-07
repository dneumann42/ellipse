## Repls attaching to a running owl app, end to end with real processes:
## bin/owl run serves its socket from the frame loop; repls attach, change
## the running program, detach and come back to the state they left; two
## clients at once; a file saved on disk reloads into the running app; stop
## closes it and removes its socket. Headless (SDL offscreen). Needs bin/owl.

import std/[syncio, strutils, os, osproc, envvars]
import ./testutils

var owl = ""
var base = ""
var dir = ""
try:
  owl = absolutePath("bin/owl")
  base = absolutePath("nimcache/owl_attach_test")
  dir = base & "/app"
except:
  quit "cannot resolve paths"

proc sh(cmd: string; input = ""): string =
  result = ""
  try:
    let (output, code) = execCmdEx(cmd, input = input)
    result = output
    discard code
  except:
    expect false, "command ran: " & cmd

proc repl(input: string): string =
  sh("cd " & quoteShell(dir) & " && " & quoteShell(owl) & " repl", input)

proc runtimeDir(): string =
  result = ""
  try:
    result = getEnv("XDG_RUNTIME_DIR")
  except:
    discard
  if result.len == 0:
    result = "/tmp/owl-unknown"
  result.add "/owl"

discard sh("rm -rf " & quoteShell(base) & " && mkdir -p " & quoteShell(base))
discard sh("cd " & quoteShell(base) & " && " & quoteShell(owl) & " new app gui")
expect fileExists(dir & "/src/main.owl") and fileExists(dir & "/src/widgets.owl"),
  "owl new app gui made main and widgets"

# Start the app, detached, the way the repl's run does.
let pidText = sh("(cd " & quoteShell(dir) & " && SDL_VIDEODRIVER=offscreen exec " &
  quoteShell(owl) & " run > " & quoteShell(base & "/app.log") & " 2>&1 < /dev/null) > /dev/null 2>&1 & echo $!").strip()
let sock = runtimeDir() & "/" & pidText & ".sock"
var waited = 0
while not fileExists(sock) and not symlinkExists(sock) and waited < 100:
  discard sh("sleep 0.1")
  inc waited
let listed = repl("apps\n")
expect pidText in listed and "app" in listed, "apps lists the running app:\n" & listed

# Attach, change the running program, detach.
let first = repl("attach " & pidText & "\nclicks\nset clicks 41\nfun double x:\n    * x 2\n\ndouble clicks\ndetach\n")
expect "attached to app" in first, "attached:\n" & first
expect "=> 0" in first and "=> 82" in first, "code ran in the app:\n" & first
expect "detached from app" in first, "detached:\n" & first

# A second session finds the state and the definition the first one left.
let second = repl("attach " & pidText & "\nclicks\ndouble 5\ndocs\nexit\n")
expect "=> 41" in second and "=> 10" in second, "state survives detaching:\n" & second
expect "main" in second and "modified" in second, "the app's main document holds the patch:\n" & second

# Two clients at once: one holds a connection open while another works.
let holder = sh("(cd " & quoteShell(dir) & " && (printf 'attach " & pidText & "\\nclicks\\n'; sleep 2; printf 'clicks\\n') | " &
  quoteShell(owl) & " repl > " & quoteShell(base & "/holder.out") & " 2>&1) > /dev/null 2>&1 & echo started")
discard holder
discard sh("sleep 0.5")
let other = repl("attach " & pidText & "\nset clicks 7\ndetach\n")
expect "=> 7" in other, "a second client works while the first holds on:\n" & other
discard sh("sleep 2.5")
var held = ""
try:
  held = readFile(base & "/holder.out")
except:
  discard
expect "=> 41" in held and "=> 7" in held, "the first client saw the second's change:\n" & held

# A file saved on disk reloads into the running app.
var widgets = ""
try:
  widgets = readFile(dir & "/src/widgets.owl")
  writeFile(dir & "/src/widgets.owl", widgets & "\nfun answer:\n    42\n")
except:
  expect false, "widgets.owl rewritten"
discard sh("sleep 0.5")
let reloaded = repl("attach " & pidText & "\n(answer)\n(frame-error)\nstop\n")
expect "=> 42" in reloaded, "the saved definition is live (main uses widgets):\n" & reloaded
expect "stopped app" in reloaded, "stop closes the app:\n" & reloaded
discard sh("sleep 0.5")
expect not fileExists(sock), "the socket is gone after stop"
let gone = repl("apps\n")
expect pidText notin gone, "apps no longer lists it:\n" & gone
var log = ""
try:
  log = readFile(base & "/app.log")
except:
  discard
expect "reloaded widgets" in log, "the app logged the reload:\n" & log

finish "attach"
