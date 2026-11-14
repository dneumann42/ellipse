
// Shared layout with clustered.nim: 32 x 16 x 32 world-space clusters.
layout(set = 2, binding = 1) uniform sampler2D uClusters;
float clusterValue(int i) { return texelFetch(uClusters, ivec2(i % 1024, i / 1024), 0).r; }
vec3 clusterVec(int i) { return vec3(clusterValue(i), clusterValue(i+1), clusterValue(i+2)); }

// RoomOffset=413700, RoomStride=94, RoomGridOffset=461828 (clustered.nim).
// No camera-dependent exposure: only the receiver's world position matters.
float environmentExposure(vec3 p) {
  float cell = clusterValue(3);
  if (cell <= 0.0) return 1.0;
  ivec3 c = ivec3(floor((p - clusterVec(0)) / cell));
  if (any(lessThan(c, ivec3(0))) || any(greaterThanEqual(c, ivec3(32,16,32)))) return 1.0;
  int at = 461828 + (c.x + 32 * (c.y + 16 * c.z)) * 17;
  int count = min(int(clusterValue(at)), 16);
  for (int i = 0; i < count; ++i) {
    int b = 413700 + int(clusterValue(at + 1 + i)) * 94;
    vec3 lo = clusterVec(b), hi = clusterVec(b + 3);
    if (any(lessThan(p,lo)) || any(greaterThan(p,hi))) continue;
    vec2 rotation = vec2(clusterValue(b+92),clusterValue(b+93));
    if (dot(rotation,rotation) > 0.5) {
      vec2 delta = p.xz-vec2(clusterValue(b+88),clusterValue(b+89));
      vec2 local = vec2(dot(delta,rotation),dot(delta,vec2(-rotation.y,rotation.x)));
      vec2 halfSize = vec2(clusterValue(b+90),clusterValue(b+91));
      if (any(greaterThan(abs(local),halfSize))) continue;
    }
    float exposure = 0.04;
    int portals = min(int(clusterValue(b + 6)), 8);
    for (int j = 0; j < portals; ++j) {
      int port = b + 8 + j * 10;
      vec3 low = clusterVec(port), high = clusterVec(port + 3);
      vec3 delta = p - clamp(p,low,high);
      float depth = dot(delta, clusterVec(port + 6));
      if (depth < -0.001) continue;
      vec3 size = high - low;
      float area = size.x*size.y + size.y*size.z + size.z*size.x;
      float d2 = dot(delta,delta);
      float facing = min(max(depth,0.02)*inversesqrt(max(d2,0.0004)),1.0);
      float transmission = clamp(clusterValue(port + 9),0.0,1.0);
      float sky = transmission*facing*area/max(area+4.0*d2,0.0001);
      exposure = max(exposure,0.04+0.96*sky);
    }
    return exposure;
  }
  return 1.0;
}

// Same appended tree layout as clustered.nim. All material paths use this.
bool shadowBlocked(vec3 start, vec3 finish) {
  vec3 ray = finish-start;
  int count = int(clusterValue(740356));
  int node = 0;
  while (node < count) {
    int at = 740357 + node*14;
    vec3 lo = clusterVec(at), hi = clusterVec(at+3);
    vec3 origin = start, direction = ray;
    vec2 rotation = vec2(clusterValue(at+12),clusterValue(at+13));
    if (clusterValue(at+7) > 0.5 && dot(rotation,rotation) > 0.5) {
      vec2 center = vec2(clusterValue(at+8),clusterValue(at+9));
      vec2 d = start.xz-center;
      origin.xz = vec2(dot(d,rotation),dot(d,vec2(-rotation.y,rotation.x)));
      direction.xz = vec2(dot(ray.xz,rotation),dot(ray.xz,vec2(-rotation.y,rotation.x)));
      vec2 halfSize = vec2(clusterValue(at+10),clusterValue(at+11));
      lo.xz = -halfSize;
      hi.xz = halfSize;
    }
    float enter = 0.0, leave = 1.0;
    bool hit = true;
    for (int axis=0; axis<3; ++axis) {
      if (abs(direction[axis]) < 0.000001) {
        if (origin[axis] < lo[axis] || origin[axis] > hi[axis]) hit = false;
      } else {
        float a = (lo[axis]-origin[axis])/direction[axis];
        float b = (hi[axis]-origin[axis])/direction[axis];
        enter = max(enter,min(a,b));
        leave = min(leave,max(a,b));
      }
    }
    // Bias in world units, independent of light/receiver separation. A
    // proportional endpoint bias used to skip thin walls near a light.
    hit = hit && enter < leave && leave > 0.0 && enter < 1.0;
    if (!hit) node = int(clusterValue(at+6));
    else if (clusterValue(at+7) > 0.5) return true;
    else ++node;
  }
  return false;
}

vec3 pointLighting(vec3 p, vec3 n) {
  float cell = clusterValue(3);
  if (cell <= 0.0) return vec3(0.0);
  ivec3 c = ivec3(floor((p - clusterVec(0)) / cell));
  if (any(lessThan(c, ivec3(0))) || any(greaterThanEqual(c, ivec3(32,16,32)))) return vec3(0.0);
  int at = 4100 + (c.x + 32 * (c.y + 16 * c.z)) * 25;
  int count = min(int(clusterValue(at)), 24);
  vec3 total = vec3(0.0);
  for (int i=0; i<count; ++i) {
    int b = 4 + int(clusterValue(at+1+i)) * 8;
    vec3 lp = clusterVec(b);
    vec3 delta = lp-p;
    float radius = clusterValue(b+3);
    float d2 = dot(delta,delta);
    if (d2 >= radius*radius) continue;
    float falloff = 1.0 - d2/(radius*radius);
    // A small diffuse bounce keeps walls beside a sconce readable. It
    // shares the same visibility test as direct light, so it cannot cross
    // a solid wall or illuminate a neighbouring enclosed room.
    // Normal-free sprites average max(N dot L, 0) over a sphere (1/4).
    float lambert = dot(n,n) < 0.5 ? 0.25 :
      max(dot(n, delta * inversesqrt(max(d2,0.0001))), 0.0);
    float diffuse = 0.4 + 0.6*lambert;
    float visible = 1.0;
    if (clusterValue(b+7) > 0.5 &&
        shadowBlocked(p+n*0.01,lp)) visible = 0.0;
    total += clusterVec(b+4)*falloff*falloff*diffuse*visible;
  }
  // Screen-anchored ordered dithering quantizes local illumination only.
  const int bayer[16]=int[16](0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5);
  ivec2 px=ivec2(gl_FragCoord.xy)&3;
  float threshold=(float(bayer[px.x+px.y*4])+0.5)/16.0;
  return floor(total*8.0+threshold)/8.0;
}
