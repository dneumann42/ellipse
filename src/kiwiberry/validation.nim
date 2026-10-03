## Validation helpers for numeric solver input.
##
## Nimony has no exception objects: invalid values raise `ValueError`
## (an `ErrorCode` value). See `errors.nim` for the public aliases.

func isFiniteNumber*(value: float64): bool =
  ## Returns true when `value` is neither NaN nor infinity.
  value == value and value != Inf and value != -Inf

func requireFiniteNumber*(value: float64, name: string): float64 {.raises.} =
  ## Returns `value` or raises `ValueError` when it is NaN or infinity.
  ## `name` is kept for call-site documentation only.
  if not value.isFiniteNumber:
    raise ValueError
  value

func requireNonZeroFiniteNumber*(value: float64, name: string): float64 {.raises.} =
  ## Returns `value` or raises `ValueError` when it is zero, NaN, or infinity.
  discard requireFiniteNumber(value, name)
  if value == 0.0:
    raise ValueError
  value
