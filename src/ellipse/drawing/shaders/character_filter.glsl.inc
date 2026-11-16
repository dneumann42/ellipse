// Pixel squares with screen-space coverage. Compose source texels BEFORE
// reconstruction, so transparent clothing does not bleed into an opaque body.
// Shared by colour and occlusion: derivatives must be evaluated before discard.
vec4 overPixel(vec4 under, vec4 source) {
  return vec4(source.rgb * source.a + under.rgb * (1.0-source.a),
              source.a + under.a * (1.0-source.a));
}

vec4 sourcePixel(vec2 uv, float layer, int level) {
  ivec2 size = textureSize(uSprites, level).xy;
  ivec2 p = clamp(ivec2(floor(uv * vec2(size))), ivec2(0), size-1);
  return texelFetch(uSprites, ivec3(p, int(layer+0.5)), level);
}

vec4 composedPixel(vec2 uv, int level, vec2 scales[4]) {
  vec4 body = sourcePixel(uv, fragmentLayer, level);
  vec4 result = vec4(body.rgb*body.a, body.a);
  vec2 overlays[4] = vec2[](clothingUv0,clothingUv1,clothingUv2,clothingUv3);
  for (int i=0; i<4; ++i) {
    if (clothingLayers[i] < 0.0) continue;
    vec2 at = overlays[i] + (uv-fragmentUv)*scales[i];
    result = overPixel(result, sourcePixel(at, clothingLayers[i], level));
  }
  return result;
}

vec4 reconstructedLevel(int level, vec2 footprint, vec2 scales[4]) {
  vec2 size = vec2(textureSize(uSprites, level).xy);
  vec2 q = fragmentUv*size;
  vec2 width = clamp(footprint*size, vec2(0.00001), vec2(1.0));
  vec2 f = fract(q);
  // Flat throughout each painted pixel, a one-screen-pixel transition at
  // its boundaries. At minification this becomes ordinary bilinear weights.
  vec2 warped = floor(q) + clamp(f/width,0.0,0.5) +
                clamp((f-1.0)/width+0.5,0.0,0.5);
  vec2 base = floor(warped-0.5);
  vec2 weight = fract(warped-0.5);
  vec4 a = composedPixel((base+vec2(0.5,0.5))/size,level,scales);
  // Most magnified fragments lie inside one painted pixel. Explicit-LOD
  // fetches let us skip its unused neighbours without divergent derivatives.
  if (weight.x == 0.0 && weight.y == 0.0) return a;
  if (weight.x == 0.0)
    return mix(a,composedPixel((base+vec2(0.5,1.5))/size,level,scales),weight.y);
  vec4 b = composedPixel((base+vec2(1.5,0.5))/size,level,scales);
  if (weight.y == 0.0) return mix(a,b,weight.x);
  vec4 c = composedPixel((base+vec2(0.5,1.5))/size,level,scales);
  vec4 d = composedPixel((base+vec2(1.5,1.5))/size,level,scales);
  return mix(mix(a,b,weight.x),mix(c,d,weight.x),weight.y);
}

vec4 coverageTexel() {
  vec2 size = vec2(textureSize(uSprites,0).xy);
  vec2 dx = dFdx(fragmentUv), dy = dFdy(fragmentUv);
  vec2 footprint = abs(dx)+abs(dy);
  vec2 safeWidth = max(footprint,vec2(1e-10));
  vec2 scales[4] = vec2[](fwidth(clothingUv0)/safeWidth,
    fwidth(clothingUv1)/safeWidth,fwidth(clothingUv2)/safeWidth,
    fwidth(clothingUv3)/safeWidth);
  float reach = max(length(dx*size),length(dy*size));
  int last = textureQueryLevels(uSprites)-1;
  float lod = clamp(log2(max(reach,1.0)),0.0,float(last));
  int level = int(floor(lod));
  vec4 result = reconstructedLevel(level,footprint,scales);
  if (lod > float(level))
    result = mix(result,reconstructedLevel(min(level+1,last),footprint,scales),fract(lod));
  if (result.a > 0.0) result.rgb /= result.a;
  return result;
}
