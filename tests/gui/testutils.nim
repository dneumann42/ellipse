## Minimal test helpers for the GUI tests (ported from the nimony kit's
## `tests/testutils.nim`, minus the owl plumbing: the GUI tests only need
## counting assertions and a final report).

var failures = 0
var passed = 0

proc expect*(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

proc finish*(name: string) =
  if failures == 0:
    echo name & " tests OK (" & $passed & " assertions)"
  else:
    quit name & " tests failed: " & $failures & " of " & $(passed + failures)
