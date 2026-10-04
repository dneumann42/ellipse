import std/[syncio]

var
  rootWidth = 0
  rootHeight = 0

proc setRootSize(w, h: int) =
  rootWidth = w
  rootHeight = h

proc beginLayout*() =
  echo "BEGIN"

proc endLayout*() =
  discard
