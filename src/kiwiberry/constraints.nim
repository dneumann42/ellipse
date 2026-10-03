## Constraint construction and query API.
##
## The upstream generic DSL (`[A: ConstraintValue, B: ConstraintValue]`
## operators) does not bind under Nimony's eager generics, so every operand
## pair gets a concrete overload. The block below is generated; see
## scripts/gen_dsl.nim.

import std/hashes
import std/atomics


type
  Relation* = enum ## Relational operator used by a constraint.
    relLe ## Less-than-or-equal relation: expression <= 0.
    relGe ## Greater-than-or-equal relation: expression >= 0.
    relEq ## Equality relation: expression == 0.

  Constraint* = ref object ## Identity-bearing linear constraint.
    id: uint64
    expressionValue: Expression
    relationValue: Relation
    strengthValue: Strength

var nextConstraintId: uint64 = 1

proc takeConstraintId(): uint64 =
  atomicFetchAdd(nextConstraintId, 1'u64)

proc reduce(expression: Expression): Expression {.raises.} =
  let expressionTerms = expression.terms
  var terms = newSeqOfCap[Term](expressionTerms.len)

  for index in 0 ..< expressionTerms.len:
    let term = expressionTerms[index]
    let id = term.variable.variableId
    var found = false
    for existingIndex in 0 ..< terms.len:
      if terms[existingIndex].variable.variableId == id:
        let variable = terms[existingIndex].variable
        let coefficient = terms[existingIndex].coefficient + term.coefficient
        terms[existingIndex] = initTerm(variable, coefficient)
        found = true
        break
    if not found:
      terms.add term

  var compactTerms = newSeqOfCap[Term](terms.len)
  for term in terms:
    if not term.coefficient.nearZero:
      compactTerms.add term
  initExpression(compactTerms, expression.constant)

proc newConstraint*(
    expression: Expression, relation: Relation, strength: Strength = Required
): Constraint {.raises.} =
  ## Creates a constraint from an already-normalized expression.
  ##
  ## The expression is reduced by variable identity and the strength is clipped
  ## into Kiwi's supported strength range.
  result = Constraint(
    id: takeConstraintId(),
    expressionValue: reduce(expression),
    relationValue: relation,
    strengthValue: strength.clip,
  )

func expression*(constraint: Constraint): Expression =
  ## Returns the reduced expression stored by `constraint`.
  constraint.expressionValue

func relation*(constraint: Constraint): Relation =
  ## Returns the relation used by `constraint`.
  constraint.relationValue

func strength*(constraint: Constraint): Strength =
  ## Returns the clipped strength used by `constraint`.
  constraint.strengthValue

func sameConstraint*(a, b: Constraint): bool =
  ## Returns true when both handles refer to the same constraint identity.
  a.id == b.id

func sameExpressionShape(a, b: Expression): bool =
  if a.constant != b.constant or a.len != b.len:
    return false

  for left in a:
    var found = false
    for right in b:
      if left.variable.sameVariable(right.variable):
        if left.coefficient != right.coefficient:
          return false
        found = true
        break
    if not found:
      return false

  true

func sameShape*(a, b: Constraint): bool =
  ## Returns true when two constraints have the same expression, relation, and strength.
  a.relation == b.relation and a.strength == b.strength and
    sameExpressionShape(a.expression, b.expression)

func `==`*(a, b: Constraint): bool =
  ## Compares constraint identity, not structural equality.
  a.sameConstraint(b)

func hash*(constraint: Constraint): Hash =
  ## Hashes a constraint by identity.
  hash(constraint.id)

func violated*(constraint: Constraint): bool =
  ## Returns true when the current variable values violate `constraint`.
  case constraint.relationValue
  of relEq:
    not constraint.expressionValue.value.nearZero
  of relGe:
    constraint.expressionValue.value < 0
  of relLe:
    constraint.expressionValue.value > 0

proc withStrength*(constraint: Constraint, strength: Strength): Constraint {.raises.} =
  ## Returns a new constraint with the same expression/relation and new strength.
  newConstraint(constraint.expressionValue, constraint.relationValue, strength)

proc `|`*(constraint: Constraint, strength: Strength): Constraint {.raises.} =
  ## Convenience syntax for `withStrength`.
  constraint.withStrength(strength)

include dsl_generated
