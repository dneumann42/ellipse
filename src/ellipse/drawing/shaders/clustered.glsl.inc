
// Shared layout with clustered.nim: 32 x 16 x 32 world-space clusters.
// RGBA32F, 1024 texels a row: scalar record i is component i&3 of texel i>>2.
layout(set = 2, binding = 1) uniform sampler2D uClusters;
vec4 clusterTexel(int t) { return texelFetch(uClusters, ivec2(t & 1023, t >> 10), 0); }
float clusterValue(int i) { return clusterTexel(i >> 2)[i & 3]; }
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
bool clipShadowPlane(vec3 n, float bound, vec3 origin, vec3 ray, inout float enter, inout float leave) {
  float distance=bound-dot(n,origin), along=dot(n,ray);
  if (abs(along)<0.000001) return distance>=0.0;
  if (along>0.0) leave=min(leave,distance/along);
  else enter=max(enter,distance/along);
  return enter<leave;
}
// ShadowTreeOffset=740356 holds the node count. Near lists start at texel
// 185344 (NearOffset/4), 16 leaf records per light; tree nodes start at
// texel 226304 (ShadowNodeBase/4). Every record is five texels: lo+escape,
// hi+kind, center.xz/half.xz, rotation/profile.xy, profile.zw (clustered.nim).
// Kinds: 0 inner, 1 box, 2/3 roof, 4 frame. A frame node (world bounds;
// texel 2 = pivot.xz, cos, sin) puts the following nodes up to its escape
// index in a rotated frame where oriented walls are axis aligned.

// Segment origin+[0,1]*direction against record t's convex solid (kinds 1-3)
// or bounds (kinds 0 and 4), in the frame origin/direction are given in.
bool recordHit(int t, int mode, vec3 lo, vec3 hi, vec3 origin, vec3 direction) {
  vec4 d = vec4(0.0);
  if (mode > 0 && mode < 4) {
    d = clusterTexel(t+3);
    if (dot(d.xy,d.xy) > 0.5) {
      vec4 c = clusterTexel(t+2);
      vec2 delta = origin.xz-c.xy;
      origin.xz = vec2(dot(delta,d.xy),dot(delta,vec2(-d.y,d.x)));
      direction.xz = vec2(dot(direction.xz,d.xy),dot(direction.xz,vec2(-d.y,d.x)));
      lo.xz = -c.zw;
      hi.xz = c.zw;
    }
  }
  float enter = 0.0, leave = 1.0;
  for (int axis=0; axis<3; ++axis) {
    if (abs(direction[axis]) < 0.000001) {
      if (origin[axis] < lo[axis] || origin[axis] > hi[axis]) return false;
    } else {
      float s0 = (lo[axis]-origin[axis])/direction[axis];
      float s1 = (hi[axis]-origin[axis])/direction[axis];
      enter = max(enter,min(s0,s1));
      leave = min(leave,max(s0,s1));
    }
  }
  bool hit = true;
  if (enter<leave && (mode==2 || mode==3)) {
    vec4 p = vec4(d.zw,clusterTexel(t+4).xy);
    if (mode==2) {
      if (p.x>0.0) hit=clipShadowPlane(vec3(p.x,1,0),lo.y+p.y,origin,direction,enter,leave) &&
        clipShadowPlane(vec3(-p.x,1,0),lo.y+p.y,origin,direction,enter,leave);
      if (hit && p.z>0.0) hit=clipShadowPlane(vec3(0,1,p.z),lo.y+p.w,origin,direction,enter,leave) &&
        clipShadowPlane(vec3(0,1,-p.z),lo.y+p.w,origin,direction,enter,leave);
    } else hit=clipShadowPlane(vec3(-p.x,1,-p.z),lo.y+p.y,origin,direction,enter,leave);
  }
  // Bias in world units, independent of light/receiver separation. A
  // proportional endpoint bias used to skip thin walls near a light.
  return hit && enter < leave && leave > 0.0 && enter < 1.0;
}

bool shadowBlocked(vec3 start, vec3 finish) {
  vec3 ray = finish-start;
  int count = int(clusterValue(740356));
  int node = 0;
  vec3 frameStart = start, frameRay = ray;
  int frameEnd = -1;
  while (node < count) {
    if (node == frameEnd) { frameStart = start; frameRay = ray; frameEnd = -1; }
    int t = 226304 + node*5;
    vec4 a = clusterTexel(t), b = clusterTexel(t+1);
    int mode = int(b.w);
    bool hit = mode == 4 ? recordHit(t,mode,a.xyz,b.xyz,start,ray)
                         : recordHit(t,mode,a.xyz,b.xyz,frameStart,frameRay);
    if (!hit) node = int(a.w);
    else if (mode == 4) {
      vec4 frame = clusterTexel(t+2);
      vec2 delta = start.xz-frame.xy;
      frameStart = vec3(dot(delta,frame.zw),start.y,dot(delta,vec2(-frame.w,frame.z)));
      frameRay = vec3(dot(ray.xz,frame.zw),ray.y,dot(ray.xz,vec2(-frame.w,frame.z)));
      frameEnd = int(a.w);
      ++node;
    }
    else if (mode > 0) return true;
    else ++node;
  }
  return false;
}

// Light `light`'s nearest static solids first: most blocked rays end there.
bool lightShadowBlocked(int light, int nearCount, vec3 start, vec3 finish) {
  vec3 ray = finish-start;
  for (int k=0; k<nearCount; ++k) {
    int t = 185344 + (light*16+k)*5;
    vec4 a = clusterTexel(t), b = clusterTexel(t+1);
    if (recordHit(t,int(b.w),a.xyz,b.xyz,start,ray)) return true;
  }
  return shadowBlocked(start,finish);
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
    int light = int(clusterValue(at+1+i));
    int b = 1 + light * 2; // texel of a light record
    vec4 position = clusterTexel(b);
    vec3 lp = position.xyz;
    vec3 delta = lp-p;
    float radius = position.w;
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
    vec4 color = clusterTexel(b+1);
    if (color.w > 0.5 && lightShadowBlocked(light,int(color.w)-1,p+n*0.01,lp)) continue;
    total += color.xyz*falloff*falloff*diffuse;
  }
  // Screen-anchored ordered dithering quantizes local illumination only.
  const int bayer[16]=int[16](0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5);
  ivec2 px=ivec2(gl_FragCoord.xy)&3;
  float threshold=(float(bayer[px.x+px.y*4])+0.5)/16.0;
  return floor(total*8.0+threshold)/8.0;
}
