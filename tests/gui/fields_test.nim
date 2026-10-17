## Tests for `ellipse_ui/dialogs/fields`: the typed bag a dialog takes and
## returns, and its wire form -- the line that carries a request to a
## dialog process and its result back.

import std/syncio

import ellipse_ui/dialogs/fields

var failures = 0
var passed = 0

proc expect(cond: bool, msg: string) =
  if cond:
    passed += 1
  else:
    failures += 1
    echo "FAILED: ", msg

proc main() =
  var f = Fields()
  f.put("name", "Grace Hopper")
  f.put("hours", 40)
  f.put("rate", 85.5)
  f.put("remote", true)
  f.put("admin", false)
  expect(f.len == 5, "five keys")
  expect(f.get("name") == "Grace Hopper", "string back")
  expect(f.getInt("hours") == 40, "int back")
  expect(f.getFloat("rate") == 85.5, "float back")
  expect(f.getBool("remote"), "bool true back")
  expect(not f.getBool("admin", true), "bool false back")
  expect(f.get("missing", "dflt") == "dflt", "missing string default")
  expect(f.getInt("name", 7) == 7, "unparsable int falls back")
  expect(f.getFloat("name", 1.5) == 1.5, "unparsable float falls back")

  f.put("hours", 32)
  expect(f.len == 5 and f.getInt("hours") == 32, "put replaces in place")
  expect(f.keyAt(1) == "hours", "order kept on replace")

  let line = encode(f)
  expect(line.find(' ') < 0 and line.find('\n') < 0, "wire form has no spaces/newlines")
  expect(decode(line) == f, "round trip")

  var odd = Fields()
  odd.put("a=b&c", "x%y\nz & \"q\" ü \t")
  odd.put("", "empty key")
  odd.put("empty", "")
  expect(decode(encode(odd)) == odd, "round trip of awkward bytes")

  var l = Fields()
  l.putList("items", ["one", "two, three", "", "four&five"])
  let items = decode(encode(l)).getList("items")
  expect(items.len == 4, "list length")
  expect(items.len == 4 and items[1] == "two, three" and items[2] == "" and
         items[3] == "four&five", "list items intact")
  expect(Fields().getList("none").len == 0, "missing list is empty")

  var outer = Fields()
  outer.put("name", "ellipse.message")
  outer.putFields("args", f)
  let back = decode(encode(outer))
  expect(back.getFields("args") == f, "nested bag survives")

  let lit = fields({"title": "Hi", "body": "there"})
  expect(lit.get("title") == "Hi" and lit.get("body") == "there", "literal pairs")
  expect(decode("") == Fields(), "empty line, empty bag")
  expect(decode("flag&&k=v").get("flag", "x") == "" and
         decode("flag&&k=v").get("k") == "v", "bare key, empty segment")
  expect(decode("bad=%G1%4").get("bad") == "%G1%4", "broken escapes kept")

  echo "fields_test: ", passed, " passed, ", failures, " failed"
  if failures > 0:
    quit 1

when isMainModule:
  main()
