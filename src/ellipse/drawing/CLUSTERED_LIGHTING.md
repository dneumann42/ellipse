# Clustered forward lighting

`Artist3D.setPointLights(lights, explorerPosition, occluders)` stages linear RGB
point lights. Call it every frame (pass an empty list in scenes without lights).
Directional/ambient lighting still applies. Meshes, terrain, billboards and water
sample one shared light grid in their forward colour passes. Depth/SSAO passes
remain unchanged. Sprite planes keep their explicitly supplied colour.

The CPU bins radius spheres into 8-metre world-space cells: 32 x 16 x 32 cells,
centred on the explorer. This is a spatial 3D cluster grid rather than camera
screen tiles, so it also works with orthographic cameras. Each fragment reads
only its cell's list. The closest 512 lights inside 112 metres are retained;
intensity fades over the last 20% of that distance. Clusters retain the nearest
24 lights on overflow. `ClusteredLights.activeCount` and `overflowCount` expose
budget saturation. The fixed R32 texture is about 1.7 MB, uploaded once per frame.
There are no per-light draws or render targets.

Optional `LightOccluder` axis-aligned boxes produce simple segment/box shadows.
Each light retains up to four nearby boxes intersecting its radius; boxes
containing the source are excluded. There are no shadow-map updates, cubemaps,
or additional geometry passes. Shadows are approximate: they model submitted
walls/doors, not arbitrary mesh silhouettes, and excess proxies can cause light
leaks. Receivers are offset to limit self-shadow acne. Submit thin wall boxes
and current door bounds for buildings rather than their entire solid volume.

Local illumination is quantized to eight steps per unit with a 4x4 ordered
Bayer dither. RGB components, radius, and intensity are independent.

Beyond derives entrance torches and indoor lamps from saved settlement doors,
so existing towns and cities acquire fixtures without a save-format migration.
`lighting.owl` exposes `torchColor`, `lampColor`, `torchRadius`, `lampRadius`, and
`localIntensity`; existing lighting hot reload applies. The offhand torch also
casts light while equipped and lit. World fixtures flicker with a stable phase.

Validation from Beyond:

```
nim c --path:src --nimcache:build/test-clustered -o:build/test-clustered-bin tests/clustered_lighting.nim
xvfb-run -a env SDL_VIDEODRIVER=x11 SDL_AUDIODRIVER=dummy build/test-clustered-bin
```

The regression checks RGB response, proxy shadows, distant-light rejection,
terrain/sprite integration, the 512-light cap, saturated clusters, and clearing
lights. It saves four diagnostic PNGs under `/tmp/beyond-clustered-*.png`.
