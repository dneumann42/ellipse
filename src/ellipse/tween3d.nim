import std/[math]

import drawing/geometry

export geometry

## A 3D tween library: values that move themselves.
##
## A `Tween3` carries a `Vec3` from where it stands to where it is sent,
## over a duration, shaped by an easing curve. Advancing it is the frame's
## business: `advance(t, dt)` every tick, `value(t)` for the position the
## tween has reached. A tween that is sent somewhere new mid-flight starts
## from wherever it actually is, so reversals bend rather than snap --
## raise a shield, let go half-way up, and it glides back from that height.
##
## A `Pose` is the whole of a thing's place in 3D -- position, rotation
## (Euler, radians), scale -- and a `PoseTween` drives the three together;
## `matrix(pose)` composes them into the model matrix.

type
  EaseFn* = proc (t: float32): float32 {.noSideEffect.} ## 0..1 in, shaped 0..1 out

  Tween3* = object
    fromV, toV: Vec3
    elapsed, duration: float32
    easing: EaseFn
    running*: bool ## whether the tween still has ground to cover

  Pose* = object
    position*, rotation*: Vec3 ## rotation: Euler radians about x, y, z
    scale*: Vec3

  PoseTween* = object
    pos*, rot*, scl*: Tween3

const
  EaseNone* = EaseFn(proc (t: float32): float32 = t)
  EaseInQuad* = EaseFn(proc (t: float32): float32 = t * t)
  EaseOutQuad* = EaseFn(proc (t: float32): float32 = 1 - (1 - t) * (1 - t))
  EaseInOutQuad* = EaseFn(proc (t: float32): float32 =
    if t < 0.5: 2 * t * t else: 1 - (-2 * t + 2) ^ 2 / 2)
  EaseInCubic* = EaseFn(proc (t: float32): float32 = t * t * t)
  EaseOutCubic* = EaseFn(proc (t: float32): float32 = 1 - (1 - t) ^ 3)
  EaseInOutCubic* = EaseFn(proc (t: float32): float32 =
    if t < 0.5: 4 * t * t * t else: 1 - (-2 * t + 2) ^ 3 / 2)
  EaseOutBack* = EaseFn(proc (t: float32): float32 =
    const c1 = 1.70158
    const c3 = c1 + 1
    1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2)
  EaseInOutBack* = EaseFn(proc (t: float32): float32 =
    const c1 = 1.70158
    const c2 = c1 * 1.525
    if t < 0.5: ((2 * t) ^ 2 * ((c2 + 1) * 2 * t - c2)) / 2
    else: ((2 * t - 2) ^ 2 * ((c2 + 1) * (t * 2 - 2) + c2) + 2) / 2)
  EaseOutElastic* = EaseFn(proc (t: float32): float32 =
    const c4 = 2 * float32(PI) / 3
    if t <= 0: 0
    elif t >= 1: 1
    else: pow(2, -10 * t) * sin((t * 10 - 0.75) * c4) + 1)
  EaseOutBounce* = EaseFn(proc (t: float32): float32 =
    const n1 = 7.5625'f32
    const d1 = 2.75'f32
    if t < 1 / d1:
      n1 * t * t
    elif t < 2 / d1:
      let u = t - 1.5 / d1
      n1 * u * u + 0.75
    elif t < 2.5 / d1:
      let u = t - 2.25 / d1
      n1 * u * u + 0.9375
    else:
      let u = t - 2.625 / d1
      n1 * u * u + 0.984375)

proc lerp*(a, b: float32, t: float32): float32 =
  a + (b - a) * t

proc lerp*(a, b: Vec3, t: float32): Vec3 =
  a + (b - a) * t

proc value*(t: Tween3): Vec3 =
  ## Where the tween stands: the eased point between its ends, or the
  ## destination once it has arrived.
  if not t.running:
    return t.toV
  if t.duration <= 0:
    return t.toV
  let p = clamp(t.elapsed / t.duration, 0'f32, 1'f32)
  lerp(t.fromV, t.toV, (if t.easing.isNil: p else: t.easing(p)))

proc done*(t: Tween3): bool =
  not t.running

proc run*(t: var Tween3, fromV, toV: Vec3, duration: float32,
          easing: EaseFn = EaseInOutQuad) =
  ## Send the tween from a known place to a destination.
  t.fromV = fromV
  t.toV = toV
  t.duration = max(duration, 0'f32)
  t.elapsed = 0
  t.easing = easing
  t.running = t.duration > 0
  if not t.running:
    t.toV = toV

proc run*(t: var Tween3, toV: Vec3, duration: float32,
          easing: EaseFn = EaseInOutQuad) =
  ## Send the tween from wherever it stands -- interrupting mid-flight
  ## bends the new path out of the current position, never a jump.
  t.run(t.value(), toV, duration, easing)

proc advance*(t: var Tween3, dt: float32) =
  ## Move the tween along by `dt` seconds; it lands and rests at its
  ## destination when the time is spent.
  if not t.running:
    return
  t.elapsed += dt
  if t.elapsed >= t.duration:
    t.fromV = t.toV
    t.elapsed = t.duration
    t.running = false

proc stop*(t: var Tween3) =
  ## Halt where it stands: the current value becomes both end, so the
  ## tween rests mid-air rather than sliding to its old destination.
  if t.running:
    t.toV = t.value()
    t.fromV = t.toV
    t.running = false

proc reset*(t: var Tween3, at: Vec3) =
  ## Park the tween at a place, ended and ready for a fresh `run`.
  t.fromV = at
  t.toV = at
  t.elapsed = 0
  t.running = false

proc pose*(t: PoseTween): Pose =
  Pose(position: t.pos.value(), rotation: t.rot.value(),
       scale: t.scl.value())

proc done*(t: PoseTween): bool =
  t.pos.done and t.rot.done and t.scl.done

proc run*(t: var PoseTween, to: Pose, duration: float32,
          easing: EaseFn = EaseInOutQuad) =
  ## Send the whole pose from where it stands to `to`.
  t.pos.run(to.position, duration, easing)
  t.rot.run(to.rotation, duration, easing)
  t.scl.run(to.scale, duration, easing)

proc run*(t: var PoseTween, fromPose, to: Pose, duration: float32,
          easing: EaseFn = EaseInOutQuad) =
  t.pos.run(fromPose.position, to.position, duration, easing)
  t.rot.run(fromPose.rotation, to.rotation, duration, easing)
  t.scl.run(fromPose.scale, to.scale, duration, easing)

proc advance*(t: var PoseTween, dt: float32) =
  t.pos.advance(dt)
  t.rot.advance(dt)
  t.scl.advance(dt)

proc matrix*(p: Pose): Mat4 =
  ## The pose as a model matrix: scale, then rotate (z about y about x,
  ## the Euler order), then translate.
  translationMatrix(p.position) *
    rotationMatrix(p.rotation.y, vec3(0, 1, 0)) *
    rotationMatrix(p.rotation.x, vec3(1, 0, 0)) *
    rotationMatrix(p.rotation.z, vec3(0, 0, 1)) *
    scalingMatrix(p.scale)
