# Static clouds (Godot 4.3+ compositor demo)

Copy this whole folder into your project as `res://cloud_demo/`, reload the project, open
`cloud_demo.tscn` and press Play. Needs the Forward+ or Mobile renderer.

## Files

| File | Purpose |
|---|---|
| `static_cloud_effect.gd` | `CompositorEffect`: bakes the volumes, runs the march + composite every frame |
| `static_cloud_volume.gd` | Low-res CPU copy of the loaded grid, for gameplay queries |
| `static_cloud_cell_override.gd` | Resource: replaces one cell's clouds with painted textures |
| `static_cloud_probe.gd` | Node that reports `OUT / EDGE / IN`, a smoothed `cloudiness` and the raw density. Finds the effect itself |
| `static_cloud_effector.gd` | Node: a sphere that adds cloud or clears cloud locally, live (max 16) |
| `distant_landmark.gd` | Node: keeps a mesh visible at any distance, beyond the camera's far plane |
| `static_cloud_origin_shifter.gd` | Node: floating origin. Moves the world back near the origin and keeps the clouds in step |
| `static_cloud_light.gd` | Node: a point light that lights the clouds from inside (max 6), for lightning / weapon fire |
| `cloud_demo.gd` / `.tscn` | Demo scene (built in code): sky, sun, ground, test boxes, fly camera, HUD |
| `shaders/cloud_noise.comp` | Tileable gradient/worley noise helpers |
| `shaders/cloud_bake_density.glsl` | Generates one grid cell of cloud density from the infinite noise field |
| `shaders/cloud_bake_detail.glsl` | Bakes the 64^3 edge-erosion noise |
| `shaders/cloud_bake_light.glsl` | Bakes sun transmittance, optical depth toward the sun (for multiple scattering) and sky visibility |
| `shaders/cloud_common.comp` | Shared parameter block + depth/ray helpers |
| `shaders/cloud_march.glsl` | Low-res raymarch of the baked volume |
| `shaders/cloud_composite.glsl` | Exact occlusion for surfaces in the layer, depth-aware upsample, hard-edge curve, blend into the scene |

## Using it in your own scene

```gdscript
var effect := StaticCloudEffect.new()
var list: Array[CompositorEffect] = [effect]
var comp := Compositor.new()
comp.compositor_effects = list
$WorldEnvironment.compositor = comp

# keep the lighting in sync with your DirectionalLight3D (+Z of the light points toward the sun)
effect.sun_direction = $Sun.global_transform.basis.z

# gameplay queries
var probe := StaticCloudProbe.new()
probe.effect = effect
$Player.add_child(probe)
probe.state_changed.connect(func(s): print("cloud state: ", s))
```

`probe.cloudiness` (0..1, smoothed) and `probe.state` (`OUT`, `EDGE`, `IN`) are what you read from other scripts.

### Using the probe in your own scene

Just add a `StaticCloudProbe` node (usually under the player or camera). You do not need to assign `effect`: the
probe finds the `StaticCloudEffect` in the current camera's Compositor, then in any WorldEnvironment's Compositor,
by itself. Two things to know:

- **It only has data near the camera.** The gameplay copy covers the 3x3 block of cells around the camera's own
  cell (whatever `grid_radius` is), so a probe on something far from the camera reports "outside the loaded cells" and `OUT`.
- **Check `probe.status` and `probe.data_available`** if it reads zero. Put `probe.status` in a debug label: it says
  whether the effect was found, whether the first cells are still generating, or whether the probe is outside the
  loaded cells. If no effect is found for 3 seconds, a warning is printed.

The gameplay copy is low resolution (`probe_resolution` texels per cell, so `cell_size / probe_resolution` metres
per texel: 333 m with the defaults). Raise `probe_resolution` (up to 128) if you want finer edges, and keep the
probe's `edge_radius` larger than one texel, or EDGE will rarely differ from IN/OUT.
You can also call `effect.cpu_volume.sample(world_pos)` directly.

## Demo controls

Click = capture mouse, Esc = release, WASD move, Q/E down/up, Shift fast, F1 cycle debug view,
B re-bake with a new seed, L tower landmark on/off, M toggle 4x MSAA, `[` `]` coverage, T/G sun elevation,
Y swing the sun 90° (watch the amortized re-bake), U amortized / immediate sun re-bake, N warping on/off, J anvil tops on/off.

## If something looks wrong

1. **Open the Output panel first.** Shader compile errors are printed there with the file name.
2. **F1 debug view 2** shows the reconstructed scene distance (white = 5 km or more / sky). If the ground and
   boxes are not a smooth dark-to-light gradient, depth reconstruction is off: try `depth_source` 1 or 2.
3. **F1 debug view 1** shows cloud alpha, **3** the raw cloud colour.
4. **Clouds ignore geometry / draw over the tower:** the `depth_source` setting above.
5. **Probe says OUT while you are visibly inside cloud (or the HUD says "baking..." forever):** the CPU readback
   failed. Check the Output panel for the byte-count warning. Also check the axis order assumption
   (x fastest, then y, then z) by sampling a known spot.
6. **No clouds at all:** coverage too low, or the camera is far from the slab. Slab is `base_altitude` to
   `base_altitude + thickness` (default 1500 m to 2700 m).

## The streamed world grid (no repetition)

The world is divided into square cells of `cell_size` metres (default 16 km). A block of cells around the camera is
kept loaded (`grid_radius` 1, 2 or 3 gives 3x3, 5x5 or 7x7 cells; default 2), and every cell is generated on the GPU from ONE infinite noise field, sampled at that
cell's own coordinates. Neighbouring cells therefore agree exactly along their shared border, and the pattern
only repeats after tens of thousands of kilometres. (A different random seed per cell would cut the clouds off
at every border, so cells differ by position instead.)

- **Streaming:** when the camera moves into a new cell (past `center_hysteresis`, 10% by default, so crossing a
  border back and forth does not thrash) the block shifts and the newly needed cells are generated, nearest first.
  Generation is spread over frames (`bake_slices_per_frame`), and clouds fade out by the view distance, so
  new cells finish long before they can be seen. A cell that is not ready is simply drawn empty; nothing ever
  shows half-generated data.
- **View distance** is about `grid_radius` cells (`cell_size x (grid_radius - center_hysteresis)`), also capped by
  `max_distance` in the March group, because beyond the loaded block there are no clouds. The defaults give about
  30 km. For 43 km use `grid_radius` 3 and `max_distance` 45000. If far clouds still stop early, raise `max_steps`.

### Rings of detail (less memory, longer view)

Only the cell the camera is in needs full detail. Cells are grouped in rings around it (ring 0 is the camera's
cell, ring 1 the eight around it, and so on), and each ring has fewer texels per cell than the one inside it:

| Setting | Meaning |
|---|---|
| `cell_resolution` (256) | texels across the camera's own cell (voxels of `cell_size / this` metres) |
| `ring_falloff` (2) | each ring out has this many times fewer texels per cell (1 = all the same) |
| `min_cell_resolution` (64) | no ring goes below this |
| `light_cell_resolution` (96), `min_light_resolution` (32) | the same for the baked lighting |
| `lod_fade_time` (1 s) | cross-fade when a cell changes ring |

With the defaults the rings are 256, 128, 64, 64 texels. With the default 1200 m slab, the memory used is about:

| `grid_radius` | Block | View distance | Memory |
|---|---|---|---|
| 1 | 3x3 | ~14 km | ~34 MB |
| 2 (default) | 5x5 | ~30 km | ~45 MB |
| 3 | 7x7 | ~43 km | ~60 MB |

(The old single-resolution 3x3 block used about 59 MB for 14 km.) The demo HUD shows the cloud memory in use, and
`get_memory_mb()` returns it. To save more, raise `ring_falloff` or lower `cell_resolution`.

When the camera moves, cells that change ring are baked again at their new resolution in the background (nearest
first, a few at a time, using spare slots in the atlases) and cross-faded in over `lod_fade_time`, so detail
appears without a visible jump. The old version stays on screen until the new one is complete. All cells sample the
same noise field, so a coarse cell is the same cloud layout with less detail, and the fine erosion noise is applied
in world space at render time, so coarse cells keep their small-scale texture. Each cell has a one-texel border
holding its neighbours' values, so there are no seams at cell borders even between different resolutions.
- **Threading:** generation is GPU compute issued from the render thread, so it never blocks the main thread.
  Textures for overrides given by path load on a background thread (`ResourceLoader` threaded loading) when the
  player is within a cell of the loaded block, and the gameplay copy is read back asynchronously.

## Hand-made cells (overrides)

A `StaticCloudCellOverride` replaces one cell (by `cell` coordinates) with painted textures that cover the cell:

| Texture | Channels |
|---|---|
| `weather_map` | R = coverage (white = cloud), G = type (0 stratus, 0.5 cumulus, 1 towering), B = scale (0 big billows, 1 small puffs) |
| `height_map` | R = cloud-top height (black = very low, white = very high) |

Either can be left empty to keep that channel procedural. Assign textures directly or by path (`weather_map_path`).
Near the cell edge the layout blends back into the procedural clouds over `blend_margin`, so borders stay seamless.

```gdscript
var ov := StaticCloudCellOverride.new()
ov.cell = Vector2i(2, -1)
ov.weather_map_path = "res://clouds/storm_cell.png"   # loaded on a background thread
effect.add_cell_override(ov)          # or add it to effect.cell_overrides in the inspector
```

Cell coordinates are `floor(true position / cell_size)` on X and Z. `effect.get_cell_at(local_position)` tells you the
cell a position is in. If you change an override at runtime, call `effect.refresh_overrides()`. In the demo, the
cell you start in has a painted "storm eye"; press `O` to toggle it.

## Cloud variety (weather)

Four channels drive the procedural clouds (all in the `Weather` and `Heights` groups): **coverage** (where clouds are;
`coverage_softness` makes clear areas and solid banks more or less distinct), **type** (0 flat stratus, 0.5 cumulus,
1 tall towers with flat tops), **scale** (big billows to small puffs) and **height** (how high each cloud top
reaches, very low to very high; `height_variation`, `height_influence`, `top_roughness`). In the demo, press `P`
to cycle through presets.

## Effectors (local dense / empty areas)

Add `StaticCloudEffector` nodes anywhere. `add_density` > 0 creates cloud inside the sphere (even in clear sky),
`clear_amount` > 0 removes it, `radius` and `inner_fraction` set the size and softness. They are live (move them,
animate them) and cost nothing to bake. Up to 16 at once. Not affected: the baked sun shadowing, so an added puff
is lit as if in open sun.

## Lights inside clouds

Add `StaticCloudLight` nodes and animate `energy` (a Tween) for flashes. They light only the cloud volume, with
distance falloff and a 3-sample estimate of the cloud in between, so a flash deep inside a cloud lights its
surroundings but is dimmed by thick cloud around it. `mirror_omni` also creates an OmniLight3D so nearby meshes
are lit. Up to 6 at once; extra lights are ignored. In the demo, press `K` for a lightning flash.

## Fog and the far edge of the clouds

Clouds fade out smoothly between `fade_start_fraction` x `max_distance` and `max_distance` (default 60% to 100%),
so they never end in a hard edge. Distant cloud colour also blends toward `fog_color` (strength `fog_density`).
For a seamless horizon, set `fog_color` to your sky's horizon colour and raise `fog_density` until distant clouds
have mostly taken on that colour by the time they fade out (about `3 / max_distance`, e.g. 0.0001 for 30 km).
If distant cloud still ends abruptly, raise `max_steps` (the march can run out of steps before it reaches the
distance limit on very large open views).

## Floating origin

Far from (0,0,0), float precision makes things jitter. The usual cure is to move the whole world back
when the player strays too far. The clouds must be told, or they would jump. Two ways:

- Add a `StaticCloudOriginShifter` node: set `target` (player or camera), `world_root` (the node containing
  everything, including the target) and `threshold`. It moves `world_root`, calls the effect, and emits `origin_shifted`.
- Or, if your game already shifts the world, call `effect.shift_origin(shift)` with the same shift you applied to
  every node (new position = old position + shift).

The effect keeps the total offset in double precision (`effect.origin_offset`, `effect.get_true_position(p)`), wraps
it to the cloud grid for the shaders, and shifts effector and light slots along with the world. Rigid bodies and any
other absolute positions are your game's responsibility: use the `origin_shifted` signal.

## Meshes that must be visible at any distance (`DistantLandmark`)

Meshes disappear at long range for a few ordinary reasons. Check these first, since they need no code:

- **`Camera3D.far`** (default 4000 m): nothing beyond it is drawn. Raising it is the simplest fix.
- **`Visibility Range End`** on the mesh (GeometryInstance3D > Visibility Range): 0 means unlimited.
- **Mesh LOD**: the importer's "Generate LODs" simplifies meshes with distance; `lod_bias` adjusts it.
- **Occlusion culling**, if you use occluders.
- **The clouds**: they fade out by `get_view_distance()` and hide things behind them, as they should.

When raising `far` is not enough (a landmark at 100 km, 500 km...), add a `DistantLandmark` node at the landmark's TRUE
position and make the mesh (or a whole scene) a child of it. Beyond the park distance (90% of the camera's far plane
by default) the visual is drawn at that distance instead, along the same line of sight, scaled down by the same ratio,
so it looks identical but is always inside the far plane. It stays at its real position and size when closer.

- Keep collisions and gameplay logic on the node itself or elsewhere at the true position; only the visual is swapped.
- Do not animate the visual's own transform (it is rewritten every frame). Animate its children.
- `stay_beyond_clouds` (default on) never parks the visual closer than the cloud view distance, so clouds in front of
  it still hide it and clouds beyond the park distance cannot wrongly cover it.
- **Low-poly stand-in:** assign `far_visual` (a second model under the node, same place and size as `visual`) and set
  `lod_distance`. `visual` is shown closer than that TRUE distance and `far_visual` beyond it, with a small hysteresis
  (`lod_hysteresis`) so it does not flicker. This works at any range, unlike Visibility Range, which only sees the park
  distance once the model is parked. Leave Visibility Range at 0 on both models.
- Read `true_distance`, `is_proxied` and `showing_far` for gameplay (a distance readout, a compass marker).
- Clouds in front of the landmark will hide it, which is correct. A landmark that shows through clouds (a beacon) is a
  different feature.
- Distance haze follows the park distance, not the true distance, so an Environment fog tuned for 54 km will not
  look 120 km deep.

The demo has a low-poly tower 120 km away, beyond the demo camera's 60 km far plane. Press `L` to switch the landmark
off and see it vanish.

## Warping and anvil tops (Warping / Anvil Tops groups)

Both are off by default, so the original look is unchanged until you switch them on. Both are applied when cells are generated, so they cost nothing per frame, and changing them re-generates the cells. Everything still depends only on world position, so neighbouring cells match and nothing repeats.

- **Warping** pushes the noise sample positions around with a second, smooth 3D noise, which gives swirled, torn, wind-blown shapes instead of round blobs.
  - `warp_strength` is the push distance, in base-noise feature widths. Start around 0.3–0.8.
  - `warp_cells` is the swirl size: lower is bigger.
  - `warp_coverage` also warps *where* clouds are, which gives streaky, torn cloud fields.
  - Cell generation costs about 30% more while warping is on.
- **Anvil tops:** towering clouds (type near 1) spread outward and flatten near their tops, like thunderheads. The spread follows each tower's own outline and the column below is left alone, so you get a mushroom silhouette.
  - `anvil_strength` is how far it spreads.
  - `anvil_height` is the fraction of the cloud's height, from the top down, that the anvil occupies.
  - The "Storm towers" preset (P in the demo) shows it best.

In the demo, N toggles warping and J toggles anvil tops.

## Moving the sun (Sun Re-bake group)

With `amortize_sun_rebake` on (the default), changing `sun_direction` at runtime never causes a hitch:

- Only the sun term is recalculated. Sky visibility is kept, which is about half the work.
- The work is spread across frames, about `sun_rebake_slices_per_frame` slices of the camera's cell per frame. That's roughly 0.1–0.3 ms on a GTX 1070 at the default 4.
- A big move is swept across in steps of at most `sun_rebake_step_degrees`. During a step, neighbouring cells differ by at most that angle, which isn't visible.
- New cells are always baked for the current step.

With the defaults, a 90° swing settles in about 400 frames (around 7 seconds at 60 fps). The sun's phase, meaning the glow toward the sun, changes at once; the shadowing follows. Raise the slices per frame to make it faster. Once settled, the result matches an immediate re-bake pixel for pixel. Changing any bake or shape setting still re-lights everything immediately for the current sun. In the demo, Y swings the sun 90° and U switches between amortized and immediate re-baking.

## Multiple scattering (Lighting group)

Sunlight inside a real cloud bounces many times, which is what makes cloud interiors bright and milky, and gives edges facing the sun their silver lining. The light bake stores the optical depth toward the sun. Each march step then adds several scattering "octaves". Octave *n* is dimmed less by the cloud (`scatter_attenuation`^n), adds less light (`scatter_contribution`^n), and uses a less directional phase function (`scatter_eccentricity`^n). Every octave's phase is worked out once per pixel, so the cost is a few `exp()` calls per step.

| Setting | Effect |
|---|---|
| `scatter_octaves` | 0 = the original single-lobe look (for A/B comparison), 1 = single scattering only, 3 = recommended, 4 = max |
| `scatter_attenuation` | Lower = light reaches deeper, so thick cores are brighter |
| `scatter_contribution` | Higher = brighter overall, especially thick cloud |
| `scatter_eccentricity` | Lower = bounced light spreads evenly. Higher = more glow when looking toward the sun |

These settings take effect live, with no re-bake. If clouds look too bright after the change, lower `sun_intensity` a little: with the octaves enabled, more of the sun's light reaches the camera.

## Tuning notes

- **Meshes inside clouds:** any surface lying inside the cloud slab's range (a ship, a mountain) gets an exact
  full-resolution march from the camera to that surface, so it does not depend on the half-res buffer.
  Debug view 4 shows what the shader thinks of each surface: red = cloud alpha over it, green = it is inside the
  cloud slab, blue = it is in front of the cloud.
- **Moire / dither pattern:** `Denoise > denoise_passes` (default 2) blurs the low-res cloud buffer with an edge-aware
  filter. Raise to 3 for more smoothing, 0 to compare. `March > inside_step` (default 60 m) is the largest step
  inside cloud; lower it for smoother surfaces. Cloud entry points are refined with small steps automatically.
- **Banding on very thick clouds:** density is now 16-bit and `auto_vertical_resolution` keeps voxels near
  `target_voxel_height` (30 m) tall as you change `thickness`. Lighting is 16-bit too.

## MSAA

Godot does not give compute shaders write access to the multisampled colour buffer, so the effect handles
MSAA differently: when MSAA is on it switches itself to run after the transparent pass, on the resolved
single-sample image (it follows the MSAA setting automatically, with a frame or two of delay when you toggle).
Trade-offs with MSAA on: transparent objects are drawn before the clouds, so the clouds are composited over
them, and mesh silhouettes get a single depth per pixel, so you may see a faint halo where a mesh edge meets
a cloud. With MSAA off, none of that applies. FXAA / SMAA also work fine with the effect.

## Meshes in clouds

Surfaces inside a cloud are covered by however much cloud lies between the camera and that surface. If a mesh
still looks untouched deep inside a cloud: (1) raise `extinction` (default 0.02; try 0.04-0.06) because thin
clouds are physically see-through, and (2) check the mesh's material. Materials using the **Alpha** transparency
mode are drawn after the clouds and do not write depth, so they always appear on top. Use Alpha Scissor /
Alpha Hash (or Disabled) for anything that should sit inside clouds.

## What is deliberately not in this version

- **Radiance cascades.** Lighting is a baked sun transmittance + a 5-direction sky visibility term. The light bake
  (`cloud_bake_light.glsl`, channel B) is where a cascade pass would plug in.
- **Temporal accumulation.** The march uses interleaved-gradient jitter; expect slight grain at 1/2 resolution.
  Raise `resolution_divisor` quality (1) or add a history buffer.
- **Empty-space skipping** (min/max mips of the density) and a **far-field cubemap**.
- **Grid size:** at most 7x7 cells and 4 ring levels (shaders and uniform layout assume it).
- **Sun shadowing across the grid edge:** baked shadows are computed within the loaded block, so shadows cast from
  beyond it are missing. A cell's lighting is re-baked when a neighbour changes, one cell per frame.
- **Cell changes:** a parameter change (coverage, seed...) re-bakes every cell in the background, nearest first, so
  it takes a few seconds to reach the edge of a 7x7 block.
- Only the first view is handled (no XR / multiview).
