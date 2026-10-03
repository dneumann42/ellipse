## Linear terms and expressions.
##
## Upstream returns several accessors via `lent`; Nimony has no `lent`, so
## they return copies. `seq.add` of whole sequences is replaced by loops.


type
  Term* = object ## Variable/coefficient pair.
    variableValue: Variable
    coefficientValue: KiwiScalar

  Expression* = object ## Linear expression plus constant.
    termsValue: seq[Term]
    constantValue: KiwiScalar

func initTerm*(variable: Variable, coefficient: KiwiScalar = 1): Term {.raises.} =
  ## Creates a term for `coefficient * variable`.
  Term(
    variableValue: variable,
    coefficientValue: coefficient.requireFinite("term coefficient"),
  )

func initExpression*(
    terms: seq[Term] = @[], constant: KiwiScalar = KiwiScalar(0.0)
): Expression {.raises.} =
  ## Creates an expression from terms and a constant.
  Expression(termsValue: terms, constantValue: constant.requireFinite("expression constant"))

func toExpression*(variable: Variable): Expression {.raises.} =
  ## Converts a variable to a one-term expression.
  initExpression(@[initTerm(variable)])

func toExpression*(term: Term): Expression {.raises.} =
  ## Converts a term to a one-term expression.
  initExpression(@[term])

func toExpression*(constant: KiwiScalar): Expression {.raises.} =
  ## Converts a constant to an expression with no terms.
  initExpression(constant = constant)

func variable*(term: Term): Variable =
  ## Returns the variable used by `term`.
  term.variableValue

func coefficient*(term: Term): KiwiScalar =
  ## Returns the coefficient used by `term`.
  term.coefficientValue

func value*(term: Term): KiwiScalar =
  ## Evaluates the term using the variable's current value.
  term.coefficientValue * term.variableValue.value

func terms*(expression: Expression): seq[Term] =
  ## Returns the expression terms.
  expression.termsValue

func constant*(expression: Expression): KiwiScalar =
  ## Returns the expression constant.
  expression.constantValue

func len*(expression: Expression): int =
  ## Returns the number of terms in the expression.
  expression.termsValue.len

iterator items*(expression: Expression): Term =
  for index in 0 ..< expression.termsValue.len:
    yield expression.termsValue[index]

func value*(expression: Expression): KiwiScalar =
  ## Evaluates the expression using current variable values.
  result = expression.constantValue
  for term in expression.termsValue:
    result += term.value

func `-`*(variable: Variable): Term {.raises.} =
  initTerm(variable, -1)

func `*`*(variable: Variable, coefficient: KiwiScalar): Term {.raises.} =
  initTerm(variable, coefficient)

func `*`*(coefficient: KiwiScalar, variable: Variable): Term {.raises.} =
  variable * coefficient

func `/`*(variable: Variable, denominator: KiwiScalar): Term {.raises.} =
  variable * (1 / denominator)

func `-`*(term: Term): Term {.raises.} =
  initTerm(term.variableValue, -term.coefficientValue)

func `*`*(term: Term, coefficient: KiwiScalar): Term {.raises.} =
  initTerm(term.variableValue, term.coefficientValue * coefficient)

func `*`*(coefficient: KiwiScalar, term: Term): Term {.raises.} =
  term * coefficient

func `/`*(term: Term, denominator: KiwiScalar): Term {.raises.} =
  term * (1 / denominator)

func `-`*(expression: Expression): Expression {.raises.} =
  result = initExpression(constant = -expression.constantValue)
  for term in expression.termsValue:
    result.termsValue.add -term

func `*`*(expression: Expression, coefficient: KiwiScalar): Expression {.raises.} =
  result = initExpression(constant = expression.constantValue * coefficient)
  for term in expression.termsValue:
    result.termsValue.add term * coefficient

func `*`*(coefficient: KiwiScalar, expression: Expression): Expression {.raises.} =
  expression * coefficient

func `/`*(expression: Expression, denominator: KiwiScalar): Expression {.raises.} =
  expression * (1 / denominator)

func `+`*(left, right: Expression): Expression {.raises.} =
  result = initExpression(constant = left.constantValue + right.constantValue)
  result.termsValue = newSeqOfCap[Term](left.termsValue.len + right.termsValue.len)
  for term in left.termsValue:
    result.termsValue.add term
  for term in right.termsValue:
    result.termsValue.add term

func `+`*(expression: Expression, term: Term): Expression =
  result = expression
  result.termsValue.add term

func `+`*(term: Term, expression: Expression): Expression =
  expression + term

func `+`*(expression: Expression, variable: Variable): Expression {.raises.} =
  expression + initTerm(variable)

func `+`*(variable: Variable, expression: Expression): Expression {.raises.} =
  expression + variable

func `+`*(expression: Expression, constant: KiwiScalar): Expression =
  result = expression
  result.constantValue += constant

func `+`*(constant: KiwiScalar, expression: Expression): Expression =
  expression + constant

func `+`*(left, right: Term): Expression {.raises.} =
  initExpression(@[left, right])

func `+`*(term: Term, variable: Variable): Expression {.raises.} =
  term + initTerm(variable)

func `+`*(variable: Variable, term: Term): Expression {.raises.} =
  term + variable

func `+`*(term: Term, constant: KiwiScalar): Expression {.raises.} =
  initExpression(@[term], constant)

func `+`*(constant: KiwiScalar, term: Term): Expression {.raises.} =
  term + constant

func `+`*(left, right: Variable): Expression {.raises.} =
  initTerm(left) + right

func `+`*(variable: Variable, constant: KiwiScalar): Expression {.raises.} =
  initTerm(variable) + constant

func `+`*(constant: KiwiScalar, variable: Variable): Expression {.raises.} =
  variable + constant

func `-`*(left, right: Expression): Expression {.raises.} =
  left + -right

func `-`*(expression: Expression, term: Term): Expression {.raises.} =
  expression + -term

func `-`*(term: Term, expression: Expression): Expression {.raises.} =
  toExpression(term) - expression

func `-`*(expression: Expression, variable: Variable): Expression {.raises.} =
  expression + -variable

func `-`*(variable: Variable, expression: Expression): Expression {.raises.} =
  toExpression(variable) - expression

func `-`*(expression: Expression, constant: KiwiScalar): Expression {.raises.} =
  expression + -constant

func `-`*(constant: KiwiScalar, expression: Expression): Expression {.raises.} =
  toExpression(constant) - expression

func `-`*(left, right: Term): Expression {.raises.} =
  left + -right

func `-`*(term: Term, variable: Variable): Expression {.raises.} =
  term + -variable

func `-`*(variable: Variable, term: Term): Expression {.raises.} =
  initTerm(variable) - term

func `-`*(term: Term, constant: KiwiScalar): Expression {.raises.} =
  term + -constant

func `-`*(constant: KiwiScalar, term: Term): Expression {.raises.} =
  toExpression(constant) - toExpression(term)

func `-`*(left, right: Variable): Expression {.raises.} =
  initTerm(left) - right

func `-`*(variable: Variable, constant: KiwiScalar): Expression {.raises.} =
  initTerm(variable) - constant

func `-`*(constant: KiwiScalar, variable: Variable): Expression {.raises.} =
  toExpression(constant) - toExpression(variable)
