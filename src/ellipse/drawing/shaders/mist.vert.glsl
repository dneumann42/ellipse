#version 450

// Mist billboards: one instance per puff, its four corners built here from
// gl_VertexIndex. Each puff floats on the axes the artist hands over -- the
// camera's flat right, so the ground-hugging ellipses never tumble with the
// view's roll, and the camera's up -- leans slowly on its own sway, and
// turns over time so the same silhouette never sits in the same place
// twice. The shaping is done by the fragment stage: this one only lays the
// quad where the eye will find it.

layout(location = 0) in vec4 iCenter; // xyz: the middle; w: radius, metres
layout(location = 1) in vec4 iShape;  // x: seed 0..1; y: stretch; z: spin;
                                      // w: opacity, already scaled

layout(set = 1, binding = 0) uniform Uniforms {
  mat4 viewProj;
  vec4 right;  // xyz: the camera's flat right; w: seconds
  vec4 up;     // xyz: the camera's up; w: unused
  vec4 params; // x: master opacity; y: vertical squash; zw: unused
  vec4 axis;   // the view's forward row: xyz, w -- a world point's view
               // depth falls out of it by one dot product
} u;

layout(location = 0) out vec2 corner;      // the quad's own -1..1 space
layout(location = 1) out vec3 worldPosition;
layout(location = 2) out vec4 shape;       // x: seed; yw: opacity
layout(location = 3) out float viewDepth;  // metres along the view's -z

const vec2 quad[6] = vec2[](
  vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0),
  vec2(-1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, 1.0));

void main() {
  float seed = iShape.x;
  float t = u.right.w;

  // The puff leans a small fraction of its own size: two sines on their
  // own phases, so neighbours drift apart instead of pacing each other.
  float swayX = sin(t * 0.11 + seed * 40.0) * 0.06;
  float swayY = sin(t * 0.17 + seed * 70.0) * 0.05;

  // Blobs turn slowly about the view axis: the spin an instance arrives
  // with, eased by its own seed so a hundred puffs never tick in step.
  float spin = iShape.z + t * (0.02 + fract(seed * 7.13) * 0.05);

  vec2 q = quad[gl_VertexIndex];
  // Turn first, then flatten: the spin may send a puff's long axis any
  // which way across the ground, but the squash that follows pins every
  // silhouette low -- mist lies flat however it drifts, and no turn ever
  // rears one up into a wall across the eye. The squash itself rides a
  // seed: neighbours crest at different heights, and the field reads as
  // rolls rather than as a shelf with one clean edge.
  float squash = u.params.y * (0.7 + 0.9 * fract(seed * 5.77));
  float cs = cos(spin), sn = sin(spin);
  vec2 rq = vec2(q.x * cs - q.y * sn, q.x * sn + q.y * cs);
  vec2 s = vec2(rq.x * iShape.y, rq.y * squash) * iCenter.w;
  vec3 world = iCenter.xyz + u.right.xyz * (s.x + swayX * iCenter.w) +
                                  u.up.xyz * (s.y + swayY * iCenter.w);
  gl_Position = u.viewProj * vec4(world, 1.0);

  // Corners travel already turned: the fragment stage fades the crest of
  // the silhouette against the world behind it, and the crest is the
  // rotated y -- which way is up for this puff -- not the unspun square's.
  corner = rq;
  worldPosition = world;
  viewDepth = -(dot(u.axis, vec4(world, 1.0)));
  // And no two puffs carry the same weight: a second seed-shake of the
  // opacity keeps a stack of neighbours from settling into one flat sheet.
  shape = vec4(seed, 0.0, 0.0, iShape.w * u.params.x *
                              (0.55 + 0.9 * fract(seed * 9.13)));
}
