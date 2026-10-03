import std/hashes

type
  SymbolId* = distinct uint64

  SymbolKind* = enum
    skInvalid
    skExternal
    skSlack
    skError
    skDummy

  Symbol* = object
    kind*: SymbolKind
    id*: SymbolId

func `==`*(a, b: SymbolId): bool {.borrow.}
func `<`*(a, b: SymbolId): bool {.borrow.}
func `$`*(id: SymbolId): string {.borrow.}

func hash*(id: SymbolId): Hash {.inline.} =
  cast[Hash](uint64(id))

func initSymbol*(
    kind: SymbolKind = skInvalid, id: SymbolId = SymbolId(0u)
): Symbol {.inline.} =
  Symbol(kind: kind, id: id)

func isInvalid*(symbol: Symbol): bool {.inline.} =
  symbol.kind == skInvalid

func isExternal*(symbol: Symbol): bool {.inline.} =
  symbol.kind == skExternal

func isRestricted*(symbol: Symbol): bool {.inline.} =
  symbol.kind in {skSlack, skError, skDummy}

func isDummy*(symbol: Symbol): bool {.inline.} =
  symbol.kind == skDummy

func isPivotable*(symbol: Symbol): bool {.inline.} =
  symbol.kind in {skSlack, skError}

func `==`*(a, b: Symbol): bool {.inline.} =
  a.id == b.id


func `<`*(a, b: Symbol): bool {.inline.} =
  a.id < b.id

func hash*(symbol: Symbol): Hash {.inline.} =
  hash(symbol.id)

func `$`*(symbol: Symbol): string =
  let prefix =
    case symbol.kind
    of skInvalid: "i"
    of skExternal: "v"
    of skSlack: "s"
    of skError: "e"
    of skDummy: "d"
  prefix & $symbol.id
