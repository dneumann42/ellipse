
// Shared layout with clustered.nim: 32 x 16 x 32 world-space clusters.
layout(set = 2, binding = 1) uniform sampler2D uClusters;
float clusterValue(int i) { return texelFetch(uClusters, ivec2(i % 1024, i / 1024), 0).r; }
vec3 clusterVec(int i) { return vec3(clusterValue(i), clusterValue(i+1), clusterValue(i+2)); }

// RoomOffset=425988, RoomStride=94, RoomGridOffset=474116 (clustered.nim).
// No camera-dependent exposure: only the receiver's world position matters.
float environmentExposure(vec3 p) {
  float cell = clusterValue(3);
  if (cell <= 0.0) return 1.0;
  ivec3 c = ivec3(floor((p - clusterVec(0)) / cell));
  if (any(lessThan(c, ivec3(0))) || any(greaterThanEqual(c, ivec3(32,16,32)))) return 1.0;
  int at = 474116 + (c.x + 32 * (c.y + 16 * c.z)) * 17;
  int count = min(int(clusterValue(at)), 16);
  for (int i = 0; i < count; ++i) {
    int b = 425988 + int(clusterValue(at + 1 + i)) * 94;
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

vec3 pointLighting(vec3 p, vec3 n) {
  float cell = clusterValue(3);
  if (cell <= 0.0) return vec3(0.0);
  ivec3 c = ivec3(floor((p - clusterVec(0)) / cell));
  if (any(lessThan(c, ivec3(0))) || any(greaterThanEqual(c, ivec3(32,16,32)))) return vec3(0.0);
  int at = 16388 + (c.x + 32 * (c.y + 16 * c.z)) * 25;
  int count = min(int(clusterValue(at)), 24);
  vec3 total = vec3(0.0);
  for (int i=0; i<count; ++i) {
    int b = 4 + int(clusterValue(at+1+i)) * 32;
    vec3 lp = clusterVec(b);
    vec3 delta = lp-p;
    float radius = clusterValue(b+3);
    float d2 = dot(delta,delta);
    if (d2 >= radius*radius) continue;
    float falloff = 1.0 - d2/(radius*radius);
    float diffuse = max(dot(n, delta * inversesqrt(max(d2,0.0001))), 0.0);
    if (diffuse <= 0.0) continue;
    float visible = 1.0;
    // Segment/AABB shadows: at most four simple nearby wall proxies per
    // light, no shadow render passes. Offset the receiver to avoid acne.
    vec3 start = p + n*0.035;
    vec3 ray = lp-start;
    vec3 invRay = 1.0 / mix(ray, vec3(0.000001), lessThan(abs(ray),vec3(0.000001)));
    int shadows = min(int(clusterValue(b+7)),4);
    for (int j=0; j<shadows; ++j) {
      vec3 lo = clusterVec(b+8+j*6);
      vec3 hi = clusterVec(b+11+j*6);
      vec3 t0=(lo-start)*invRay, t1=(hi-start)*invRay;
      vec3 mn=min(t0,t1), mx=max(t0,t1);
      float enter=max(max(mn.x,mn.y),mn.z);
      float leave=min(min(mx.x,mx.y),mx.z);
      if (max(enter,0.002)<min(leave,0.998)) { visible=0.0; break; }
    }
    total += clusterVec(b+4)*falloff*falloff*diffuse*visible;
  }
  // Screen-anchored ordered dithering quantizes local illumination only.
  const int bayer[16]=int[16](0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5);
  ivec2 px=ivec2(gl_FragCoord.xy)&3;
  float threshold=(float(bayer[px.x+px.y*4])+0.5)/16.0;
  return floor(total*8.0+threshold)/8.0;
}
