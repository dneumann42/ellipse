## Numeric scalar type used by the solver.
##
## The upstream `'ks` literal template is dropped: Nimony cannot bind
## `static` template parameters. Integer and float64 converters provide the
## same ergonomics (`240'ks` -> `240`).

import std/hashes


type KiwiScalar* = distinct float64 ## Solver numeric scalar.

func `+`*(a, b: KiwiScalar): KiwiScalar {.borrow.}
func `-`*(a, b: KiwiScalar): KiwiScalar {.borrow.}
func `*`*(a, b: KiwiScalar): KiwiScalar {.borrow.}
func `/`*(a, b: KiwiScalar): KiwiScalar {.borrow.}
func `-`*(a: KiwiScalar): KiwiScalar {.borrow.}
func `<`*(a, b: KiwiScalar): bool {.borrow.}
func `<=`*(a, b: KiwiScalar): bool {.borrow.}
func `==`*(a, b: KiwiScalar): bool {.borrow.}
func `>`*(a, b: KiwiScalar): bool = b < a
func `>=`*(a, b: KiwiScalar): bool = not (a < b)
func hash*(value: KiwiScalar): Hash {.borrow.}
func `$`*(value: KiwiScalar): string {.borrow.}
# Compound assignments cannot {.borrow.} in Nimony (var KiwiScalar does not
# alias var float64), so they are spelled out.
func `+=`*(a: var KiwiScalar, b: KiwiScalar) =
  a = KiwiScalar(float64(a) + float64(b))

func `-=`*(a: var KiwiScalar, b: KiwiScalar) =
  a = KiwiScalar(float64(a) - float64(b))

func `*=`*(a: var KiwiScalar, b: KiwiScalar) =
  a = KiwiScalar(float64(a) * float64(b))

func `/=`*(a: var KiwiScalar, b: KiwiScalar) =
  a = KiwiScalar(float64(a) / float64(b))

func abs*(value: KiwiScalar): KiwiScalar =
  KiwiScalar(abs(float64 value))

func min*(a, b: KiwiScalar): KiwiScalar =
  if b < a: b else: a

func max*(a, b: KiwiScalar): KiwiScalar =
  if a < b: b else: a

converter toKiwiScalar*(value: int): KiwiScalar =
  ## Converts an integer literal/value to `KiwiScalar`.
  ## Finite by construction; real validation happens at solver entry points.
  KiwiScalar(float64 value)

converter toKiwiScalar*(value: float64): KiwiScalar =
  ## Converts a floating-point value to `KiwiScalar`.
  ## NaN/infinity are rejected later by `requireFinite`.
  KiwiScalar(value)

func requireFinite*(value: KiwiScalar, name: string): KiwiScalar {.raises.} =
  ## Returns `value` or raises `ValueError` when it is NaN or infinity.
  KiwiScalar(requireFiniteNumber(float64 value, name))

func isFinite*(value: KiwiScalar): bool {.inline.} =
  ## Returns true when `value` is neither NaN nor infinity.
  value.float64.isFiniteNumber

func nearZero*(value: KiwiScalar): bool {.inline.} =
  ## Returns true when `value` is within Kiwi's zero tolerance.
  abs(value).float64 < 1.0e-8
