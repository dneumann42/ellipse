import std/[unittest, math]

import ellipse/tween3d

suite "tween3d":
  test "a tween runs from where it stands to its destination":
    var t = Tween3()
    t.reset(vec3(0, 0, 0))
    t.run(vec3(10, 0, 0), 1, EaseNone)
    check not t.done
    t.advance(0.25)
    check abs(t.value().x - 2.5) < 1e-4
    t.advance(0.75)
    check abs(t.value().x - 10) < 1e-4
    check t.done
    t.advance(1)
    check abs(t.value().x - 10) < 1e-4

  test "an interrupted tween bends from its current place":
    var t = Tween3()
    t.reset(vec3(0, 0, 0))
    t.run(vec3(10, 0, 0), 1, EaseNone)
    t.advance(0.5)
    t.run(vec3(0, 0, 0), 1, EaseNone)
    check abs(t.value().x - 5) < 1e-4
    t.advance(0.5)
    check abs(t.value().x - 2.5) < 1e-4

  test "easing shapes the path":
    var t = Tween3()
    t.reset(vec3(0, 0, 0))
    t.run(vec3(1, 0, 0), 1, EaseInQuad)
    t.advance(0.5)
    check abs(t.value().x - 0.25) < 1e-4

  test "stop parks the tween where it stands":
    var t = Tween3()
    t.reset(vec3(0, 0, 0))
    t.run(vec3(4, 0, 0), 1, EaseNone)
    t.advance(0.5)
    t.stop()
    check t.done
    check abs(t.value().x - 2) < 1e-4
    t.advance(1)
    check abs(t.value().x - 2) < 1e-4

  test "a pose tween carries position, rotation and scale together":
    var t = PoseTween()
    t.pos.reset(vec3(0, 0, 0))
    t.rot.reset(vec3(0, 0, 0))
    t.scl.reset(vec3(1, 1, 1))
    t.run(Pose(position: vec3(2, 0, 0), rotation: vec3(0, 0, 0),
      scale: vec3(1, 1, 1)), 1, EaseNone)
    t.advance(0.5)
    check abs(t.pose().position.x - 1) < 1e-4
    check not t.done
    t.advance(0.5)
    check t.done

  test "a pose matrix places and turns":
    let p = Pose(position: vec3(1, 2, 3), rotation: vec3(0, float32(PI) / 2, 0),
      scale: vec3(1, 1, 1))
    let m = p.matrix()
    let v = m * vec4(1, 0, 0, 1)
    check abs(v.x - 1) < 1e-4
    check abs(v.z - 2) < 1e-4
