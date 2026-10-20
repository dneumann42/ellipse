#version 450

// Blends up to eight tiling layers by the weights painted at the vertices.
// Each texel's alpha is its height: where two layers share a spot, the one
// standing higher (its weight plus its height) wins, and `blendDepth` sets
// how far below the winner another layer may still show through. Weights
// alone would crossfade; with the heights, stones poke through the grass
// before the grass gives way to them.

layout(location = 0) in vec3 worldPosition;
layout(location = 1) in vec4 weightsLow;
layout(location = 2) in vec4 weightsHigh;
layout(location = 3) in vec4 lighting;

layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2DArray uLayers;

layout(set = 3, binding = 0) uniform Splat {
  vec4 uSplat; // x: metres one texture repeat spans, y: blend depth, z: height contrast
};

const int Layers = 8;
const float Present = 0.002; // weights below this are not sampled at all

void main() {
  float weights[Layers] = float[Layers](
    weightsLow.x, weightsLow.y, weightsLow.z, weightsLow.w,
    weightsHigh.x, weightsHigh.y, weightsHigh.z, weightsHigh.w);
  float total = 0.0;
  for (int i = 0; i < Layers; i++) {
    total += weights[i];
  }
  total = max(total, 1e-4);

  // Gradients taken before any branch: which layers are sampled differs
  // from pixel to pixel, and implicit derivatives inside such a branch
  // would pick the wrong mip level along every border.
  vec2 uv = worldPosition.xz / uSplat.x;
  vec2 dx = dFdx(uv);
  vec2 dy = dFdy(uv);
  vec4 texels[Layers];
  float scores[Layers];
  float best = -1e9;
  for (int i = 0; i < Layers; i++) {
    float w = weights[i] / total;
    weights[i] = w;
    if (w > Present) {
      texels[i] = textureGrad(uLayers, vec3(uv, float(i)), dx, dy);
      scores[i] = w + texels[i].a * uSplat.z;
      best = max(best, scores[i]);
    }
  }

  vec3 colour = vec3(0.0);
  float sum = 0.0;
  for (int i = 0; i < Layers; i++) {
    if (weights[i] > Present) {
      // The fade on small weights lets a layer leave without a hard edge
      // where its weight reaches zero.
      float share = max(scores[i] - best + uSplat.y, 0.0) * min(weights[i] * 16.0, 1.0);
      colour += texels[i].rgb * share;
      sum += share;
    }
  }
  colour /= max(sum, 1e-4);

  outColor = vec4(colour * lighting.rgb + lighting.a, 1.0);
}
