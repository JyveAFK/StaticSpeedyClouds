@tool
class_name StaticCloudEffect
extends CompositorEffect
## Streamed, baked cloud layer rendered as a compositor effect.
##
## World layout
##   The world is split into square cells (cell_size). A block of (2 x grid_radius + 1)^2 cells around the camera
##   is kept loaded, in rings: the camera's own cell at full resolution, each ring further out at a coarser one
##   (cell_resolution, then divided by ring_falloff per ring, down to min_cell_resolution). Far clouds therefore
##   cost little memory, so the view distance can be several cells.
##   Every cell is generated on the GPU, a few slices per frame, from ONE infinite noise field sampled at the
##   cell's own coordinates, so neighbouring cells match along their borders and nothing ever repeats.
##   When the camera moves, cells that change ring are re-generated at the new resolution in the background and
##   cross-faded in, nearest first, so detail appears without a visible jump.
##   Individual cells can be replaced with hand-made layouts (cell_overrides).
##
## Pipeline
##   generate (a few slices per frame, only when needed):
##     cell density -> cell lighting (sun transmittance + sky visibility) -> low-res copy for gameplay queries
##   every frame:
##     march (low-res compute) -> denoise -> composite (exact occlusion for surfaces in the layer,
##     depth-aware upsample, hard edge, blend into scene colour)
##
## Requires Godot 4.3+ (Forward+ or Mobile renderer).

signal baked  ## Emitted on the main thread when the CPU copy of the grid (for density_at) has been refreshed.
signal origin_shifted(shift: Vector3)  ## Emitted by shift_origin().
signal cell_generated(cell: Vector2i)  ## Emitted (main thread) when a cell has finished generating.

const MAX_EFFECTORS := 16
const MAX_LIGHTS := 6
const MAX_LEVELS := 4                  # ring levels (grid_radius 3 -> levels 0..3); fixed by the shaders
const MAX_CELLS := 49                  # 7 x 7 cells, the largest block (grid_radius 3); fixed by the shaders
const PROBE_GRID := 3                  # cells per side of the CPU copy used by StaticCloudProbe
const UBO_BYTES := 224 * 16            # 224 vec4s, see cloud_common.comp
const NOISE_WRAP := 4096               # cell indices wrap here for noise only (tens of thousands of km)
const NO_CELL := Vector2i(2147483647, 2147483647)

const SHADER_DIR := "res://cloud_demo/shaders/"
const CTX := &"static_clouds"

## The most recently created effect. StaticCloudEffector / StaticCloudLight nodes use it when no effect is assigned.
static var active: StaticCloudEffect

# ------------------------------------------------------------------ layer
@export_group("Layer")
## Altitude of the bottom of the cloud layer, in true world coordinates.
@export var base_altitude := 1500.0
@export var thickness := 1200.0: set = _set_thickness
## Extinction per metre at density 1. Higher = denser, darker, more opaque.
@export var extinction := 0.02: set = _set_extinction

@export_group("World Grid")
## World size (m) of one cell. Bigger cells = longer view distance for the same number of rings.
@export var cell_size := 16000.0: set = _set_cell_size
## Rings of cells kept loaded around the camera's cell: 1 = 3x3 cells, 2 = 5x5, 3 = 7x7.
## Clouds are visible out to about grid_radius x cell_size (see also max_distance in March).
@export_range(1, 3) var grid_radius := 2
## Texels across the cell the camera is in (full detail): voxels there are cell_size / this metres wide.
@export_range(64, 512) var cell_resolution := 256
## Each ring further out has this many times fewer texels per cell than the ring inside it (1 = no reduction).
@export_range(1.0, 4.0) var ring_falloff := 2.0
## No ring goes below this many texels per cell.
@export_range(16, 256) var min_cell_resolution := 64
## Derive the vertical resolution from the slab thickness so voxels stay about target_voxel_height tall.
@export var auto_vertical_resolution := true
@export var target_voxel_height := 30.0
## Vertical slices when auto_vertical_resolution is off.
@export_range(8, 192) var vertical_resolution := 48
## Texels across the camera's cell for the baked lighting (coarser rings use fewer, down to min_light_resolution).
@export_range(32, 192) var light_cell_resolution := 96
@export_range(16, 128) var min_light_resolution := 32
## Resolution of the low-res copy used for gameplay queries (StaticCloudProbe).
@export_range(16, 128) var probe_resolution := 48
## The loaded block only re-centres once the camera is this far (fraction of a cell) into the next cell,
## so crossing a border back and forth does not thrash.
@export_range(0.0, 0.4) var center_hysteresis := 0.1
## Seconds to cross-fade a cell from its old resolution to the new one when it changes ring (0 = swap at once).
@export_range(0.0, 5.0) var lod_fade_time := 1.0
## Hand-made layouts for specific cells. See StaticCloudCellOverride.
@export var cell_overrides: Array[StaticCloudCellOverride]: set = _set_cell_overrides
## Z slices generated per frame. Lower = smoother frame rate while cells are generated, but slower.
@export_range(1, 64) var bake_slices_per_frame := 16

@export_group("Bake")
@export_range(0.0, 1.0) var coverage := 0.55: set = _set_coverage
## World seed. Every cell uses it (cells differ because they sample different coordinates).
@export var cloud_seed := 1: set = _set_seed
@export var base_cells := 4: set = _set_base_cells
@export var coverage_cells := 3: set = _set_coverage_cells
## Direction TOWARD the sun (world space). Re-bakes lighting when it changes noticeably (see Sun Re-bake).
@export var sun_direction := Vector3(0.4, 0.6, 0.3): set = _set_sun_direction
## Keep a low-res CPU copy of the grid for gameplay queries (StaticCloudProbe).
@export var cpu_readback := true

@export_group("Sun Re-bake")
## Re-light the clouds gradually when sun_direction changes: a few light slices per frame, sun term only,
## so moving the sun never causes a frame hitch. Off = re-light every loaded cell as fast as possible
## (one whole cell per frame, sun and sky), which is quicker to catch up but can stutter.
@export var amortize_sun_rebake := true: set = _set_amortize_sun_rebake
## Work per frame, measured in slices of the camera's (full-resolution) cell; coarser rings cost less per slice.
## Higher = the lighting catches up with the sun faster, at a higher per-frame cost.
@export_range(1, 32) var sun_rebake_slices_per_frame := 4
## A big sun move is swept across in steps of at most this many degrees. While a step is in progress, cells
## differ by at most this angle, which is not visible; smaller = smoother but slower to arrive.
@export_range(0.5, 30.0) var sun_rebake_step_degrees := 5.0

@export_group("Weather")
## Width of the transition between clear sky and cloud. Small = distinct clear areas and solid cloud banks.
@export_range(0.02, 0.5) var coverage_softness := 0.15: set = _set_coverage_softness
## Noise cells per cell for the type and scale channels.
@export var type_cells := 4: set = _set_type_cells
@export var scale_cells := 5: set = _set_scale_cells
## Cloud type: 0 flat stratus sheets, 0.5 cumulus, 1 tall towering clouds with flat tops.
@export_range(0.0, 1.0) var type_bias := 0.5: set = _set_type_bias
## How much the type varies across the world (0 = the same type everywhere).
@export_range(0.0, 1.0) var type_variation := 0.5: set = _set_type_variation
## Feature size: 0 big billows, 1 small puffs.
@export_range(0.0, 1.0) var scale_bias := 0.3: set = _set_scale_bias
@export_range(0.0, 1.0) var scale_variation := 0.5: set = _set_scale_variation

@export_group("Heights")
## Noise cells per cell for the cloud-top height channel. More = busier tops.
@export var height_cells := 6: set = _set_height_cells
## Middle of the height range: 0 = tops mostly low, 1 = mostly high.
@export_range(0.0, 1.0) var height_bias := 0.5: set = _set_height_bias
## How far tops range around that middle. 0 = all the same height, 1 = from very low to very high.
@export_range(0.0, 1.0) var height_variation := 0.9: set = _set_height_variation
## How strongly the height channel overrides the cloud type's own top height.
@export_range(0.0, 1.0) var height_influence := 0.9: set = _set_height_influence
## Billowing of the tops: 0 = smooth, 1 = very lumpy.
@export_range(0.0, 1.0) var top_roughness := 0.5: set = _set_top_roughness
## Stretches the noise so it reaches the extremes. Higher = more very high and very low tops.
@export_range(1.0, 6.0) var height_contrast := 3.0: set = _set_height_contrast

@export_group("Warping")
## Bends the cloud shapes with a second, smooth noise: swirled, torn, wind-blown shapes instead of round blobs.
## Changing any of these re-generates the cells.
@export var warp_enabled := false: set = _set_warp_enabled
## How far shapes are pushed around, in base-noise feature widths. 0.3 = gentle swirls, 1+ = heavily torn.
@export_range(0.0, 2.0) var warp_strength := 0.6: set = _set_warp_strength
## Size of the swirls (noise cells per cell). Lower = big sweeping distortions, higher = small tight curls.
@export_range(1, 32) var warp_cells := 6: set = _set_warp_cells
## Also warp WHERE the clouds are (the coverage), giving streaky, torn cloud fields. 0 = shapes only.
@export_range(0.0, 1.0) var warp_coverage := 0.0: set = _set_warp_coverage

@export_group("Anvil Tops")
## Towering clouds (type near 1) spread out into flat anvils near their tops, like thunderheads.
## Changing any of these re-generates the cells.
@export var anvil_enabled := false: set = _set_anvil_enabled
## How far the anvil spreads out beyond the tower.
@export_range(0.0, 1.0) var anvil_strength := 0.7: set = _set_anvil_strength
## Fraction of the cloud's height, from the top down, that the anvil occupies.
@export_range(0.05, 0.6) var anvil_height := 0.25: set = _set_anvil_height

@export_group("Lighting")
@export var sun_color := Color(1.0, 0.95, 0.85)
@export var sun_intensity := 3.0
@export var sky_ambient_color := Color(0.45, 0.6, 0.9)
@export var sky_ambient_intensity := 1.0
@export var ground_ambient_color := Color(0.45, 0.48, 0.5)
@export var ground_ambient_intensity := 0.5
@export_range(0.0, 0.99) var forward_g := 0.6
@export_range(-0.99, 0.0) var back_g := -0.25
@export_range(0.0, 1.0) var back_weight := 0.3
@export_range(0.0, 1.0) var powder := 0.4
## Multiple scattering: how many times light is modelled as bouncing inside the cloud. More = brighter, softer,
## milkier interiors and silver-lined edges. 0 = the original single-lobe approximation (for A/B comparison).
@export_range(0, 4) var scatter_octaves := 3
## How much less each bounce is dimmed by the cloud in front of it. Lower = light reaches deeper (brighter cores).
@export_range(0.05, 1.0) var scatter_attenuation := 0.5
## How much each further bounce adds. Higher = brighter overall, especially in thick cloud.
@export_range(0.0, 1.0) var scatter_contribution := 0.5
## How directional each further bounce stays. Lower = bounced light spreads evenly (less sun-facing glow).
@export_range(0.0, 1.0) var scatter_eccentricity := 0.5
@export var fog_color := Color(0.62, 0.74, 0.92)
## Distance fade toward fog_color (per metre).
@export var fog_density := 0.00003

@export_group("March")
@export_range(1, 4) var resolution_divisor := 2
@export_range(16, 256) var max_steps := 192
## Step length (m) at the camera. Steps grow with distance.
@export var near_step := 20.0
@export var step_growth := 0.002
## Largest step (m) while inside cloud. Smaller = smoother surfaces and less banding, but slower.
@export var inside_step := 60.0
## Longest view distance (m). It is also limited to about grid_radius cells (see cell_size and grid_radius),
## because beyond the loaded block there are no clouds; the fade below hides that edge.
## If far clouds are cut off early, raise max_steps too.
@export var max_distance := 30000.0
## Clouds start thinning out at this fraction of the view distance and are gone by the end of it, so they never
## end in a hard edge. Pair with fog_color / fog_density so the distant clouds melt into the horizon.
@export_range(0.0, 0.99) var fade_start_fraction := 0.6
@export_range(0.0, 1.0) var jitter := 1.0
## Re-randomise the march jitter every frame (only useful with TAA).
@export var animate_noise := false

@export_group("Denoise")
## Edge-aware blur passes on the low-res cloud buffer (0 = off). Removes dither / moire patterns.
@export_range(0, 3) var denoise_passes := 2
## Higher = blur respects cloud/object edges more strictly.
@export var denoise_sharpness := 8.0

@export_group("Detail")
@export var detail_tile_size := 600.0
@export_range(0.0, 1.0) var detail_strength := 0.35
@export var detail_fade_start := 1500.0
@export var detail_fade_end := 4000.0

@export_group("Edge")
## Alpha below edge_low is cut, above edge_high is opaque. Set both equal to disable.
@export_range(0.0, 1.0) var edge_low := 0.3
@export_range(0.0, 1.0) var edge_high := 0.7

@export_group("Debug")
## 0 off, 1 cloud alpha, 2 reconstructed scene distance, 3 raw cloud colour,
## 4 per-surface diagnostics (R = cloud alpha over the surface, G = surface is inside the cloud slab, B = surface is in front of the cloud).
@export_range(0, 4) var debug_mode := 0
## How scene distance is reconstructed from the depth buffer. 0 = Godot's own scene-data buffer (default),
## 1 = own projection + reverse-Z, 2 = own projection + standard depth. Try the others if debug view 2 looks wrong.
@export_range(0, 2) var depth_source := 0

## CPU copy of the grid (null until the first cells have been read back). Use density_at() to query it.
var cpu_volume: StaticCloudVolume

# ------------------------------------------------------------------ internals
var rd: RenderingDevice
var _gpu_ready := false
var _regen_all := true          # regenerate every cell of the loaded block (parameters changed)
var _reset_grid := true         # forget the loaded block entirely (cell size changed)
var _light_dirty := true
var _baked_sun := Vector3.ZERO          # the sun direction the light volumes are (being) baked for
var _sun_pass: Array[Vector3i] = []     # amortized sun re-bake: (cell x, cell y, version) still to do
var _sun_pass_z := 0                    # next slice of the first entry
var _frame := 0

# Floating origin. true position = local position + offset. The main-thread copy is used for CPU queries;
# the render-thread copy is updated through the render command queue so it changes on the same frame as the
# node transforms that moved. Doubles, so many shifts never lose precision.
var _ox := 0.0
var _oy := 0.0
var _oz := 0.0
var _r_ox := 0.0
var _r_oy := 0.0
var _r_oz := 0.0

var _density_shader: RID
var _detail_shader: RID
var _light_shader: RID
var _march_shader: RID
var _composite_shader: RID
var _blur_shader: RID
var _density_pipe: RID
var _detail_pipe: RID
var _light_pipe: RID
var _march_pipe: RID
var _composite_pipe: RID
var _blur_pipe: RID

# One state record per loaded cell. A cell can have a shown version (cur) and one being baked (nxt):
# when a cell moves to another ring it is re-baked at the new resolution and cross-faded in.
class CellState:
	var cur_lv := -1          # ring level of the shown version (-1 = nothing to show yet)
	var cur_slot := -1        # its slot in that level's atlas
	var nxt_lv := -1          # version being baked (-1 = none)
	var nxt_slot := -1
	var nxt_z := 0            # density slices done
	var nxt_dens := false     # density finished
	var nxt_lit := false      # lighting finished: ready to be shown
	var fade := 0.0           # 0..1 cross-fade progress (0 = not fading)
	var dirty := false        # parameters changed: needs a fresh bake

# Atlases: one density and one light atlas per ring level. Each holds a pool of slots of (res + 2)^2 texels
# (a one-texel gutter around the cell), laid out in columns x rows.
var _density_tex: Array = []    # RID per level
var _light_tex: Array = []      # RID per level
var _probe_tex: RID             # 3x3 cells, toroidal, no gutter (CPU copy for gameplay queries)
var _detail_tex: RID
var _dummy_tex2d: RID           # 1x1 stand-in when a cell has no painted map
var _atlas_sig: Array = []
var _levels := 0
var _lvl_res := PackedInt32Array()
var _lvl_lres := PackedInt32Array()
var _lvl_cols := PackedInt32Array()
var _lvl_rows := PackedInt32Array()
var _lvl_cap := PackedInt32Array()
var _free: Array = []           # per level: free slot numbers
var _atlas_z := 0
var _light_z := 0
var _probe_res := 0
var _probe_z := 0
var _memory_bytes := 0
var _detail_baked := false

# Streaming state (render thread).
var _grid_valid := false
var _grid_center := Vector2i.ZERO
var _cells := {}                        # Vector2i -> CellState
var _block_sorted: Array[Vector2i] = [] # cells of the loaded block, nearest the centre first
var _light_queue: Array[Vector3i] = []  # (cell x, cell y, 0 = shown version / 1 = incoming version)
var _light_set := {}
var _probe_cell: Array[Vector2i] = []
var _probe_ready := PackedByteArray()
var _probe_dirty := PackedByteArray()
var _pending_probe_read := false
var _baked_once := false
var _ready_count := 0
var _last_tick_us := 0
var _center_published := Vector2i.ZERO  # read by the main thread

# Cell overrides, shared with the render thread.
var _ov_mutex := Mutex.new()
var _ov_map := {}                       # Vector2i -> StaticCloudCellOverride
var _load_requested := {}               # path -> true
var _load_failed_paths := {}            # path -> true

# Effector / light slots. Written on the main thread by StaticCloudEffector / StaticCloudLight nodes and
# read by the render thread when it builds the uniform buffer.
var _eff_data := PackedFloat32Array()   # 8 floats per slot: centre xyz, radius, add, clear, inner, unused
var _eff_used := PackedByteArray()      # slot reserved
var _eff_live := PackedByteArray()      # slot has data and should be rendered
var _lit_data := PackedFloat32Array()   # 8 floats per slot: pos xyz, range, rgb*energy, core
var _lit_used := PackedByteArray()
var _lit_live := PackedByteArray()

var _sampler_vol: RID      # linear, repeat XY, clamp Z
var _sampler_detail: RID   # linear, repeat all
var _sampler_nearest: RID
var _ubo: RID


func _init() -> void:
	active = self
	_eff_data.resize(MAX_EFFECTORS * 8)
	_eff_used.resize(MAX_EFFECTORS)
	_eff_live.resize(MAX_EFFECTORS)
	_lit_data.resize(MAX_LIGHTS * 8)
	_lit_used.resize(MAX_LIGHTS)
	_lit_live.resize(MAX_LIGHTS)
	_probe_cell.resize(PROBE_GRID * PROBE_GRID)
	_probe_cell.fill(NO_CELL)
	_probe_ready.resize(PROBE_GRID * PROBE_GRID)
	_probe_dirty.resize(PROBE_GRID * PROBE_GRID)
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	# With MSAA on, the effect runs after the resolve (POST_TRANSPARENT) on single-sample colour and depth.
	access_resolved_color = true
	access_resolved_depth = true
	RenderingServer.call_on_render_thread(_initialize_gpu)
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		tree.process_frame.connect(_main_tick)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		var rids: Array = [_density_shader, _detail_shader, _light_shader, _march_shader, _composite_shader, _blur_shader,
				_probe_tex, _detail_tex, _dummy_tex2d, _sampler_vol, _sampler_detail, _sampler_nearest, _ubo]
		rids.append_array(_density_tex)
		rids.append_array(_light_tex)
		for rid in rids:
			if rid is RID and rid.is_valid():
				RenderingServer.free_rid(rid)


# ------------------------------------------------------------------ setters (main thread)
func _mark_dirty() -> void:
	_regen_all = true
	_light_dirty = true

func _set_thickness(v: float) -> void:
	thickness = maxf(v, 10.0)
	_mark_dirty()

func _set_cell_size(v: float) -> void:
	cell_size = maxf(v, 500.0)
	_reset_grid = true

func _set_extinction(v: float) -> void:
	extinction = maxf(v, 0.0001)
	_light_dirty = true

func _set_coverage(v: float) -> void:
	coverage = v
	_mark_dirty()

func _set_seed(v: int) -> void:
	cloud_seed = v
	_mark_dirty()

func _set_base_cells(v: int) -> void:
	base_cells = maxi(v, 1)
	_mark_dirty()

func _set_coverage_cells(v: int) -> void:
	coverage_cells = maxi(v, 1)
	_mark_dirty()

func _set_coverage_softness(v: float) -> void:
	coverage_softness = v
	_mark_dirty()

func _set_type_cells(v: int) -> void:
	type_cells = maxi(v, 1)
	_mark_dirty()

func _set_scale_cells(v: int) -> void:
	scale_cells = maxi(v, 1)
	_mark_dirty()

func _set_type_bias(v: float) -> void:
	type_bias = v
	_mark_dirty()

func _set_type_variation(v: float) -> void:
	type_variation = v
	_mark_dirty()

func _set_scale_bias(v: float) -> void:
	scale_bias = v
	_mark_dirty()

func _set_scale_variation(v: float) -> void:
	scale_variation = v
	_mark_dirty()

func _set_height_cells(v: int) -> void:
	height_cells = maxi(v, 1)
	_mark_dirty()

func _set_height_bias(v: float) -> void:
	height_bias = v
	_mark_dirty()

func _set_height_variation(v: float) -> void:
	height_variation = v
	_mark_dirty()

func _set_height_influence(v: float) -> void:
	height_influence = v
	_mark_dirty()

func _set_top_roughness(v: float) -> void:
	top_roughness = v
	_mark_dirty()

func _set_height_contrast(v: float) -> void:
	height_contrast = v
	_mark_dirty()

func _set_sun_direction(v: Vector3) -> void:
	sun_direction = v.normalized() if v.length() > 0.001 else Vector3.UP
	# Amortized: the render thread notices the difference itself and sweeps the lighting across (_step_sun_pass).
	if not amortize_sun_rebake and _baked_sun.angle_to(sun_direction) > 0.02:
		_light_dirty = true

func _set_amortize_sun_rebake(v: bool) -> void:
	amortize_sun_rebake = v
	if not v and _baked_sun.angle_to(sun_direction) > 0.02:
		_light_dirty = true

func _set_warp_enabled(v: bool) -> void:
	warp_enabled = v
	_mark_dirty()

func _set_warp_strength(v: float) -> void:
	warp_strength = v
	_mark_dirty()

func _set_warp_cells(v: int) -> void:
	warp_cells = maxi(v, 1)
	_mark_dirty()

func _set_warp_coverage(v: float) -> void:
	warp_coverage = v
	_mark_dirty()

func _set_anvil_enabled(v: bool) -> void:
	anvil_enabled = v
	_mark_dirty()

func _set_anvil_strength(v: float) -> void:
	anvil_strength = v
	_mark_dirty()

func _set_anvil_height(v: float) -> void:
	anvil_height = v
	_mark_dirty()

func _set_cell_overrides(v: Array[StaticCloudCellOverride]) -> void:
	cell_overrides = v
	refresh_overrides()


## Force every loaded cell to be regenerated (density, lighting and CPU copy).
func request_rebake() -> void:
	_mark_dirty()


# ------------------------------------------------------------------ cell overrides (main thread)
## Replace the clouds of one cell with a hand-made layout. Replaces any existing override for that cell.
func add_cell_override(ov: StaticCloudCellOverride) -> void:
	remove_cell_override(ov.cell)
	cell_overrides.append(ov)
	refresh_overrides()

func remove_cell_override(cell: Vector2i) -> void:
	for existing in cell_overrides:
		if existing != null and existing.cell == cell:
			cell_overrides.erase(existing)
			break
	refresh_overrides()

## Call after editing an override's fields at runtime (the inspector array calls it for you).
func refresh_overrides() -> void:
	_ov_mutex.lock()
	_ov_map.clear()
	for ov in cell_overrides:
		if ov != null and ov.enabled:
			_ov_map[ov.cell] = ov
	_ov_mutex.unlock()
	_regen_all = true
	_light_dirty = true

func _get_override(cell: Vector2i) -> StaticCloudCellOverride:
	_ov_mutex.lock()
	var ov: StaticCloudCellOverride = _ov_map.get(cell)
	_ov_mutex.unlock()
	return ov

## Main-thread tick: starts and polls background loading of override textures that are given by path,
## for overrides within a cell of the loaded block, so they are ready by the time the cell is generated.
func _main_tick() -> void:
	if cell_overrides.is_empty():
		return
	var c := _center_published
	for ov in cell_overrides:
		if ov == null or not ov.enabled:
			continue
		if maxi(absi(ov.cell.x - c.x), absi(ov.cell.y - c.y)) > grid_radius + 1:
			continue
		if ov.weather_map == null and ov.weather_map_path != "" and not ov.weather_failed:
			var t := _poll_texture(ov.weather_map_path)
			if t != null:
				ov.weather_map = t
			elif _load_failed_paths.has(ov.weather_map_path):
				ov.weather_failed = true
				push_warning("StaticCloudEffect: could not load %s" % ov.weather_map_path)
		if ov.height_map == null and ov.height_map_path != "" and not ov.height_failed:
			var t2 := _poll_texture(ov.height_map_path)
			if t2 != null:
				ov.height_map = t2
			elif _load_failed_paths.has(ov.height_map_path):
				ov.height_failed = true
				push_warning("StaticCloudEffect: could not load %s" % ov.height_map_path)

func _poll_texture(path: String) -> Texture2D:
	if ResourceLoader.has_cached(path):
		return load(path) as Texture2D
	if not _load_requested.has(path):
		_load_requested[path] = true
		ResourceLoader.load_threaded_request(path, "Texture2D")
		return null
	match ResourceLoader.load_threaded_get_status(path):
		ResourceLoader.THREAD_LOAD_LOADED:
			return ResourceLoader.load_threaded_get(path) as Texture2D
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_load_failed_paths[path] = true
	return null


# ------------------------------------------------------------------ effectors / lights API (main thread)
## Reserve a slot for a local density modifier. Returns -1 if all MAX_EFFECTORS slots are taken.
func acquire_effector() -> int:
	for i in MAX_EFFECTORS:
		if _eff_used[i] == 0:
			_eff_used[i] = 1
			_eff_live[i] = 0
			return i
	return -1

## Update a modifier. add_density 0..1 creates cloud in the sphere; clear_amount 0..1 removes it.
func set_effector(slot: int, pos: Vector3, radius: float, add_density: float, clear_amount: float, inner_fraction: float) -> void:
	if slot < 0 or slot >= MAX_EFFECTORS:
		return
	var o := slot * 8
	_eff_data[o] = pos.x
	_eff_data[o + 1] = pos.y
	_eff_data[o + 2] = pos.z
	_eff_data[o + 3] = maxf(radius, 1.0)
	_eff_data[o + 4] = clampf(add_density, 0.0, 1.0)
	_eff_data[o + 5] = clampf(clear_amount, 0.0, 1.0)
	_eff_data[o + 6] = clampf(inner_fraction, 0.0, 0.99)
	_eff_live[slot] = 1

func release_effector(slot: int) -> void:
	if slot >= 0 and slot < MAX_EFFECTORS:
		_eff_used[slot] = 0
		_eff_live[slot] = 0

## Reserve a slot for a light inside the clouds. Returns -1 if all MAX_LIGHTS slots are taken.
func acquire_light() -> int:
	for i in MAX_LIGHTS:
		if _lit_used[i] == 0:
			_lit_used[i] = 1
			_lit_live[i] = 0
			return i
	return -1

func set_light(slot: int, pos: Vector3, light_range: float, color: Color, energy: float, core_radius: float) -> void:
	if slot < 0 or slot >= MAX_LIGHTS:
		return
	var o := slot * 8
	_lit_data[o] = pos.x
	_lit_data[o + 1] = pos.y
	_lit_data[o + 2] = pos.z
	_lit_data[o + 3] = maxf(light_range, 1.0)
	_lit_data[o + 4] = color.r * energy
	_lit_data[o + 5] = color.g * energy
	_lit_data[o + 6] = color.b * energy
	_lit_data[o + 7] = maxf(core_radius, 1.0)
	_lit_live[slot] = 1 if energy > 0.001 else 0

func release_light(slot: int) -> void:
	if slot >= 0 and slot < MAX_LIGHTS:
		_lit_used[slot] = 0
		_lit_live[slot] = 0


# ------------------------------------------------------------------ floating origin (main thread)
## Offset between local and true world coordinates: true position = local position + origin_offset.
var origin_offset: Vector3:
	get:
		return Vector3(_ox, _oy, _oz)

## Call this whenever you move the whole world by `shift` to bring the player back near the origin
## (every node's new position = old position + shift). The clouds stay where they were in the true world.
## StaticCloudOriginShifter does this for you. Effector and light slots are shifted along with the world.
func shift_origin(shift: Vector3) -> void:
	_ox -= shift.x
	_oy -= shift.y
	_oz -= shift.z
	for i in MAX_EFFECTORS:
		if _eff_live[i] == 1:
			_eff_data[i * 8] += shift.x
			_eff_data[i * 8 + 1] += shift.y
			_eff_data[i * 8 + 2] += shift.z
	for i in MAX_LIGHTS:
		if _lit_live[i] == 1:
			_lit_data[i * 8] += shift.x
			_lit_data[i * 8 + 1] += shift.y
			_lit_data[i * 8 + 2] += shift.z
	RenderingServer.call_on_render_thread(_apply_render_offset.bind(_ox, _oy, _oz))
	origin_shifted.emit(shift)

## Set the offset directly (for example when loading a saved game, or to start in a chosen cell).
func set_origin_offset(offset: Vector3) -> void:
	_ox = offset.x
	_oy = offset.y
	_oz = offset.z
	RenderingServer.call_on_render_thread(_apply_render_offset.bind(_ox, _oy, _oz))

## Local position -> true world position (useful for saving or for position readouts).
func get_true_position(local: Vector3) -> Vector3:
	return Vector3(local.x + _ox, local.y + _oy, local.z + _oz)

func _apply_render_offset(x: float, y: float, z: float) -> void:
	_r_ox = x
	_r_oy = y
	_r_oz = z


# ------------------------------------------------------------------ queries (main thread)
## The cell the loaded block is currently centred on.
func get_center_cell() -> Vector2i:
	return _center_published

## The cell containing a local position.
func get_cell_at(local: Vector3) -> Vector2i:
	return Vector2i(floori((local.x + _ox) / cell_size), floori((local.z + _oz) / cell_size))

## How many of the loaded cells are generated, lit and drawn (see get_grid_cell_count for the total).
func get_ready_cell_count() -> int:
	return _ready_count

## How many cells the loaded block holds: 9, 25 or 49.
func get_grid_cell_count() -> int:
	var n := grid_radius * 2 + 1
	return n * n

## Video memory used by the cloud atlases (density, light and the gameplay copy), in megabytes.
func get_memory_mb() -> float:
	return float(_memory_bytes) / 1048576.0

## True if a local position lies in a loaded, generated cell, i.e. where density_at() has real data.
func is_loaded_at(p: Vector3) -> bool:
	return cpu_volume != null and cpu_volume.is_loaded(p.x + _ox, p.z + _oz)

## Cloud density (0..1) at a local position: the generated field plus any active effectors.
## Used by StaticCloudProbe. Returns 0 until the first cells have been read back, and in cells not loaded.
func density_at(p: Vector3) -> float:
	if cpu_volume == null or not cpu_volume.is_valid():
		return 0.0
	var d := cpu_volume.sample_true(p.x + _ox, p.y + _oy, p.z + _oz)
	for i in MAX_EFFECTORS:
		if _eff_live[i] == 1:
			var o := i * 8
			var radius := _eff_data[o + 3]
			var dist := p.distance_to(Vector3(_eff_data[o], _eff_data[o + 1], _eff_data[o + 2]))
			var f := 1.0 - smoothstep(radius * _eff_data[o + 6], radius, dist)
			d = d * (1.0 - _eff_data[o + 5] * f) + _eff_data[o + 4] * f
	return clampf(d, 0.0, 1.0)


# ------------------------------------------------------------------ GPU setup (render thread)
func _load_shader(file_name: String) -> RID:
	var file := load(SHADER_DIR + file_name) as RDShaderFile
	if file == null:
		push_error("StaticCloudEffect: could not load %s" % file_name)
		return RID()
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("StaticCloudEffect: %s failed to compile:\n%s" % [file_name, spirv.compile_error_compute])
		return RID()
	return rd.shader_create_from_spirv(spirv)


func _initialize_gpu() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		return

	_density_shader = _load_shader("cloud_bake_density.glsl")
	_detail_shader = _load_shader("cloud_bake_detail.glsl")
	_light_shader = _load_shader("cloud_bake_light.glsl")
	_march_shader = _load_shader("cloud_march.glsl")
	_composite_shader = _load_shader("cloud_composite.glsl")
	_blur_shader = _load_shader("cloud_blur.glsl")
	for s in [_density_shader, _detail_shader, _light_shader, _march_shader, _composite_shader, _blur_shader]:
		if not (s as RID).is_valid():
			return

	_density_pipe = rd.compute_pipeline_create(_density_shader)
	_detail_pipe = rd.compute_pipeline_create(_detail_shader)
	_light_pipe = rd.compute_pipeline_create(_light_shader)
	_march_pipe = rd.compute_pipeline_create(_march_shader)
	_composite_pipe = rd.compute_pipeline_create(_composite_shader)
	_blur_pipe = rd.compute_pipeline_create(_blur_shader)

	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	ss.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler_vol = rd.sampler_create(ss)

	var sd := RDSamplerState.new()
	sd.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sd.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sd.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sd.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sd.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_sampler_detail = rd.sampler_create(sd)

	var sn := RDSamplerState.new()
	sn.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sn.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sn.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sn.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sn.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler_nearest = rd.sampler_create(sn)

	var df := RDTextureFormat.new()
	df.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	df.width = 1
	df.height = 1
	df.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_dummy_tex2d = rd.texture_create(df, RDTextureView.new(), [PackedByteArray([128, 128, 128, 255])])

	var empty := PackedByteArray()
	empty.resize(UBO_BYTES)  # filled every frame
	_ubo = rd.uniform_buffer_create(empty.size(), empty)

	_gpu_ready = true


func _make_tex3d(size: Vector3i, format: RenderingDevice.DataFormat) -> RID:
	var f := RDTextureFormat.new()
	f.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	f.format = format
	f.width = size.x
	f.height = size.y
	f.depth = size.z
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return rd.texture_create(f, RDTextureView.new())


func _set_callback_type(t: EffectCallbackType) -> void:
	effect_callback_type = t


# ------------------------------------------------------------------ uniform helpers
func _u_image(binding: int, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(tex)
	return u

func _u_sampled(binding: int, sampler: RID, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(sampler)
	u.add_id(tex)
	return u

func _u_ubo(binding: int, buf: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u

func _dispatch(pipe: RID, uniform_set: RID, pc: PackedByteArray, gx: int, gy: int, gz: int) -> void:
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipe)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	if pc.size() > 0:
		rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, gx, gy, gz)
	rd.compute_list_end()


# ------------------------------------------------------------------ atlases (render thread)
func _effective_z() -> int:
	if auto_vertical_resolution:
		return clampi(ceili(thickness / maxf(target_voxel_height, 1.0)), 16, 192)
	return maxi(vertical_resolution, 8)


func _grid_n() -> int:
	return grid_radius * 2 + 1


func _ring_count(k: int) -> int:
	return 1 if k == 0 else 8 * k


func _level_res(k: int) -> int:
	var r := roundi(float(cell_resolution) / pow(ring_falloff, float(k)))
	return mini(cell_resolution, maxi(min_cell_resolution, r))


func _level_light_res(k: int) -> int:
	var r := roundi(float(light_cell_resolution) / pow(ring_falloff, float(k)))
	return mini(light_cell_resolution, maxi(min_light_resolution, r))


func _slot_col(k: int, slot: int) -> int:
	return slot % _lvl_cols[k]


func _slot_row(k: int, slot: int) -> int:
	return floori(float(slot) / float(_lvl_cols[k]))


func _free_level_textures() -> void:
	for rid in _density_tex:
		if (rid as RID).is_valid():
			rd.free_rid(rid)
	for rid in _light_tex:
		if (rid as RID).is_valid():
			rd.free_rid(rid)
	_density_tex.clear()
	_light_tex.clear()
	if _probe_tex.is_valid():
		rd.free_rid(_probe_tex)
		_probe_tex = RID()


func _ensure_atlases() -> void:
	var z := _effective_z()
	var sig := [grid_radius, cell_resolution, ring_falloff, min_cell_resolution, light_cell_resolution,
		min_light_resolution, probe_resolution, z]
	if not _density_tex.is_empty() and sig == _atlas_sig:
		return
	_free_level_textures()
	_atlas_sig = sig
	_levels = grid_radius + 1
	_atlas_z = z
	_light_z = clampi(ceili(z / 2.0), 8, 96)
	_probe_res = probe_resolution
	_probe_z = mini(z, 32)
	_lvl_res.resize(_levels)
	_lvl_lres.resize(_levels)
	_lvl_cols.resize(_levels)
	_lvl_rows.resize(_levels)
	_lvl_cap.resize(_levels)
	_memory_bytes = 0
	for k in _levels:
		var res := _level_res(k)
		var lres := _level_light_res(k)
		# Slots: one per cell of the ring, plus a few spare so a cell can be re-baked at a new resolution
		# while its old version is still shown.
		var cap := _ring_count(k) + (1 if k == 0 else 2)
		var cols := ceili(sqrt(float(cap)))
		var rows := ceili(float(cap) / float(cols))
		_lvl_res[k] = res
		_lvl_lres[k] = lres
		_lvl_cols[k] = cols
		_lvl_rows[k] = rows
		_lvl_cap[k] = cap
		var dw := cols * (res + 2)
		var dh := rows * (res + 2)
		var lw := cols * (lres + 2)
		var lh := rows * (lres + 2)
		_density_tex.append(_make_tex3d(Vector3i(dw, dh, _atlas_z), RenderingDevice.DATA_FORMAT_R16_SFLOAT))
		_light_tex.append(_make_tex3d(Vector3i(lw, lh, _light_z), RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT))
		_memory_bytes += dw * dh * _atlas_z * 2 + lw * lh * _light_z * 8
	_probe_tex = _make_tex3d(Vector3i(PROBE_GRID * _probe_res, PROBE_GRID * _probe_res, _probe_z), RenderingDevice.DATA_FORMAT_R16_SFLOAT)
	_memory_bytes += PROBE_GRID * _probe_res * PROBE_GRID * _probe_res * _probe_z * 2
	if not _detail_tex.is_valid():
		_detail_tex = _make_tex3d(Vector3i(64, 64, 64), RenderingDevice.DATA_FORMAT_R8_UNORM)
		_detail_baked = false
	_reset_grid_state()


func _reset_grid_state() -> void:
	_grid_valid = false
	_cells.clear()
	_block_sorted.clear()
	_light_queue.clear()
	_light_set.clear()
	_free.clear()
	for k in _levels:
		var slots: Array = []
		for sl in _lvl_cap[k]:
			slots.append(sl)
		_free.append(slots)
	for i in PROBE_GRID * PROBE_GRID:
		_probe_cell[i] = NO_CELL
		_probe_ready[i] = 0
		_probe_dirty[i] = 0
	_baked_once = false
	_pending_probe_read = false
	_ready_count = 0


# ------------------------------------------------------------------ streaming (render thread)
## How far (m) the clouds are drawn: about grid_radius cells, limited by max_distance. Beyond it the sky has no clouds.
func get_view_distance() -> float:
	return _view_distance()


func _view_distance() -> float:
	# The camera can be up to (0.5 + hysteresis) cells from the middle of the centre cell, and the block reaches
	# grid_radius + 0.5 cells from it, so this much cloud is always loaded in every direction.
	return minf(max_distance, cell_size * (float(grid_radius) - center_hysteresis))


func _ring_of(cell: Vector2i) -> int:
	return maxi(absi(cell.x - _grid_center.x), absi(cell.y - _grid_center.y))


func _alloc_slot(k: int) -> int:
	var f: Array = _free[k]
	if f.is_empty():
		return -1
	return int(f.pop_front())


func _free_slot(k: int, slot: int) -> void:
	if slot >= 0 and k >= 0 and k < _free.size():
		(_free[k] as Array).append(slot)


func _release_cell(cell: Vector2i) -> void:
	var st: CellState = _cells[cell]
	_free_slot(st.cur_lv, st.cur_slot)
	_free_slot(st.nxt_lv, st.nxt_slot)
	_cells.erase(cell)


func _enter_center() -> void:
	_center_published = _grid_center
	var r := grid_radius
	var block: Array[Vector2i] = []
	for b in range(-r, r + 1):
		for a in range(-r, r + 1):
			block.append(_grid_center + Vector2i(a, b))
	var c := _grid_center
	block.sort_custom(func(p: Vector2i, q: Vector2i) -> bool: return (p - c).length_squared() < (q - c).length_squared())
	_block_sorted = block
	var keep := {}
	for cell in block:
		keep[cell] = true
		if not _cells.has(cell):
			_cells[cell] = CellState.new()
	for cell in _cells.keys():
		if not keep.has(cell):
			_release_cell(cell)


## Parameters changed: every cell needs a fresh bake (cells being baked restart).
func _mark_all_dirty() -> void:
	for cell in _cells:
		var st: CellState = _cells[cell]
		if st.nxt_lv >= 0:
			st.nxt_z = 0
			st.nxt_dens = false
			st.nxt_lit = false
			st.fade = 0.0
		else:
			st.dirty = true


## Starts a bake (into a free slot) for every cell whose shown version is at the wrong ring level or out of date.
## Nearest cells first, so the camera's own cell is upgraded before anything else.
func _schedule() -> void:
	for cell in _block_sorted:
		var st: CellState = _cells.get(cell)
		if st == null:
			continue
		var want := _ring_of(cell)
		if st.nxt_lv >= 0:
			if st.nxt_lv == want:
				continue
			# The camera moved on while this was baking: drop it and start again at the right level.
			_free_slot(st.nxt_lv, st.nxt_slot)
			st.nxt_lv = -1
			st.nxt_slot = -1
			st.nxt_z = 0
			st.nxt_dens = false
			st.nxt_lit = false
			st.fade = 0.0
		if st.cur_lv == want and not st.dirty:
			continue
		var slot := _alloc_slot(want)
		if slot < 0:
			continue  # no free slot at that level yet; try again next frame
		st.nxt_lv = want
		st.nxt_slot = slot
		st.nxt_z = 0
		st.nxt_dens = false
		st.nxt_lit = false
		st.fade = 0.0
		st.dirty = false


func _update_streaming(cam_local: Vector3) -> void:
	if _reset_grid:
		_reset_grid = false
		_reset_grid_state()
	if not _detail_baked:
		var pc := PackedFloat32Array([64, 64, 64, float(cloud_seed) + 17.0, 4.0, 0.0, 0.0, 0.0]).to_byte_array()
		var set_rid := UniformSetCacheRD.get_cache(_detail_shader, 0, [_u_image(0, _detail_tex)])
		_dispatch(_detail_pipe, set_rid, pc, 8, 8, 16)
		_detail_baked = true

	var fx := (cam_local.x + _r_ox) / cell_size
	var fz := (cam_local.z + _r_oz) / cell_size
	if not _grid_valid:
		_grid_center = Vector2i(floori(fx), floori(fz))
		_grid_valid = true
		_enter_center()
	else:
		var limit := 0.5 + center_hysteresis
		if absf(fx - (_grid_center.x + 0.5)) > limit or absf(fz - (_grid_center.y + 0.5)) > limit:
			_grid_center = Vector2i(floori(fx), floori(fz))
			_enter_center()

	if _regen_all:
		_regen_all = false
		_light_dirty = true
		_mark_all_dirty()
		_probe_dirty.fill(1)

	_schedule()
	_process_jobs()
	if cpu_readback:
		_update_probe()
	if _light_dirty:
		# a full re-light: every cell goes straight to the current sun
		_light_dirty = false
		_baked_sun = sun_direction.normalized()
		_sun_pass.clear()
		_sun_pass_z = 0
		_queue_all_light()


## Generates a few slices of the nearest cell that is waiting for density.
func _process_jobs() -> void:
	for cell in _block_sorted:
		var st: CellState = _cells.get(cell)
		if st == null or st.nxt_lv < 0 or st.nxt_dens:
			continue
		var ov := _get_override(cell)
		if ov != null and not ov.is_ready():
			continue  # its textures are still loading on the background thread: let other cells go first
		var n := mini(bake_slices_per_frame, _atlas_z - st.nxt_z)
		var slot_xy := Vector2i(_slot_col(st.nxt_lv, st.nxt_slot), _slot_row(st.nxt_lv, st.nxt_slot))
		_dispatch_density(_density_tex[st.nxt_lv], _lvl_res[st.nxt_lv], cell, slot_xy, st.nxt_z, n, ov, 1)
		st.nxt_z += n
		if st.nxt_z >= _atlas_z:
			st.nxt_dens = true
			_queue_light(cell, 1, true)
			_queue_light_around(cell)
			call_deferred("_emit_cell_generated", cell)
		return


func _emit_cell_generated(cell: Vector2i) -> void:
	cell_generated.emit(cell)


## Generates part of one cell (z_count slices from z_off) into its slot of an atlas texture.
## gutter = 1 adds a one-texel border on every side (the atlases the renderer samples); 0 for the gameplay copy.
func _dispatch_density(tex: RID, res: int, cell: Vector2i, slot_xy: Vector2i, z_off: int, z_count: int, ov: StaticCloudCellOverride, gutter: int) -> void:
	var weather_rd := _dummy_tex2d
	var height_rd := _dummy_tex2d
	var use_weather := 0.0
	var use_height := 0.0
	var blend := 0.0
	if ov != null:
		blend = ov.blend_margin
		if ov.weather_map != null:
			var w_rid := RenderingServer.texture_get_rd_texture(ov.weather_map.get_rid())
			if w_rid.is_valid():
				weather_rd = w_rid
				use_weather = 1.0
		if ov.height_map != null:
			var h_rid := RenderingServer.texture_get_rd_texture(ov.height_map.get_rid())
			if h_rid.is_valid():
				height_rd = h_rid
				use_height = 1.0
	var pc := PackedFloat32Array([
		float(posmod(cell.x, NOISE_WRAP)), float(posmod(cell.y, NOISE_WRAP)), float(slot_xy.x), float(slot_xy.y),
		coverage, float(base_cells), float(coverage_cells), coverage_softness,
		cell_size, thickness, blend, float(z_off),
		float(type_cells), float(scale_cells), type_bias, type_variation,
		scale_bias, scale_variation, use_weather, float(cloud_seed),
		float(height_cells), height_bias, height_variation, height_influence,
		top_roughness, height_contrast, use_height, float(res),
		float(gutter), _warp_packed_strength(), _warp_packed_cells(), _anvil_packed(),
	]).to_byte_array()
	var set_rid := UniformSetCacheRD.get_cache(_density_shader, 0, [
		_u_image(0, tex),
		_u_sampled(1, _sampler_vol, weather_rd),
		_u_sampled(2, _sampler_vol, height_rd),
	])
	var groups := ceili(float(res + 2 * gutter) / 8.0)
	_dispatch(_density_pipe, set_rid, pc, groups, groups, ceili(z_count / 4.0))


# Shape modifiers share the last push-constant vec4 with the gutter, so two values are packed into one float:
# integer part + fraction * 0.99 (the shader unpacks with floor / fract).
func _warp_packed_strength() -> float:
	return warp_strength if warp_enabled else 0.0

func _warp_packed_cells() -> float:
	return float(maxi(warp_cells, 1)) + clampf(warp_coverage, 0.0, 1.0) * 0.99

func _anvil_packed() -> float:
	if not anvil_enabled:
		return 0.0
	return float(clampi(roundi(anvil_height * 100.0), 2, 90)) + clampf(anvil_strength, 0.0, 1.0) * 0.99


## Keeps the 3x3 low-res copy around the camera's cell up to date (for StaticCloudProbe).
func _update_probe() -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var cell := _grid_center + Vector2i(dx, dy)
			var s := posmod(cell.x, PROBE_GRID) + posmod(cell.y, PROBE_GRID) * PROBE_GRID
			if _probe_cell[s] != cell:
				_probe_cell[s] = cell
				_probe_ready[s] = 0
				_probe_dirty[s] = 1
			if _probe_ready[s] == 1 and _probe_dirty[s] == 0:
				continue
			var ov := _get_override(cell)
			if ov != null and not ov.is_ready():
				continue
			var slot_xy := Vector2i(s % PROBE_GRID, floori(float(s) / float(PROBE_GRID)))
			_dispatch_density(_probe_tex, _probe_res, cell, slot_xy, 0, _probe_z, ov, 0)
			_probe_ready[s] = 1
			_probe_dirty[s] = 0
			_pending_probe_read = true


# ------------------------------------------------------------------ lighting (render thread)
func _queue_light(cell: Vector2i, version: int, front: bool) -> void:
	var key := Vector3i(cell.x, cell.y, version)
	if _light_set.has(key):
		return
	_light_set[key] = true
	if front:
		_light_queue.push_front(key)
	else:
		_light_queue.push_back(key)


## A cell just got new density: it and its neighbours need their lighting (re)baked, because shadows cross borders.
func _queue_light_around(cell: Vector2i) -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var c2 := cell + Vector2i(dx, dy)
			var st: CellState = _cells.get(c2)
			if st == null:
				continue
			if st.cur_lv >= 0:
				_queue_light(c2, 0, false)
			if st.nxt_dens and c2 != cell:
				_queue_light(c2, 1, false)


func _queue_all_light() -> void:
	for cell in _block_sorted:
		var st: CellState = _cells.get(cell)
		if st == null:
			continue
		if st.nxt_dens:
			_queue_light(cell, 1, false)
		if st.cur_lv >= 0:
			_queue_light(cell, 0, false)


## Bakes lighting for one cell version per frame. Uses the uniform buffer, so it runs after _build_ubo().
func _process_light() -> void:
	while not _light_queue.is_empty():
		var key: Vector3i = _light_queue.pop_front()
		_light_set.erase(key)
		var cell := Vector2i(key.x, key.y)
		var st: CellState = _cells.get(cell)
		if st == null:
			continue
		var lv := -1
		var slot := -1
		if key.z == 0:
			lv = st.cur_lv
			slot = st.cur_slot
		elif st.nxt_dens:
			lv = st.nxt_lv
			slot = st.nxt_slot
		if lv < 0 or slot < 0:
			continue
		_dispatch_light(cell, lv, slot)
		if key.z == 1:
			st.nxt_lit = true
		return


## Amortized sun re-bake. When the sun has moved away from the direction the lighting was baked for, the baked
## direction steps toward it by at most sun_rebake_step_degrees and every loaded cell is re-lit for that step,
## a few slices per frame and the sun term only. When the pass is done the next step starts, until it arrives.
## Runs on the render thread after _process_light(); new cells meanwhile are baked straight for the current step.
func _step_sun_pass() -> void:
	if _sun_pass.is_empty():
		var target := sun_direction.normalized()
		if _baked_sun.length() < 0.5:
			_baked_sun = target
			return
		var ang := _baked_sun.angle_to(target)
		if ang < 0.002:
			return
		var step := deg_to_rad(sun_rebake_step_degrees)
		_baked_sun = target if ang <= step else _baked_sun.slerp(target, step / ang).normalized()
		for cell in _block_sorted:
			var st: CellState = _cells.get(cell)
			if st == null:
				continue
			if st.cur_lv >= 0:
				_sun_pass.append(Vector3i(cell.x, cell.y, 0))
			if st.nxt_dens and st.nxt_lit:
				_sun_pass.append(Vector3i(cell.x, cell.y, 1))
		_sun_pass_z = 0
	if _sun_pass.is_empty() or _levels <= 0:
		return
	# Budget in texels so a coarse ring cell (fewer texels per slice) gets proportionally more slices.
	var full_stride := _lvl_lres[0] + 2
	var budget := sun_rebake_slices_per_frame * full_stride * full_stride
	while budget > 0 and not _sun_pass.is_empty():
		var key: Vector3i = _sun_pass[0]
		var st: CellState = _cells.get(Vector2i(key.x, key.y))
		var lv := -1
		var slot := -1
		if st != null:
			if key.z == 0:
				lv = st.cur_lv
				slot = st.cur_slot
			elif st.nxt_dens and st.nxt_lit:
				lv = st.nxt_lv
				slot = st.nxt_slot
		if lv < 0 or slot < 0:
			_sun_pass.pop_front()  # gone, or swapped / unloaded since the pass started
			_sun_pass_z = 0
			continue
		var stride := _lvl_lres[lv] + 2
		var n := clampi(budget / (stride * stride), 1, _light_z - _sun_pass_z)
		_dispatch_light(Vector2i(key.x, key.y), lv, slot, _sun_pass_z, n, true)
		budget -= n * stride * stride
		_sun_pass_z += n
		if _sun_pass_z >= _light_z:
			_sun_pass.pop_front()
			_sun_pass_z = 0


func _dispatch_light(cell: Vector2i, lv: int, slot: int, z_off := 0, z_count := -1, sun_only := false) -> void:
	if _baked_sun.length() < 0.5:
		_baked_sun = sun_direction.normalized()
	var sun := _baked_sun
	if z_count < 0:
		z_count = _light_z
	var sun_steps := 32.0
	var path_len := thickness / maxf(absf(sun.y), 0.15)
	var sun_step := path_len / sun_steps
	var amb_steps := 6.0
	var amb_step := thickness / amb_steps
	var lres := _lvl_lres[lv]
	var rel := cell - (_grid_center - Vector2i(grid_radius, grid_radius))
	var pc := PackedFloat32Array([
		float(rel.x), float(rel.y), float(lres), float(z_off),
		float(_slot_col(lv, slot)), float(_slot_row(lv, slot)), sun_steps, amb_steps,
		sun.x, sun.y, sun.z, extinction,
		sun_step, amb_step, 1.0 if sun_only else 0.0, 0.0,
	]).to_byte_array()
	var uniforms: Array[RDUniform] = [_u_ubo(0, _ubo), _u_image(1, _light_tex[lv])]
	uniforms.append_array(_level_uniforms(8, _density_tex))
	var set_rid := UniformSetCacheRD.get_cache(_light_shader, 0, uniforms)
	var groups := ceili(float(lres + 2) / 8.0)
	_dispatch(_light_pipe, set_rid, pc, groups, groups, ceili(z_count / 4.0))


## Four sampled-texture uniforms (one per ring level) starting at base_binding. Unused levels repeat level 0.
func _level_uniforms(base_binding: int, texs: Array) -> Array[RDUniform]:
	var out: Array[RDUniform] = []
	for k in MAX_LEVELS:
		var tex: RID = texs[k] if k < texs.size() else texs[0]
		out.append(_u_sampled(base_binding + k, _sampler_vol, tex))
	return out


## After lighting: a finished incoming version is shown (instantly for a new cell or a same-resolution refresh,
## cross-faded when the resolution changes) and the version it replaces is freed.
func _advance_cells() -> void:
	var now := Time.get_ticks_usec()
	var dt := clampf(float(now - _last_tick_us) / 1000000.0, 0.0, 0.1)
	_last_tick_us = now
	var ready := 0
	for cell in _block_sorted:
		var st: CellState = _cells.get(cell)
		if st == null:
			continue
		if st.nxt_lv >= 0 and st.nxt_lit:
			var instant := st.cur_lv < 0 or st.cur_lv == st.nxt_lv or lod_fade_time < 0.01
			if not instant:
				st.fade = maxf(minf(st.fade + dt / lod_fade_time, 1.0), 0.0001)
			if instant or st.fade >= 1.0:
				_free_slot(st.cur_lv, st.cur_slot)
				st.cur_lv = st.nxt_lv
				st.cur_slot = st.nxt_slot
				st.nxt_lv = -1
				st.nxt_slot = -1
				st.nxt_z = 0
				st.nxt_dens = false
				st.nxt_lit = false
				st.fade = 0.0
				_baked_once = true
		if st.cur_lv >= 0:
			ready += 1
	_ready_count = ready


# ------------------------------------------------------------------ CPU copy for gameplay queries
func _process_probe_readback() -> void:
	if not _pending_probe_read or not cpu_readback or not _probe_tex.is_valid():
		return
	_pending_probe_read = false
	var cells: Array[Vector2i] = []
	for i in PROBE_GRID * PROBE_GRID:
		cells.append(_probe_cell[i])
	var meta := {
		"res": _probe_res, "zres": _probe_z, "cell_size": cell_size,
		"base": base_altitude, "thickness": thickness,
		"cells": cells, "ready": _probe_ready.duplicate(),
	}
	if rd.has_method("texture_get_data_async"):
		# Godot 4.4+: no GPU stall.
		rd.call("texture_get_data_async", _probe_tex, 0, _on_probe_data.bind(meta))
	else:
		_on_probe_data(rd.texture_get_data(_probe_tex, 0), meta)


func _on_probe_data(bytes: PackedByteArray, meta: Dictionary) -> void:
	call_deferred("_publish_grid", bytes, meta)


func _publish_grid(bytes: PackedByteArray, meta: Dictionary) -> void:
	var vol := StaticCloudVolume.new()
	vol.data = bytes
	vol.grid = PROBE_GRID
	vol.res = meta["res"]
	vol.zres = meta["zres"]
	vol.cell_size = meta["cell_size"]
	vol.base_altitude = meta["base"]
	vol.thickness = meta["thickness"]
	var cells: Array[Vector2i] = []
	cells.assign(meta["cells"])
	vol.slot_cells = cells
	vol.slot_ready = meta["ready"]
	if not vol.is_valid():
		push_warning("StaticCloudEffect: probe readback has %d bytes, expected %d. CPU queries disabled."
			% [bytes.size(), PROBE_GRID * vol.res * PROBE_GRID * vol.res * vol.zres * 2])
		return
	cpu_volume = vol
	baked.emit()


# ------------------------------------------------------------------ per-frame
func _projection_floats(m: Projection) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for col in [m.x, m.y, m.z, m.w]:
		out.append(col.x)
		out.append(col.y)
		out.append(col.z)
		out.append(col.w)
	return out

func _transform_floats(t: Transform3D) -> PackedFloat32Array:
	# Column-major mat4: basis axes (columns) then the origin.
	return PackedFloat32Array([
		t.basis.x.x, t.basis.x.y, t.basis.x.z, 0.0,
		t.basis.y.x, t.basis.y.y, t.basis.y.z, 0.0,
		t.basis.z.x, t.basis.z.y, t.basis.z.z, 0.0,
		t.origin.x, t.origin.y, t.origin.z, 1.0,
	])

func _color_floats(c: Color, intensity: float, a: float) -> PackedFloat32Array:
	return PackedFloat32Array([c.r * intensity, c.g * intensity, c.b * intensity, a])

func _build_ubo(scene_data: RenderSceneData, full: Vector2i, low: Vector2i) -> PackedByteArray:
	var a := PackedFloat32Array()
	var proj: Projection = scene_data.get_cam_projection()
	a.append_array(_projection_floats(proj.inverse()))
	a.append_array(_transform_floats(scene_data.get_cam_transform()))

	var sun := sun_direction.normalized()
	var view_dist := _view_distance()
	a.append_array(PackedFloat32Array([sun.x, sun.y, sun.z, 0.0]))
	a.append_array(_color_floats(sun_color, sun_intensity, 1.0))
	a.append_array(_color_floats(sky_ambient_color, sky_ambient_intensity, 1.0))
	a.append_array(_color_floats(ground_ambient_color, ground_ambient_intensity, 1.0))
	a.append_array(_color_floats(fog_color, 1.0, fog_density))
	# Only the height matters here: horizontal placement comes from the grid data below.
	a.append_array(PackedFloat32Array([0.0, base_altitude - _r_oy, 0.0, 0.0]))        # vol_origin
	a.append_array(PackedFloat32Array([cell_size, thickness, cell_size, extinction]))  # vol_extent
	a.append_array(PackedFloat32Array([detail_tile_size, detail_strength, detail_fade_start, detail_fade_end]))
	a.append_array(PackedFloat32Array([float(max_steps), near_step, step_growth, view_dist]))
	a.append_array(PackedFloat32Array([float(low.x), float(low.y), float(_frame) if animate_noise else 0.0, float(depth_source)]))
	a.append_array(PackedFloat32Array([forward_g, back_g, back_weight, powder]))
	a.append_array(PackedFloat32Array([float(full.x), float(full.y), float(debug_mode), jitter]))
	a.append_array(PackedFloat32Array([edge_low, edge_high, absf(1.0 / proj.x.x), absf(1.0 / proj.y.y)]))
	a.append_array(PackedFloat32Array([inside_step, view_dist * minf(fade_start_fraction, 0.99), scatter_contribution, scatter_eccentricity]))  # march2

	# Effectors and lights: compact the live slots to the front of fixed-size arrays.
	var eff_a := PackedFloat32Array()
	var eff_b := PackedFloat32Array()
	var eff_n := 0
	for i in MAX_EFFECTORS:
		if _eff_live[i] == 1:
			var o := i * 8
			eff_a.append_array(PackedFloat32Array([_eff_data[o], _eff_data[o + 1], _eff_data[o + 2], _eff_data[o + 3]]))
			eff_b.append_array(PackedFloat32Array([_eff_data[o + 4], _eff_data[o + 5], _eff_data[o + 6], 0.0]))
			eff_n += 1
	var lit_p := PackedFloat32Array()
	var lit_c := PackedFloat32Array()
	var lit_n := 0
	for i in MAX_LIGHTS:
		if _lit_live[i] == 1:
			var o := i * 8
			lit_p.append_array(PackedFloat32Array([_lit_data[o], _lit_data[o + 1], _lit_data[o + 2], _lit_data[o + 3]]))
			lit_c.append_array(PackedFloat32Array([_lit_data[o + 4], _lit_data[o + 5], _lit_data[o + 6], _lit_data[o + 7]]))
			lit_n += 1
	eff_a.resize(MAX_EFFECTORS * 4)
	eff_b.resize(MAX_EFFECTORS * 4)
	lit_p.resize(MAX_LIGHTS * 4)
	lit_c.resize(MAX_LIGHTS * 4)
	a.append_array(PackedFloat32Array([float(eff_n), float(lit_n), float(scatter_octaves), scatter_attenuation]))  # counts
	a.append_array(eff_a)
	a.append_array(eff_b)
	a.append_array(lit_p)
	a.append_array(lit_c)
	a.append_array(PackedFloat32Array([fposmod(_r_ox, detail_tile_size), fposmod(_r_oy, detail_tile_size), fposmod(_r_oz, detail_tile_size), 0.0]))  # detail_off

	# Streamed grid: where the loaded block of cells starts (in local space, computed in double precision),
	# the geometry of every ring level's atlases, and for every cell which slot of which level to read.
	var n := _grid_n()
	var gmin := _grid_center - Vector2i(grid_radius, grid_radius)
	a.append_array(PackedFloat32Array([float(gmin.x) * cell_size - _r_ox, float(gmin.y) * cell_size - _r_oz, cell_size, float(n)]))  # grid_a
	for k in MAX_LEVELS:
		var kk := k if k < _levels else 0
		var res := _lvl_res[kk]
		a.append_array(PackedFloat32Array([float(res + 2), float(res),
			1.0 / float(_lvl_cols[kk] * (res + 2)), 1.0 / float(_lvl_rows[kk] * (res + 2))]))                                   # lvl_d
	for k in MAX_LEVELS:
		var kk := k if k < _levels else 0
		var lres := _lvl_lres[kk]
		a.append_array(PackedFloat32Array([float(lres + 2), float(lres),
			1.0 / float(_lvl_cols[kk] * (lres + 2)), 1.0 / float(_lvl_rows[kk] * (lres + 2))]))                                 # lvl_l
	var ca := PackedFloat32Array()
	var cb := PackedFloat32Array()
	var cc := PackedFloat32Array()
	ca.resize(MAX_CELLS * 4)
	cb.resize(MAX_CELLS * 4)
	cc.resize(MAX_CELLS * 4)
	for row in n:
		for col in n:
			var o := (row * n + col) * 4
			var st: CellState = _cells.get(gmin + Vector2i(col, row))
			if st == null:
				continue
			if st.cur_lv >= 0:
				ca[o] = float(st.cur_lv)
				ca[o + 1] = float(_slot_col(st.cur_lv, st.cur_slot))
				ca[o + 2] = float(_slot_row(st.cur_lv, st.cur_slot))
				ca[o + 3] = 1.0
			if st.nxt_lv >= 0 and st.nxt_lit and st.fade > 0.0:
				cb[o] = float(st.nxt_lv)
				cb[o + 1] = float(_slot_col(st.nxt_lv, st.nxt_slot))
				cb[o + 2] = float(_slot_row(st.nxt_lv, st.nxt_slot))
				cb[o + 3] = maxf(smoothstep(0.0, 1.0, st.fade), 0.00001)
			if st.nxt_lv >= 0 and st.nxt_dens:
				cc[o] = float(st.nxt_lv)
				cc[o + 1] = float(_slot_col(st.nxt_lv, st.nxt_slot))
				cc[o + 2] = float(_slot_row(st.nxt_lv, st.nxt_slot))
				cc[o + 3] = 1.0
			elif st.cur_lv >= 0:
				cc[o] = ca[o]
				cc[o + 1] = ca[o + 1]
				cc[o + 2] = ca[o + 2]
				cc[o + 3] = 1.0
	a.append_array(ca)                                                                                                           # cell_a
	a.append_array(cb)                                                                                                           # cell_b
	a.append_array(cc)                                                                                                           # cell_c
	if a.size() * 4 != UBO_BYTES:
		push_error("StaticCloudEffect: uniform buffer is %d bytes, expected %d" % [a.size() * 4, UBO_BYTES])
	return a.to_byte_array()


func _render_callback(p_callback_type: int, render_data: RenderData) -> void:
	if not _gpu_ready:
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data()
	if buffers == null or scene_data == null:
		return

	# Godot only lets compute shaders write to single-sample textures. With MSAA off we run before the
	# transparent pass (so transparent objects draw over the clouds). With MSAA on we run after it, on the
	# already-resolved image. The effect follows MSAA on/off by switching its own callback type.
	var msaa := buffers.get_msaa_3d() != RenderingServer.VIEWPORT_MSAA_DISABLED
	var wanted := EFFECT_CALLBACK_TYPE_POST_TRANSPARENT if msaa else EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	if p_callback_type != wanted:
		if effect_callback_type != wanted:
			call_deferred("_set_callback_type", wanted)
		return

	# Streaming: keep the block of cells centred on the camera, in rings of falling resolution, and generate
	# whatever is missing or at the wrong resolution.
	var cam_local: Vector3 = scene_data.get_cam_transform().origin
	_ensure_atlases()
	_update_streaming(cam_local)

	var full: Vector2i = buffers.get_internal_size()
	if full.x == 0 or full.y == 0:
		return
	var div := resolution_divisor
	var low := Vector2i(ceili(full.x / float(div)), ceili(full.y / float(div)))

	# The uniform buffer carries the cell table, so it is uploaded before the lighting bake that reads it.
	var ubo_bytes := _build_ubo(scene_data, full, low)
	rd.buffer_update(_ubo, 0, ubo_bytes.size(), ubo_bytes)
	_frame += 1
	_process_light()
	if amortize_sun_rebake:
		_step_sun_pass()
	_advance_cells()
	_process_probe_readback()
	if not _baked_once:
		return  # nothing to draw until the first cell has been generated

	var cloud_name := StringName("cloud_low_%d" % div)
	var blur_name := StringName("cloud_blur_%d" % div)
	var data_name := StringName("cloud_data_%d" % div)
	var storage_sampled := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	if not buffers.has_texture(CTX, cloud_name):
		buffers.create_texture(CTX, cloud_name, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			storage_sampled, RenderingDevice.TEXTURE_SAMPLES_1, low, 1, 1, false, false)
	if not buffers.has_texture(CTX, blur_name):
		buffers.create_texture(CTX, blur_name, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			storage_sampled, RenderingDevice.TEXTURE_SAMPLES_1, low, 1, 1, false, false)
	if not buffers.has_texture(CTX, data_name):
		buffers.create_texture(CTX, data_name, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
			storage_sampled, RenderingDevice.TEXTURE_SAMPLES_1, low, 1, 1, false, false)
	var low_cloud := buffers.get_texture(CTX, cloud_name)
	var low_blur := buffers.get_texture(CTX, blur_name)
	var low_data := buffers.get_texture(CTX, data_name)

	var view := 0
	# Always the resolved, single-sample textures.
	var depth_tex := buffers.get_depth_layer(view, false)
	var color_tex := buffers.get_color_layer(view, false)
	var low_groups := Vector2i(ceili(low.x / 8.0), ceili(low.y / 8.0))

	var march_uniforms: Array[RDUniform] = [
		_u_ubo(0, _ubo),
		_u_sampled(1, _sampler_nearest, depth_tex),
		_u_sampled(4, _sampler_detail, _detail_tex),
		_u_image(5, low_cloud),
		_u_image(6, low_data),
		_u_ubo(7, scene_data.get_uniform_buffer()),
	]
	march_uniforms.append_array(_level_uniforms(8, _density_tex))
	march_uniforms.append_array(_level_uniforms(12, _light_tex))
	var march_set := UniformSetCacheRD.get_cache(_march_shader, 0, march_uniforms)
	_dispatch(_march_pipe, march_set, PackedByteArray(), low_groups.x, low_groups.y, 1)

	# Edge-aware denoise, ping-ponging between the two low-res buffers.
	var src := low_cloud
	var dst := low_blur
	for i in denoise_passes:
		var pc := PackedFloat32Array([float(low.x), float(low.y), float(1 << i), denoise_sharpness]).to_byte_array()
		var blur_set := UniformSetCacheRD.get_cache(_blur_shader, 0, [
			_u_sampled(0, _sampler_nearest, src),
			_u_sampled(1, _sampler_nearest, low_data),
			_u_image(2, dst),
		])
		_dispatch(_blur_pipe, blur_set, pc, low_groups.x, low_groups.y, 1)
		var tmp := src
		src = dst
		dst = tmp
	var final_cloud := src

	var comp_uniforms: Array[RDUniform] = [
		_u_ubo(0, _ubo),
		_u_image(1, color_tex),
		_u_sampled(2, _sampler_nearest, final_cloud),
		_u_sampled(3, _sampler_nearest, low_data),
		_u_sampled(4, _sampler_nearest, depth_tex),
		_u_sampled(6, _sampler_detail, _detail_tex),
		_u_ubo(7, scene_data.get_uniform_buffer()),
	]
	comp_uniforms.append_array(_level_uniforms(8, _density_tex))
	var comp_set := UniformSetCacheRD.get_cache(_composite_shader, 0, comp_uniforms)
	_dispatch(_composite_pipe, comp_set, PackedByteArray(), ceili(full.x / 8.0), ceili(full.y / 8.0), 1)
