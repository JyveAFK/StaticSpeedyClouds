class_name StaticCloudProbe
extends Node3D
## Put this on (or under) anything that needs to know whether it is in a cloud: the player, a ship, a camera.
## Reads the low-res CPU copy of the clouds; no GPU readback per frame.
##
## It finds the cloud effect by itself, so in your own scenes you just add the node. It looks, in order, at:
## the `effect` export (if you set it), the current Camera3D's Compositor, every WorldEnvironment's Compositor,
## and finally the most recently created StaticCloudEffect.
##
## Limits: it only has data inside the 3x3 block of cells loaded around the CAMERA. A probe far from the camera
## (an AI ship tens of km away, say) reads "not loaded" and reports OUT. See `status` and `data_available`.

enum State { OUT, EDGE, IN }

signal state_changed(new_state: State)

## Optional. Leave empty and the probe finds the effect in your Compositor on its own.
@export var effect: StaticCloudEffect
## Radius (m) of the neighbourhood used to detect edges. Larger = EDGE triggers earlier.
## Keep it above one texel of the gameplay copy: cell_size / probe_resolution (333 m with the defaults).
@export var edge_radius := 40.0
## Higher = cloudiness follows faster.
@export var smoothing := 5.0
## Apply the same hard-edge curve as the renderer so IN/OUT matches what the player sees.
@export var match_render_curve := true
## The probe samples once every this many physics frames (4 = 15 times a second at 60 Hz). The first sample is immediate.
@export_range(1, 120) var update_every_frames := 4

var state := State.OUT
## Smoothed 0..1 value, handy for audio muffling, turbulence, HUD fades...
var cloudiness := 0.0
## Raw density at the probe position (0..1, unsmoothed).
var density_here := 0.0
## True when the probe has real data at its position (the effect was found, has baked, and the cell is loaded).
var data_available := false
## Human-readable reason when data_available is false. Handy to put in a debug label.
var status := "looking for a StaticCloudEffect..."

var _fx: StaticCloudEffect
var _search_timer := 0.0
var _no_effect_time := 0.0
var _warned := false

var _frame_count := 1000000   # large so the first sample happens immediately
var _accum := 0.0   # time since the last sample, so smoothing behaves the same at any update rate

## Emitted after every sample with the raw density at the probe position (0 when there is no data).
signal density_changed(density: float)

const _AXES: Array[Vector3] = [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]


## The effect this probe is reading from (null until found).
func get_effect() -> StaticCloudEffect:
	return _fx


func _physics_process(delta: float) -> void:
	_accum += delta
	_frame_count += 1
	if _frame_count < update_every_frames:
		return
	_frame_count = 0
	delta = _accum   # from here on, delta is the time since the last sample
	_accum = 0.0

	# Find (or re-find, if it was freed or a scene changed) the effect, at most twice a second.
	if _fx == null or not is_instance_valid(_fx) or (effect != null and _fx != effect):
		_fx = null
		_search_timer -= delta
		if _search_timer <= 0.0:
			_search_timer = 0.5
			_fx = _find_effect()
		if _fx == null:
			data_available = false
			status = "no StaticCloudEffect found (is it in a Compositor on the WorldEnvironment or camera?)"
			_no_effect_time += delta
			if _no_effect_time > 3.0 and not _warned:
				_warned = true
				push_warning("StaticCloudProbe '%s': no StaticCloudEffect found. Add one to the Compositor of your WorldEnvironment (or camera), or assign the `effect` property." % name)
			return
		_no_effect_time = 0.0

	if _fx.cpu_volume == null or not _fx.cpu_volume.is_valid():
		data_available = false
		status = "waiting for the first cells to generate (or cpu_readback is off)"
		return

	var p := global_position
	if not _fx.is_loaded_at(p):
		data_available = false
		status = "outside the loaded cells (too far from the camera)"
		density_here = 0.0
		cloudiness = lerpf(cloudiness, 0.0, 1.0 - exp(-smoothing * delta))
		_update_state(0.0, 0.0)
		density_changed.emit(density_here)
		return

	data_available = true
	status = "ok"
	var centre := _shape(_fx.density_at(p))
	var total := centre
	var hi := centre
	for a in _AXES:
		var d := _shape(_fx.density_at(p + a * edge_radius))
		total += d
		hi = maxf(hi, d)

	density_here = centre
	cloudiness = lerpf(cloudiness, total / 7.0, 1.0 - exp(-smoothing * delta))
	_update_state(centre, hi)
	density_changed.emit(density_here)


func _update_state(centre: float, hi: float) -> void:
	# Hysteresis: easier to enter a state than to leave it, so it does not flicker at boundaries.
	var next := state
	match state:
		State.OUT:
			if centre > 0.5:
				next = State.IN
			elif hi > 0.1:
				next = State.EDGE
		State.EDGE:
			if centre > 0.5:
				next = State.IN
			elif hi < 0.05:
				next = State.OUT
		State.IN:
			if centre < 0.35:
				next = State.EDGE
	if next != state:
		state = next
		state_changed.emit(state)


func _shape(d: float) -> float:
	if match_render_curve and _fx.edge_high > _fx.edge_low:
		return smoothstep(_fx.edge_low, _fx.edge_high, d)
	return d


func _find_effect() -> StaticCloudEffect:
	if effect != null:
		return effect
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam != null and cam.compositor != null:
		var from_cam := _effect_in(cam.compositor)
		if from_cam != null:
			return from_cam
	var tree := get_tree()
	if tree != null:
		for n in tree.root.find_children("*", "WorldEnvironment", true, false):
			var we := n as WorldEnvironment
			if we != null and we.compositor != null:
				var from_env := _effect_in(we.compositor)
				if from_env != null:
					return from_env
	if is_instance_valid(StaticCloudEffect.active):
		return StaticCloudEffect.active
	return null


func _effect_in(comp: Compositor) -> StaticCloudEffect:
	for e in comp.compositor_effects:
		if e is StaticCloudEffect:
			return e
	return null
