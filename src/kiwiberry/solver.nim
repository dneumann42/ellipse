## Public solver API.
##
## Vendored Nimony port of kiwiberry. Notable adaptations:
##   - `AssocMap`/`CellMap` are walked via the public `entries`/`findIndex`
##     instead of the upstream `withValue` templates and `mpairs` iterators
##     (var-tuple iterators are not expressible yet).
##   - Table lookups on missing keys raise through `getOrQuit` after an
##     explicit `hasKey` guard; internal lookups that already proved
##     presence use `findIndex`.
##   - Most of the API is `{.raises.}`: scalar validation, duplicate/unknown
##     constraint handling, and tableau pivots all raise `ErrorCode` values.
##   - `Solver.constraints` is an unordered `Table` in Nimony's stdlib
##     (OrderedTable is an alias), so constraint iteration order may differ.

import std/[syncio, tables]


type
  Tag = object
    marker: Symbol
    other: Symbol

  EditInfo = object
    tag: Tag
    constraint: Constraint
    constant: KiwiScalar

  VarInfo = object
    symbol: Symbol
    variable: Variable

  Solver* = object ## Incremental Cassowary solver state.
    constraints: Table[Constraint, Tag]
    rows: AssocMap[Symbol, Row]
    vars: AssocMap[VariableId, VarInfo]
    edits: Table[VariableId, EditInfo]
    infeasibleRows: seq[Symbol]
    objective: Row
    artificial: Row
    hasArtificial: bool
    idTick: uint64

  SolverRef* = ref Solver ## Shared solver handle returned by `newSolver`.

proc initSolver*(): Solver =
  ## Creates an empty value-style solver.
  Solver(
    constraints: initTable[Constraint, Tag](),
    rows: initAssocMap[Symbol, Row](),
    vars: initAssocMap[VariableId, VarInfo](),
    edits: initTable[VariableId, EditInfo](),
    infeasibleRows: @[],
    objective: initRow(),
    artificial: initRow(),
    hasArtificial: false,
    idTick: 1,
  )

proc newSolver*(): SolverRef =
  ## Creates an empty ref-style solver handle.
  ##
  ## Whole-object `result[] = initSolver()` assignment trips a Nimony 0.6
  ## C-backend bug (incompatible types on `*result = value`), so build the
  ## ref with the field constructor instead.
  result = SolverRef(
    constraints: initTable[Constraint, Tag](),
    rows: initAssocMap[Symbol, Row](),
    vars: initAssocMap[VariableId, VarInfo](),
    edits: initTable[VariableId, EditInfo](),
    infeasibleRows: @[],
    objective: initRow(),
    artificial: initRow(),
    hasArtificial: false,
    idTick: 1,
  )

func newSymbol(solver: var Solver, kind: SymbolKind): Symbol =
  result = initSymbol(kind, SymbolId(solver.idTick))
  solver.idTick = solver.idTick + 1

proc sortedKeys(row: Row): seq[Symbol] =
  result = newSeqOfCap[Symbol](row.cells.len)
  for symbol in row.cells.keys:
    result.add symbol

func preferSymbol(symbol, current: Symbol): bool =
  current.isInvalid or symbol < current

func preferRatio(
    symbol: Symbol, ratio: KiwiScalar, current: Symbol, currentRatio: KiwiScalar
): bool =
  ratio < currentRatio or
    (not current.isInvalid and ratio == currentRatio and symbol < current)

func getVarSymbol(solver: var Solver, variable: Variable): Symbol {.raises.} =
  let id = variable.variableId
  let index = solver.vars.findIndex(id)
  if index >= 0:
    return solver.vars.entries[index].val.symbol

  result = solver.newSymbol(skExternal)
  solver.vars[id] = VarInfo(symbol: result, variable: variable)

func allDummies(row: Row): bool =
  for symbol in row.cells.keys:
    if not symbol.isDummy:
      return false
  true

func anyPivotableSymbol(row: Row): Symbol =
  result = initSymbol()
  for symbol in row.cells.keys:
    if symbol.isPivotable and symbol.preferSymbol(result):
      result = symbol

func substitute(solver: var Solver, symbol: Symbol, row: Row) =
  for index in 0 ..< solver.rows.entries.len:
    let entryKey = solver.rows.entries[index].key
    solver.rows.entries[index].val.substitute(symbol, row)
    if not entryKey.isExternal and solver.rows.entries[index].val.constant < 0:
      solver.infeasibleRows.add entryKey

  solver.objective.substitute(symbol, row)
  if solver.hasArtificial:
    solver.artificial.substitute(symbol, row)

func createRow(
    solver: var Solver, constraint: Constraint, tag: var Tag
): Row {.raises.} =
  result = initRow(constraint.expression.constant)

  let terms = constraint.expression.terms
  for index in 0 ..< terms.len:
    let term = terms[index]
    if abs(term.coefficient.float64) >= 1.0e-8:
      let symbol = solver.getVarSymbol(term.variable)
      let existing = solver.rows.findIndex(symbol)
      if existing >= 0:
        result.insert(solver.rows.entries[existing].val, term.coefficient)
      else:
        result.insert(symbol, term.coefficient)

  case constraint.relation
  of relLe, relGe:
    let coeff =
      if constraint.relation == relLe:
        1
      else:
        -1
    let slack = solver.newSymbol(skSlack)
    tag.marker = slack
    result.insert(slack, coeff)
    if constraint.strength < Required:
      let error = solver.newSymbol(skError)
      tag.other = error
      result.insert(error, KiwiScalar(-float64(coeff)))
      solver.objective.insert(error, constraint.strength.KiwiScalar)
  of relEq:
    if constraint.strength < Required:
      let errPlus = solver.newSymbol(skError)
      let errMinus = solver.newSymbol(skError)
      tag.marker = errPlus
      tag.other = errMinus
      result.insert(errPlus, -1)
      result.insert(errMinus, 1)
      solver.objective.insert(errPlus, constraint.strength.KiwiScalar)
      solver.objective.insert(errMinus, constraint.strength.KiwiScalar)
    else:
      let dummy = solver.newSymbol(skDummy)
      tag.marker = dummy
      result.insert(dummy)

  if result.constant < 0:
    result.reverseSign()

func chooseSubject(row: Row, tag: Tag): Symbol {.raises.} =
  result = initSymbol()
  for symbol in row.cells.keys:
    if symbol.isExternal and symbol.preferSymbol(result):
      result = symbol

  if not result.isInvalid:
    return result

  if tag.marker.isPivotable and row.coefficientFor(tag.marker) < 0:
    return tag.marker

  if tag.other.isPivotable and row.coefficientFor(tag.other) < 0:
    return tag.other

func getEnteringSymbol(objective: Row): Symbol =
  result = initSymbol()
  for symbol, coefficient in objective.cells:
    if not symbol.isDummy and coefficient < 0 and symbol.preferSymbol(result):
      result = symbol

func getDualEnteringSymbol(solver: Solver, row: Row): Symbol =
  var ratio = KiwiScalar(Inf)
  result = initSymbol()
  for symbol, coefficient in row.cells:
    if coefficient > 0 and not symbol.isDummy:
      let r = KiwiScalar(
        solver.objective.coefficientFor(symbol).float64 / coefficient.float64
      )
      if symbol.preferRatio(r, result, ratio):
        ratio = r
        result = symbol

func getLeavingRow(solver: Solver, entering: Symbol): Symbol =
  var ratio = KiwiScalar(Inf)
  result = initSymbol()
  for index in 0 ..< solver.rows.entries.len:
    let symbol = solver.rows.entries[index].key
    if not symbol.isExternal:
      let temp = solver.rows.entries[index].val.coefficientFor(entering)
      if temp < 0:
        let tempRatio = KiwiScalar(-solver.rows.entries[index].val.constant.float64 / temp.float64)
        if symbol.preferRatio(tempRatio, result, ratio):
          ratio = tempRatio
          result = symbol

func getMarkerLeavingRow(solver: Solver, marker: Symbol): Symbol =
  var r1 = KiwiScalar(Inf)
  var r2 = KiwiScalar(Inf)
  var first = initSymbol()
  var second = initSymbol()
  var third = initSymbol()

  for index in 0 ..< solver.rows.entries.len:
    let symbol = solver.rows.entries[index].key
    let row = solver.rows.entries[index].val
    let c = row.coefficientFor(marker)
    if c != 0:
      if symbol.isExternal:
        if third.isInvalid or third < symbol:
          third = symbol
      elif c < 0:
        let r = KiwiScalar(-row.constant.float64 / c.float64)
        if symbol.preferRatio(r, first, r1):
          r1 = r
          first = symbol
      else:
        let r = KiwiScalar(row.constant.float64 / c.float64)
        if symbol.preferRatio(r, second, r2):
          r2 = r
          second = symbol

  if not first.isInvalid:
    first
  elif not second.isInvalid:
    second
  else:
    third

type ObjectiveKind = enum
  ## Which objective row `optimize` pivots on. Selecting by kind (instead of
  ## passing the row) keeps Nimony's alias checker happy: the row lives inside
  ## the same `var Solver` that is passed alongside it.
  optObjective
  optArtificial

proc optimize(solver: var Solver, kind: ObjectiveKind) {.raises.} =
  while true:
    let entering =
      if kind == optObjective:
        getEnteringSymbol(solver.objective)
      else:
        getEnteringSymbol(solver.artificial)
    if entering.isInvalid:
      return

    let leaving = solver.getLeavingRow(entering)
    if leaving.isInvalid:
      raiseInternalSolverError("The objective is unbounded.")

    var row = initRow()
    discard solver.rows.pop(leaving, row)
    row.solveFor(leaving, entering)
    solver.substitute(entering, row)
    solver.rows[entering] = row

proc dualOptimize(solver: var Solver) {.raises.} =
  while solver.infeasibleRows.len > 0:
    let leaving = solver.infeasibleRows.pop()
    let index = solver.rows.findIndex(leaving)
    if index >= 0:
      let row = solver.rows.entries[index].val
      if abs(row.constant.float64) >= 1.0e-8 and row.constant < 0:
        let entering = solver.getDualEnteringSymbol(row)
        if entering.isInvalid:
          raiseInternalSolverError("Dual optimize failed.")

        var poppedRow = initRow()
        discard solver.rows.pop(leaving, poppedRow)
        poppedRow.solveFor(leaving, entering)
        solver.substitute(entering, poppedRow)
        solver.rows[entering] = poppedRow

proc addWithArtificialVariable(solver: var Solver, row: Row): bool {.raises.} =
  let art = solver.newSymbol(skSlack)
  solver.rows[art] = row
  solver.artificial = row
  solver.hasArtificial = true

  solver.optimize(optArtificial)
  result = abs(solver.artificial.constant.float64) < 1.0e-8
  solver.hasArtificial = false
  solver.artificial = initRow()

  var artRow = initRow()
  if solver.rows.pop(art, artRow):
    if artRow.cells.len == 0:
      return result

    let entering = anyPivotableSymbol(artRow)
    if entering.isInvalid:
      return false

    artRow.solveFor(art, entering)
    solver.substitute(entering, artRow)
    solver.rows[entering] = artRow

  for index in 0 ..< solver.rows.entries.len:
    solver.rows.entries[index].val.remove(art)
  solver.objective.remove(art)

func removeMarkerEffects(solver: var Solver, marker: Symbol, strength: Strength) =
  let strengthValue = KiwiScalar(-float64(strength))
  let index = solver.rows.findIndex(marker)
  if index >= 0:
    solver.objective.insert(solver.rows.entries[index].val, strengthValue)
  else:
    solver.objective.insert(marker, strengthValue)

func removeConstraintEffects(
    solver: var Solver, constraint: Constraint, tag: Tag
) =
  if tag.marker.kind == skError:
    solver.removeMarkerEffects(tag.marker, constraint.strength)
  if tag.other.kind == skError:
    solver.removeMarkerEffects(tag.other, constraint.strength)

type ConstraintLookup = object
  found: bool
  stored: Constraint

func findConstraint(solver: Solver, constraint: Constraint): ConstraintLookup =
  if solver.constraints.hasKey(constraint):
    return ConstraintLookup(found: true, stored: constraint)

  result = ConstraintLookup(found: false, stored: constraint)
  for existing, _ in solver.constraints:
    if existing.sameShape(constraint):
      return ConstraintLookup(found: true, stored: existing)

proc addConstraint*(solver: var Solver, constraint: Constraint) {.raises.} =
  ## Adds `constraint` to `solver`.
  ##
  ## Raises `DuplicateConstraintError` if the same constraint identity is
  ## already present. Raises `UnsatisfiableConstraintError` for required
  ## constraints that cannot be satisfied.
  if solver.constraints.hasKey(constraint):
    raiseDuplicateConstraint(constraint)

  var tag = Tag(marker: initSymbol(), other: initSymbol())
  var row = solver.createRow(constraint, tag)
  var subject = chooseSubject(row, tag)

  if subject.isInvalid and row.allDummies:
    if abs(row.constant.float64) >= 1.0e-8:
      raiseUnsatisfiableConstraint(constraint)
    subject = tag.marker

  if subject.isInvalid:
    if not solver.addWithArtificialVariable(row):
      raiseUnsatisfiableConstraint(constraint)
  else:
    row.solveFor(subject)
    solver.substitute(subject, row)
    solver.rows[subject] = row

  solver.constraints[constraint] = tag
  solver.optimize(optObjective)

proc removeConstraint*(solver: var Solver, constraint: Constraint) {.raises.} =
  ## Removes `constraint` from `solver`.
  ##
  ## The lookup accepts the same constraint identity or a structurally equivalent
  ## constraint. Raises `UnknownConstraintError` when no matching constraint has
  ## been added.
  let lookup = solver.findConstraint(constraint)
  if not lookup.found:
    raiseUnknownConstraint(constraint)

  let storedConstraint = lookup.stored
  let tag = solver.constraints[storedConstraint]
  solver.constraints.del(storedConstraint)
  solver.removeConstraintEffects(storedConstraint, tag)

  var markerRow = initRow()
  if solver.rows.pop(tag.marker, markerRow):
    discard
  else:
    let leaving = solver.getMarkerLeavingRow(tag.marker)
    if leaving.isInvalid:
      raiseInternalSolverError("failed to find leaving row")

    var row = initRow()
    discard solver.rows.pop(leaving, row)
    row.solveFor(leaving, tag.marker)
    solver.substitute(tag.marker, row)

  solver.optimize(optObjective)

func hasConstraint*(solver: Solver, constraint: Constraint): bool =
  ## Returns true when `constraint` or a structurally equivalent constraint has been added.
  solver.findConstraint(constraint).found

proc addEditVariable*(
    solver: var Solver, variable: Variable, strength: Strength
) {.raises.} =
  ## Adds `variable` as an editable variable with a non-required strength.
  ##
  ## Raises `DuplicateEditVariableError` when already present and
  ## `BadRequiredStrengthError` when `strength` clips to `Required`.
  if solver.edits.hasKey(variable.variableId):
    raiseDuplicateEditVariable(variable)

  let clipped = strength.clip
  if clipped == Required:
    raiseBadRequiredStrength()

  let constraint = newConstraint(toExpression(variable), relEq, clipped)
  solver.addConstraint(constraint)
  solver.edits[variable.variableId] = EditInfo(
    tag: solver.constraints[constraint], constraint: constraint, constant: 0
  )

proc removeEditVariable*(solver: var Solver, variable: Variable) {.raises.} =
  ## Removes an editable variable.
  ##
  ## Raises `UnknownEditVariableError` if `variable` is not editable.
  if not solver.edits.hasKey(variable.variableId):
    raiseUnknownEditVariable(variable)
  let info = solver.edits[variable.variableId]
  solver.removeConstraint(info.constraint)
  solver.edits.del(variable.variableId)

func hasEditVariable*(solver: Solver, variable: Variable): bool =
  ## Returns true when `variable` has been added as an edit variable.
  solver.edits.hasKey(variable.variableId)

proc suggestValue*(
    solver: var Solver, variable: Variable, value: KiwiScalar
) {.raises.} =
  ## Suggests a new value for an edit variable and dual-optimizes the solver.
  ##
  ## Raises `UnknownEditVariableError` if `variable` is not editable.
  let checkedValue = value.requireFinite("suggested value")
  let id = variable.variableId
  var marker = initSymbol()
  var other = initSymbol()
  var delta: KiwiScalar

  if not solver.edits.hasKey(id):
    raiseUnknownEditVariable(variable)
  let info = addr getOrQuit(solver.edits, id)
  delta = checkedValue - info[].constant
  info[].constant = checkedValue
  marker = info[].tag.marker
  other = info[].tag.other

  let markerIndex = solver.rows.findIndex(marker)
  if markerIndex >= 0:
    if solver.rows.entries[markerIndex].val.add(-delta) < 0:
      solver.infeasibleRows.add marker
    solver.dualOptimize()
    return

  let otherIndex = solver.rows.findIndex(other)
  if otherIndex >= 0:
    if solver.rows.entries[otherIndex].val.add(delta) < 0:
      solver.infeasibleRows.add other
    solver.dualOptimize()
    return

  for index in 0 ..< solver.rows.entries.len:
    let symbol = solver.rows.entries[index].key
    if solver.rows.entries[index].val.addProductFor(marker, delta) and
        solver.rows.entries[index].val.constant < 0 and not symbol.isExternal:
      solver.infeasibleRows.add symbol

  solver.dualOptimize()

func updateVariables*(solver: var Solver) =
  ## Writes solved values back into all external variables known to `solver`.
  for index in 0 ..< solver.vars.entries.len:
    let info = solver.vars.entries[index].val
    let rowIndex = solver.rows.findIndex(info.symbol)
    if rowIndex >= 0:
      info.variable.setSolverValue(solver.rows.entries[rowIndex].val.constant)
    else:
      info.variable.setSolverValue(0)

proc reset*(solver: var Solver) =
  ## Resets the solver to the empty starting state.
  solver = initSolver()

proc dumps*(solver: Solver): string =
  ## Returns a textual dump of the current solver internals.
  result = ""
  result.add "Objective\n---------\n"
  for symbol in solver.objective.sortedKeys:
    let coefficient = solver.objective.coefficientFor(symbol)
    result.add " + " & $coefficient & " * " & $symbol
  result.add "\n\nTableau\n-------\n"
  for symbol, row in solver.rows:
    result.add $symbol & " |"
    for cell in row.sortedKeys:
      let coefficient = row.coefficientFor(cell)
      result.add " + " & $coefficient & " * " & $cell
    result.add "\n"
  result.add "\nVariables\n---------\n"
  for _, info in solver.vars:
    result.add info.variable.name & " = " & $info.symbol & "\n"
  result.add "\nConstraints\n-----------\n"
  result.add $solver.constraints.len & "\n"

proc dump*(solver: Solver) =
  ## Writes a textual dump of the current solver internals to stdout.
  echo solver.dumps

proc `[]=`*(solver: var Solver, variable: Variable, strength: Strength) {.raises.} =
  ## Adds `variable` as an edit variable with `strength`.
  solver.addEditVariable(variable, strength)

proc constraint*(
    solver: var Solver, constraint: Constraint
): Constraint {.discardable, raises.} =
  ## Adds `constraint` to `solver` and returns it for later removal.
  solver.addConstraint(constraint)
  constraint

proc remove*(solver: var Solver, constraint: Constraint) {.raises.} =
  ## Removes `constraint` from `solver`.
  solver.removeConstraint(constraint)

proc remove*(solver: var Solver, variable: Variable) {.raises.} =
  ## Removes `variable` as an edit variable.
  solver.removeEditVariable(variable)

func has*(solver: Solver, constraint: Constraint): bool =
  ## Returns true when `constraint` has been added to `solver`.
  solver.hasConstraint(constraint)

func has*(solver: Solver, variable: Variable): bool =
  ## Returns true when `variable` is an edit variable.
  solver.hasEditVariable(variable)

proc suggest*(solver: var Solver, variable: Variable, value: KiwiScalar) {.raises.} =
  ## Suggests `value` for an edit variable.
  solver.suggestValue(variable, value)

func update*(solver: var Solver) =
  ## Writes solved values back into variables known to `solver`.
  solver.updateVariables()

proc addConstraint*(solver: SolverRef, constraint: Constraint) {.raises.} =
  ## Adds `constraint` to a ref-style solver.
  solver[].addConstraint(constraint)

proc removeConstraint*(solver: SolverRef, constraint: Constraint) {.raises.} =
  ## Removes `constraint` from a ref-style solver.
  solver[].removeConstraint(constraint)

func hasConstraint*(solver: SolverRef, constraint: Constraint): bool =
  ## Returns true when `constraint` has been added to a ref-style solver.
  solver[].hasConstraint(constraint)

proc addEditVariable*(
    solver: SolverRef, variable: Variable, strength: Strength
) {.raises.} =
  ## Adds `variable` as an edit variable with `strength`.
  solver[].addEditVariable(variable, strength)

proc removeEditVariable*(solver: SolverRef, variable: Variable) {.raises.} =
  ## Removes an edit variable from a ref-style solver.
  solver[].removeEditVariable(variable)

func hasEditVariable*(solver: SolverRef, variable: Variable): bool =
  ## Returns true when `variable` is editable in a ref-style solver.
  solver[].hasEditVariable(variable)

proc suggestValue*(
    solver: SolverRef, variable: Variable, value: KiwiScalar
) {.raises.} =
  ## Suggests a new value for an edit variable on a ref-style solver.
  solver[].suggestValue(variable, value)

proc updateVariables*(solver: SolverRef) =
  ## Writes solved values back into variables known to a ref-style solver.
  solver[].updateVariables()

proc reset*(solver: SolverRef) =
  ## Resets a ref-style solver to the empty starting state.
  ## Per-field: whole-object `solver[] = initSolver()` hits the same
  ## Nimony 0.6 C-backend bug as `newSolver` above.
  let fresh = initSolver()
  solver.constraints = fresh.constraints
  solver.rows = fresh.rows
  solver.vars = fresh.vars
  solver.edits = fresh.edits
  solver.infeasibleRows = fresh.infeasibleRows
  solver.objective = fresh.objective
  solver.artificial = fresh.artificial
  solver.hasArtificial = fresh.hasArtificial
  solver.idTick = fresh.idTick

proc dumps*(solver: SolverRef): string =
  ## Returns a textual dump from a ref-style solver.
  solver[].dumps()

proc dump*(solver: SolverRef) =
  ## Writes a textual dump from a ref-style solver to stdout.
  solver[].dump()

proc `[]=`*(solver: SolverRef, variable: Variable, strength: Strength) {.raises.} =
  ## Adds `variable` as an edit variable on a ref-style solver.
  solver[].addEditVariable(variable, strength)

proc constraint*(
    solver: SolverRef, constraint: Constraint
): Constraint {.discardable, raises.} =
  ## Adds `constraint` to a ref-style solver and returns it for later removal.
  solver[].addConstraint(constraint)
  constraint

proc remove*(solver: SolverRef, constraint: Constraint) {.raises.} =
  ## Removes `constraint` from a ref-style solver.
  solver[].removeConstraint(constraint)

proc remove*(solver: SolverRef, variable: Variable) {.raises.} =
  ## Removes `variable` as an edit variable from a ref-style solver.
  solver[].removeEditVariable(variable)

func has*(solver: SolverRef, constraint: Constraint): bool =
  ## Returns true when `constraint` has been added to a ref-style solver.
  solver[].hasConstraint(constraint)

func has*(solver: SolverRef, variable: Variable): bool =
  ## Returns true when `variable` is editable in a ref-style solver.
  solver[].hasEditVariable(variable)

proc suggest*(solver: SolverRef, variable: Variable, value: KiwiScalar) {.raises.} =
  ## Suggests `value` for an edit variable on a ref-style solver.
  solver[].suggestValue(variable, value)

func update*(solver: SolverRef) =
  ## Writes solved values back into variables known to a ref-style solver.
  solver[].updateVariables()
