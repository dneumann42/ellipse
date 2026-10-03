## Error codes raised by solver operations.
##
## Nimony models errors as flat `ErrorCode` enum values instead of exception
## objects, so the upstream `object of CatchableError` types become named
## constants. Catch with `except ErrorCode as e:` and compare against these
## aliases. Error payload fields (the offending constraint or variable) are
## not available; Nimony exceptions carry no data.


const
  InvalidSolverValueError* = ValueError ## Numeric solver input is not usable.
  UnsatisfiableConstraintError* = RangeError ## Required constraint is infeasible.
  UnknownConstraintError* = KeyError ## Constraint was not added to the solver.
  DuplicateConstraintError* = AlreadyInProgress ## Constraint has already been added.
  UnknownEditVariableError* = IndexError ## Variable is not an active edit variable.
  DuplicateEditVariableError* = LockedError ## Variable is already an edit variable.
  BadRequiredStrengthError* = OverflowError ## Required strength used as edit strength.
  InternalSolverError* = BugError ## Solver reached an unexpected internal state.

proc raiseUnsatisfiableConstraint*(constraint: Constraint) {.raises, noreturn.} =
  ## Raises `UnsatisfiableConstraintError` for `constraint`.
  discard constraint
  raise UnsatisfiableConstraintError

proc raiseUnknownConstraint*(constraint: Constraint) {.raises, noreturn.} =
  ## Raises `UnknownConstraintError` for `constraint`.
  discard constraint
  raise UnknownConstraintError

proc raiseDuplicateConstraint*(constraint: Constraint) {.raises, noreturn.} =
  ## Raises `DuplicateConstraintError` for `constraint`.
  discard constraint
  raise DuplicateConstraintError

proc raiseUnknownEditVariable*(variable: Variable) {.raises, noreturn.} =
  ## Raises `UnknownEditVariableError` for `variable`.
  discard variable
  raise UnknownEditVariableError

proc raiseDuplicateEditVariable*(variable: Variable) {.raises, noreturn.} =
  ## Raises `DuplicateEditVariableError` for `variable`.
  discard variable
  raise DuplicateEditVariableError

proc raiseBadRequiredStrength*() {.raises, noreturn.} =
  ## Raises `BadRequiredStrengthError`.
  raise BadRequiredStrengthError

proc raiseInternalSolverError*(message: string) {.raises, noreturn.} =
  ## Raises `InternalSolverError`. `message` is kept for call sites.
  discard message
  raise InternalSolverError
