## Solver variable API.

import std/hashes


type
  VariableId* = distinct uint64 ## Stable identity assigned to a variable.

  Variable* = ref object ## Identity-bearing solver variable.
    id: VariableId
    nameValue: string
    currentValue: KiwiScalar

when defined(nimony):
  var nextVariableId = 1'u64

  proc takeVariableId(): VariableId =
    result = VariableId(nextVariableId)
    nextVariableId = nextVariableId + 1'u64
else:
  import std/atomics

  var nextVariableId: Atomic[uint64]
  nextVariableId.store(1)

  proc takeVariableId(): VariableId =
    VariableId(nextVariableId.fetchAdd(1))

func `==`*(a, b: VariableId): bool {.borrow.}
func `<`*(a, b: VariableId): bool {.borrow.}
func hash*(id: VariableId): Hash {.borrow.}
func `$`*(id: VariableId): string {.borrow.}

proc newVariable*(name = ""): Variable =
  ## Creates a new variable with an optional display name.
  Variable(
    id: takeVariableId(), nameValue: name, currentValue: KiwiScalar(0.0)
  )

proc vars*(name: string): Variable =
  ## Creates a new variable from a call-style string literal, e.g. `vars"x"`.
  newVariable(name)

func variableId*(variable: Variable): VariableId {.inline.} =
  ## Returns the identity assigned to `variable`.
  variable.id

func sameVariable*(a, b: Variable): bool {.inline.} =
  ## Returns true when both handles refer to the same variable identity.
  a.id == b.id

func name*(variable: Variable): string =
  ## Returns the variable's display name.
  variable.nameValue

proc `name=`*(variable: Variable, name: string) =
  ## Updates the variable's display name.
  variable.nameValue = name

func value*(variable: Variable): KiwiScalar {.inline.} =
  ## Returns the variable's current solved value.
  variable.currentValue

proc `value=`*(variable: Variable, value: KiwiScalar) {.raises.} =
  ## Updates the variable's current value.
  variable.currentValue = value.requireFinite("variable value")

func setSolverValue*(variable: Variable, value: KiwiScalar) {.inline.} =
  ## Writes a finite value produced by the solver without repeating validation.
  variable.currentValue = value

func hash*(variable: Variable): Hash =
  ## Hashes a variable by identity.
  hash(variable.id)

func `$`*(variable: Variable): string =
  ## Returns the variable's name, or an identity-based fallback.
  if variable.nameValue.len == 0:
    "v" & $variable.id
  else:
    variable.nameValue
