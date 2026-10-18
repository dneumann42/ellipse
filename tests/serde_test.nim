import std/[tables, options, strutils, math, typetraits, unittest]
import owl/[objects, reader, evaluator, serde]
import owl/libraries/[base, math]
import ./testutils

captureStdio()

# serde turns values into owl data. The data is text once `toCode` prints it,
# and a value again once source is read and run: these two helpers close the
# circle so a round trip goes the whole way around, through a file's worth of
# source and back.

proc evalText(source: string): Object =
  let env = newEnvironment()
  installBase(env)
  installMath(env)
  evalForms(env, readForms(source, "<test>").get(@[]))

proc code(x: auto): string =
  owlText(x, 80)

proc decodeText[T](source: string, t: typedesc[T]): T =
  decode(evalText(source), t)

proc readBack[T](x: T): T =
  decodeText[T](code(x), T)

template failed(body: untyped, needle: string) =
  ## `body` is a conversion that must not land: a statement form, since a
  ## value it hands back would have to be used.
  var message = ""
  try:
    body
  except ValueError as e:
    message = e.msg
  check message.len > 0, "the conversion failed"
  check needle in message, "\"" & needle & "\" in the error: " & message

type
  Colour = enum
    red
    green
    blue = "azure"
  Count = distinct int
  Name = distinct string
  Inner = object
    w: int
    h: int
  Outer = object
    name: string
    inner: Inner
  Tagged = object
    case flagged: bool
    of true: note*: string
    of false: code*: int
  Custom = object
    secs: int
  Shaped = object
    keep*: int
    drop*: int
    under*: string
  Nested = object
    list: seq[Inner]
    table: Table[string, Inner]
    deep: seq[seq[int]]
  Mode = enum fast, slow
  Setting = object
    at*: int
    case mode*: Mode
    of fast: rate*: int
    of slow: pause*: int
  Carrier = object
    name*: string
    setting*: Setting

proc asOwl(c: Custom): Object =
  str($(c.secs))

proc asNim(o: Object, c: var Custom) =
  c.secs = wantNumber(o).int

proc ignoreField(s: Shaped, name: string): bool = name == "drop"
proc fieldName(s: Shaped, name: string): string =
  if name == "under": "held" else: name

template atoms() =
  check code(7) == "7", "an int is a number"
  check code(-12) == "-12", "a negative int"
  check code(1.5) == "1.5", "a float keeps its fraction"
  check code(2.0) == "2", "a whole float is written whole"
  check code(true) == "true", "a bool"
  check code(false) == "false", "and its opposite"
  check code('k') == "\"k\"", "a char is a quoted string"
  check code("a b") == "\"a b\"", "a string is quoted"
  check code("") == "\"\"", "even an empty one"
  check code(NaN) == "\"nan\"", "nan is written as text it can be read from"
  var lost: float
  decode(evalText("\"nan\""), lost)
  check lost != lost, "and reads back as nan"
  check readBack(1.0e20) == 1.0e20, "a float too big for the reader's spelling"
  check code(high(int64)) == "\"9223372036854775807\"",
    "a count past a float's keeping is written in full"
  check readBack(high(int64)) == high(int64), "and reads back exactly"
  check readBack(low(int64)) == low(int64), "including the negative end"
  check readBack(2_147_483_648'i64) == 2_147_483_648'i64, "past int32"
  check readBack(7'u8) == 7'u8, "an unsigned byte"
  check code(green) == "\"green\"", "an enum is its name, quoted"
  check code(blue) == "\"azure\"", "an enum with a written value uses it"
  check decodeText("\"azure\"", Colour) == blue, "an enum reads back by its value"
  var wrong: Colour
  failed(decode(evalText("\"violet\""), wrong), "is not a Colour")
  var b: bool
  decode(evalText("\"yes\""), b)
  check b, "a yes reads as true"
  decode(evalText("\"no\""), b)
  check not b, "a no reads as false"
  failed(decode(evalText("\"maybe\""), b), "expected a boolean")
  check code(12.Count) == "12", "a distinct number writes as its base"
  check string(readBack(Name("a b"))) == "a b", "a distinct string"
  var wide: float
  decode(evalText("\"1.25\""), wide)
  check wide == 1.25, "a number typed as a string still reads"
  var small: int8
  failed(decode(evalText("300"), small), "does not fit in int8")

template containers() =
  check code(@[1, 2, 3]) == "[] 1 2 3", "a sequence is a list"
  check code(@["a", "b"]) == "[] \"a\" \"b\"", "a sequence of strings"
  check code(newSeq[int]()) == "([])", "an empty sequence stays a list"
  check code([1, 2, 3]) == "[] 1 2 3", "an array is a list"
  check code(@[red, blue]) == "[] \"red\" \"azure\"", "a list of enums, quoted"
  check code({red, blue}) == "[] \"red\" \"azure\"", "a set is a list of members"
  check readBack(@[Inner(w: 1, h: 2)])[0].h == 2, "a sequence of records"
  var s: set[Colour] = {}
  decode(evalText("[] \"red\" \"azure\""), s)
  check s == {red, blue}, "a set reads back"
  var pair: (int, string)
  decode(evalText("[] 4 \"four\""), pair)
  check pair[0] == 4 and pair[1] == "four", "an unnamed tuple fills in order"
  check code((x: 1, y: 2)) == "{} (x = 1) (y = 2)", "a named tuple is a record"
  var tup: tuple[x: int, y: int]
  decode(evalText("{} (x = 3) (y = 4)"), tup)
  check tup.x == 3 and tup.y == 4, "and reads back"
  var arr: array[2, int]
  failed(decode(evalText("[] 1 2 3"), arr), "expected 2 items, got 3")
  failed(decode(evalText("[] 1"), arr), "expected 2 items, got 1")
  var notAList: array[2, int]
  failed(decode(evalText("\"one\""), notAList), "an array needs a list")
  check readBack(@[@[1, 2], @[3]]) == @[@[1, 2], @[3]], "a list of lists"
  check readBack(@["1", "two"]) == @["1", "two"], "a list of strings"
  var texts: seq[string]
  decode(evalText("[] 1 \"two\""), texts)
  check texts == @["1", "two"], "a number reads as text it spells"
  failed(decode(evalText("[] ({})"), texts), "0: expected a string, got a record")

template optionsAndRefs() =
  check code(some(3)) == "3", "an option is its value"
  check code(int.none) == "nothing", "or nothing"
  var o: Option[int]
  decode(evalText("nothing"), o)
  check o.isNone, "nothing reads as none"
  decode(evalText("5"), o)
  check o.get() == 5, "a value reads as some"
  var nested: Option[seq[int]]
  decode(evalText("[] 1"), nested)
  check nested.isSome and nested.get() == @[1], "an option of a sequence"
  var r: ref Inner
  check code(r) == "nothing", "a nil ref is nothing"
  var back: ref Inner
  decode(evalText("nothing"), back)
  check back == nil, "nothing reads back as nil"
  decode(evalText("{} (w = 2) (h = 3)"), back)
  check back != nil and back.h == 3, "a record reads into a fresh ref"

template tables() =
  let byName = {"one": 1, "two": 2}.toTable
  check code(byName) == "{} (one = 1) (two = 2)", "a table of names is a record"
  check readBack({"one": 1, "two": 2}.toTable) == {"two": 2, "one": 1}.toTable,
    "and reads back"
  let byNumber = {7: "seven"}.toTable
  check code(byNumber) == "[] ([] 7 \"seven\")",
    "a table keyed by numbers is a list of pairs"
  check readBack({7: "seven"}.toTable)[7] == "seven", "and reads back"
  check code({"a b": 1}.toTable) == "[] ([] \"a b\" 1)",
    "a key that is not a name goes into a pair"
  check readBack({"a b": 1}.toTable)["a b"] == 1, "and reads back"
  var fromRecord: Table[string, int]
  decode(evalText("{} (wide = 3)"), fromRecord)
  check fromRecord["wide"] == 3, "a record of names reads into a table"
  var ordered: OrderedTable[string, int]
  decode(evalText("{} (a = 1) (b = 2)"), ordered)
  check ordered.len == 2 and ordered["b"] == 2, "an ordered table too"
  check readBack({red: 1}.toTable)[red] == 1, "a table keyed by an enum"
  var byEnum: Table[Colour, int]
  decode(evalText("{} (azure = 4)"), byEnum)
  check byEnum[blue] == 4, "keys read from names"
  var wrong: Table[string, int]
  failed(decode(evalText("[] 1"), wrong), "a table item needs [key value]")
  try:
    discard evalText("{} (a)")
  except ValueError as e:
    check "needs (name = value)" in e.msg, "a bare name is no field: " & e.msg

template records() =
  let v = Outer(name: "top", inner: Inner(w: 1, h: 2))
  check code(v) == "{} (name = \"top\") (inner = {} (w = 1) (h = 2))",
    "an object is a record of its fields"
  check readBack(v) == v, "and reads back whole"
  let written = decodeText("""
{}:
    name = "top"
    inner = {}:
        w = 10
        h = 20
""", Outer)
  check written.inner.w == 10 and written.name == "top", "a nested record in block form"
  var kept = Outer(name: "keep", inner: Inner(w: 7, h: 7))
  decode(evalText("{} (name = \"other\")"), kept)
  check kept.name == "other" and kept.inner.w == 7,
    "a field the file leaves out keeps what it had"
  var fresh: Outer
  decode(evalText("()"), fresh)
  check fresh.name == "", "a file holding nothing leaves the defaults"
  var wrongShape: Outer
  failed(decode(evalText("[] 1 2"), wrongShape), "needs a record")
  var deep: Nested
  decode(evalText("""
{}:
    list = [] ({} (w = 1) (h = 2))
    table = {} (main = {} (w = 3) (h = 4))
    deep = [] ([] 1 2)
"""), deep)
  check deep.list[0].w == 1 and deep.table["main"].h == 4 and deep.deep == @[@[1, 2]],
    "records, tables and lists nested together"
  check readBack(deep).deep == @[@[1, 2]], "and the whole shape writes and reads"

template variants() =
  check code(Tagged(flagged: true, note: "hello")) ==
    "{} (flagged = true) (note = \"hello\")", "only the active branch is written"
  var off = Tagged(flagged: true, note: "left over")
  decode(evalText("{} (flagged = false) (code = 3)"), off)
  check off.flagged == false and off.code == 3,
    "the discriminator decides which branch reads"
  check readBack(Tagged(flagged: true, note: "n")).note == "n", "the other branch too"
  var stale: Tagged
  failed(decode(evalText("{} (flagged = false) (code = 1) (note = \"x\")"), stale),
    "\"note\" is not a field of Tagged")
  # a file that asks for another branch: the value is rebuilt, because a
  # discriminant will not cross from one branch to the other by assignment
  var s = Setting(at: 3, mode: fast, rate: 60)
  decode(evalText("{} (mode = \"slow\") (pause = 9)"), s)
  check s.mode == slow and s.pause == 9, "the branch the file asks for is built"
  check s.at == 3, "the fields both branches share carry across the switch"
  check code(s) == "{} (at = 3) (mode = \"slow\") (pause = 9)",
    "and only the new branch is written"
  decode(evalText("{} (mode = \"fast\") (rate = 1)"), s)
  check s.mode == fast and s.rate == 1 and s.at == 3, "and switching back works"
  var deep = Carrier(name: "n", setting: Setting(at: 5, mode: fast, rate: 1))
  decode(evalText("{} (setting = {} (mode = \"slow\") (pause = 2))"), deep)
  check deep.setting.mode == slow and deep.setting.pause == 2 and
      deep.setting.at == 5 and deep.name == "n",
    "a nested variant switches branch while its own fields keep"
  check readBack(deep).setting.pause == 2, "the nested shape round trips too"

template hooks() =
  check code(Custom(secs: 30)) == "\"30\"", "asOwl shapes the value"
  check decodeText("\"30\"", Custom).secs == 30, "asNim reads it back"
  let shaped = Shaped(keep: 1, drop: 2, under: "x")
  check code(shaped) == "{} (keep = 1) (held = \"x\")",
    "ignoreField drops a field, fieldName renames one"
  var read: Shaped
  decode(evalText("{} (keep = 4) (held = \"y\")"), read)
  check read.keep == 4 and read.under == "y" and read.drop == 0,
    "and both read back"
  failed(decode(evalText("{} (keep = 4) (drop = 1) (held = \"y\")"), read),
    "\"drop\" is not a field of Shaped")

template errors() =
  var n: int
  failed(decode(evalText("\"text\""), n), "expected a number, got the string \"text\"")
  var o = Outer(name: "x", inner: Inner(w: 1, h: 2))
  failed(decode(evalText("""
{}:
    name = "x"
    inner = {}:
        w = "wide"
        h = 2
"""), o), "inner/w: expected a number")
  var rec = Outer()
  failed(decode(evalText("{} (name = \"x\") (inner = {} (w = 1) (h = 2)) (extra = 3)"),
    rec), "\"extra\" is not a field of Outer")
  var c: Custom
  failed(decode(evalText("({})"), c), "expected a number, got a record")

template shapes() =
  let text = owlText(Outer(name: "top", inner: Inner(w: 800, h: 600)), 40)
  check text.startsWith("{}:"), "a wide value is written as a block"
  check "    name = \"top\"" in text, "one field to a line"
  check decodeText(text, Outer).inner.h == 600, "and reads back from its own text"
  check name(Outer) == "Outer", "a type is named for errors and files"

suite "owl/serde":
  test "atoms": atoms()
  test "containers": containers()
  test "options and refs": optionsAndRefs()
  test "tables": tables()
  test "records": records()
  test "variants": variants()
  test "hooks": hooks()
  test "errors": errors()
  test "text shapes": shapes()
