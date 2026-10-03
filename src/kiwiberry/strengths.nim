## Constraint strength helpers.


type Strength* = distinct KiwiScalar ## Weighted priority for soft constraints.

func `==`*(a, b: Strength): bool {.borrow.}
func `<`*(a, b: Strength): bool {.borrow.}
func `<=`*(a, b: Strength): bool {.borrow.}
func `>`*(a, b: Strength): bool = b < a
func `>=`*(a, b: Strength): bool = not (a < b)
func `$`*(value: Strength): string {.borrow.}

func createStrength*(a, b, c: KiwiScalar, weight: KiwiScalar = 1): Strength {.raises.} =
  ## Creates a strength from three weighted priority components.
  let checkedWeight = weight.requireFinite("strength weight")
  let aa = max(
    0, min(1000, a.requireFinite("strength a") * checkedWeight)
  )
  let bb = max(
    0, min(1000, b.requireFinite("strength b") * checkedWeight)
  )
  let cc = max(
    0, min(1000, c.requireFinite("strength c") * checkedWeight)
  )
  Strength(aa * 1_000_000 + bb * 1_000 + cc)

# Pre-computed strength values (avoid compile-time evaluation of createStrength
# under Nimony's expreval). Matches createStrength(a, b, c, 1) exactly:
#   value = a * 1_000_000 + b * 1_000 + c
const
  Required* = Strength(KiwiScalar(1_001_001_000.0)) ## Required constraint strength.
  Strong* = Strength(KiwiScalar(1_000_000.0)) ## Strong soft constraint strength.
  Medium* = Strength(KiwiScalar(1_000.0)) ## Medium soft constraint strength.
  Weak* = Strength(KiwiScalar(1.0)) ## Weak soft constraint strength.

func required*(): Strength =
  ## Returns `Required`.
  Required

func strong*(): Strength =
  ## Returns `Strong`.
  Strong

func medium*(): Strength =
  ## Returns `Medium`.
  Medium

func weak*(): Strength =
  ## Returns `Weak`.
  Weak

func clip*(strength: Strength): Strength =
  ## Clips `strength` into the supported `0..Required` range.
  Strength(max(0, min(Required.KiwiScalar, strength.KiwiScalar)))
