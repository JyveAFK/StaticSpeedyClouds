extends Node3D
## Self-contained demo: builds sky, sun, ground, test geometry, a fly camera, the cloud compositor
## effect, a cloud probe and a HUD. Open cloud_demo.tscn and press Play.
##
## Controls: click = capture mouse, Esc = release, WASD = move, Q/E = down/up, Shift = fast,
##           L = tower landmark on/off,
##           O = toggle the hand-made "storm eye" cell, P = next weather preset, K = lightning flash, C = clear a hole ahead, V = add a dense puff ahead,
##           X = remove spawned effectors,
##           F1 = cycle debug view, B = re-bake with a new seed, M = toggle 4x MSAA, [ ] = coverage, T/G = sun elevation,
##           Y = swing the sun 90 degrees around (watch the amortized re-bake), U = amortized sun re-bake on/off,
##           N = warping on/off, J = anvil tops on/off.

var effect: StaticCloudEffect
var camera: Camera3D
var sun: DirectionalLight3D
var probe: StaticCloudProbe
var hud: Label

var speed := 200.0
var preset_index := 0
var ground: MeshInstance3D
var shifter: Node
var shift_count := 0
var landmark: Node3D   # a DistantLandmark: the tower 120 km away
var storm_override: StaticCloudCellOverride

# Loaded by path (not by class name) so the demo works even before Godot has registered the new class.
const ShifterScript := preload("res://cloud_demo/static_cloud_origin_shifter.gd")
const LandmarkScript := preload("res://cloud_demo/distant_landmark.gd")

# coverage, softness, type bias/variation, scale bias/variation, height bias/variation, top roughness
const PRESETS := [
	{"name": "Scattered cumulus", "coverage": 0.45, "softness": 0.08, "type": 0.5, "type_var": 0.25, "scale": 0.3, "scale_var": 0.4, "h_bias": 0.5, "h_var": 0.9, "rough": 0.5},
	{"name": "Overcast stratus", "coverage": 0.75, "softness": 0.20, "type": 0.1, "type_var": 0.1, "scale": 0.1, "scale_var": 0.2, "h_bias": 0.35, "h_var": 0.3, "rough": 0.25},
	{"name": "Storm towers", "coverage": 0.55, "softness": 0.10, "type": 0.9, "type_var": 0.15, "scale": 0.2, "scale_var": 0.3, "h_bias": 0.7, "h_var": 1.0, "rough": 0.4},
	{"name": "Mixed sky", "coverage": 0.5, "softness": 0.07, "type": 0.5, "type_var": 1.0, "scale": 0.5, "scale_var": 1.0, "h_bias": 0.5, "h_var": 1.0, "rough": 0.7},
]
var sun_elevation := 40.0  # degrees
var sun_azimuth := 30.0


func _ready() -> void:
	_build_environment()
	_apply_preset(preset_index)
	_setup_cells()
	_build_world()
	_build_landmark()
	_build_camera()
	_build_hud()


func _build_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.25, 0.45, 0.85)
	sky_mat.sky_horizon_color = Color(0.62, 0.74, 0.92)
	sky_mat.ground_horizon_color = Color(0.62, 0.74, 0.92)
	sky_mat.ground_bottom_color = Color(0.35, 0.4, 0.45)
	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	effect = StaticCloudEffect.new()
	var effects: Array[CompositorEffect] = [effect]
	var compositor := Compositor.new()
	compositor.compositor_effects = effects

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	world_env.compositor = compositor
	add_child(world_env)

	sun = DirectionalLight3D.new()
	sun.light_energy = 1.2
	add_child(sun)
	_update_sun()


## Starts the demo in the middle of cell (0, 0) and gives that cell a hand-made layout: a ring of towering cloud
## around a clear "eye". The ring blends back into the procedural clouds toward the cell edges. Press O to toggle it.
func _setup_cells() -> void:
	effect.set_origin_offset(Vector3(effect.cell_size * 0.5, 0.0, effect.cell_size * 0.5))
	storm_override = StaticCloudCellOverride.new()
	storm_override.cell = Vector2i(0, 0)
	storm_override.weather_map = _make_storm_ring_map()
	storm_override.blend_margin = 0.2
	var list: Array[StaticCloudCellOverride] = [storm_override]
	effect.cell_overrides = list


func _make_storm_ring_map() -> ImageTexture:
	# R = coverage, G = cloud type, B = scale. Painted in code here; normally you would author a PNG.
	var size := 192
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			var p := Vector2(x, y) / float(size - 1) - Vector2(0.5, 0.5)
			var r := p.length() * 2.0
			var ring := 1.0 - clampf(absf(r - 0.5) / 0.2, 0.0, 1.0)
			var coverage := clampf(0.1 + ring * 0.95, 0.0, 1.0)
			var type_v := 0.95 if ring > 0.3 else 0.45
			img.set_pixel(x, y, Color(coverage, type_v, 0.3))
	return ImageTexture.create_from_image(img)


func _apply_preset(i: int) -> void:
	var p: Dictionary = PRESETS[i]
	effect.coverage = p["coverage"]
	effect.coverage_softness = p["softness"]
	effect.type_bias = p["type"]
	effect.type_variation = p["type_var"]
	effect.scale_bias = p["scale"]
	effect.scale_variation = p["scale_var"]
	effect.height_bias = p["h_bias"]
	effect.height_variation = p["h_var"]
	effect.top_roughness = p["rough"]


func _flash() -> void:
	var l := StaticCloudLight.new()
	l.effect = effect
	l.color = Color(0.75, 0.85, 1.0)
	l.light_range = 1500.0
	l.core_radius = 90.0
	l.energy = 0.0
	add_child(l)
	var fwd := -camera.global_transform.basis.z
	l.global_position = camera.global_position + fwd * 500.0 + Vector3(randf_range(-150.0, 150.0), randf_range(-100.0, 100.0), randf_range(-150.0, 150.0))
	var tw := create_tween()
	tw.tween_property(l, "energy", 140.0, 0.04)
	tw.tween_property(l, "energy", 15.0, 0.07)
	tw.tween_property(l, "energy", 100.0, 0.04)
	tw.tween_property(l, "energy", 0.0, 0.45)
	tw.tween_callback(l.queue_free)


func _spawn_effector(add: float, clear: float) -> void:
	var e := StaticCloudEffector.new()
	e.effect = effect
	e.radius = 450.0
	e.add_density = add
	e.clear_amount = clear
	e.add_to_group("demo_effectors")
	add_child(e)
	e.global_position = camera.global_position - camera.global_transform.basis.z * 700.0


func _update_sun() -> void:
	sun.rotation_degrees = Vector3(-sun_elevation, sun_azimuth + 180.0, 0.0)
	# The light shines along its local -Z, so +Z (basis.z) points toward the sun.
	effect.sun_direction = sun.global_transform.basis.z


## A low-poly tower 120 km away. That is twice the camera's far plane (60 km), so without the landmark node it is
## never drawn. Press L to switch the landmark off and watch it disappear.
func _build_landmark() -> void:
	landmark = LandmarkScript.new()
	landmark.position = Vector3(0.0, 0.0, -120000.0)
	var shaft := CylinderMesh.new()
	shaft.top_radius = 60.0
	shaft.bottom_radius = 160.0
	shaft.height = 3600.0
	shaft.radial_segments = 6
	shaft.rings = 1
	var tower := MeshInstance3D.new()
	tower.mesh = shaft
	var mat := _mat(Color(0.95, 0.5, 0.12))
	mat.emission_enabled = true
	mat.emission = Color(0.95, 0.5, 0.12) * 0.35
	tower.material_override = mat
	tower.position = Vector3(0.0, 1800.0, 0.0)
	landmark.add_child(tower)
	add_child(landmark)


func _build_world() -> void:
	ground = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80000.0, 80000.0)
	ground.mesh = plane
	ground.material_override = _mat(Color(0.2, 0.32, 0.18))
	add_child(ground)

	# A tower that pokes up through the cloud layer, to check occlusion and edge behaviour.
	_add_box(Vector3(40.0, 2600.0, 40.0), Vector3(250.0, 1300.0, -700.0), Color(0.75, 0.75, 0.8))

	# Scatter some floating blocks at different altitudes around and inside the layer.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 40:
		var pos := Vector3(rng.randf_range(-6000.0, 6000.0), rng.randf_range(300.0, 3200.0), rng.randf_range(-6000.0, 6000.0))
		_add_box(Vector3(60.0, 20.0, 120.0), pos, Color(0.8, 0.35, 0.3))


func _add_box(size: Vector3, pos: Vector3, color: Color) -> void:
	var m := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	m.mesh = box
	m.material_override = _mat(color)
	m.position = pos
	add_child(m)


func _mat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat


func _build_camera() -> void:
	camera = Camera3D.new()
	camera.far = 60000.0
	camera.position = Vector3(0.0, 700.0, 1500.0)
	camera.rotation_degrees = Vector3(8.0, 0.0, 0.0)
	add_child(camera)

	probe = StaticCloudProbe.new()
	probe.effect = effect
	camera.add_child(probe)

	# Floating origin: when you fly more than 3 km from the origin, the whole demo is moved back and the
	# clouds are told, so they do not jump. Watch the "true position" in the HUD keep counting while the
	# real position stays small.
	shifter = ShifterScript.new()
	shifter.effect = effect
	shifter.target = camera
	shifter.world_root = self
	shifter.threshold = 3000.0
	shifter.snap = 1000.0
	shifter.origin_shifted.connect(func(_s: Vector3) -> void: shift_count += 1)
	add_child(shifter)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	hud = Label.new()
	hud.position = Vector2(12.0, 8.0)
	hud.add_theme_color_override("font_color", Color.WHITE)
	hud.add_theme_color_override("font_outline_color", Color.BLACK)
	hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(hud)
	add_child(layer)


func _process(delta: float) -> void:
	ground.global_position = Vector3(camera.global_position.x, 0.0, camera.global_position.z)
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir.z -= 1.0
	if Input.is_key_pressed(KEY_S): dir.z += 1.0
	if Input.is_key_pressed(KEY_A): dir.x -= 1.0
	if Input.is_key_pressed(KEY_D): dir.x += 1.0
	var vertical := 0.0
	if Input.is_key_pressed(KEY_E): vertical += 1.0
	if Input.is_key_pressed(KEY_Q): vertical -= 1.0
	var s := speed * (5.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	camera.global_translate((camera.global_transform.basis * dir) * s * delta + Vector3.UP * vertical * s * delta)

	var names := ["OUT", "EDGE", "IN"]
	var cpu_ready: bool = effect.cpu_volume != null
	hud.text = "Cloud state: %s    cloudiness: %.2f    density here: %.2f%s\nAltitude: %.0f m    debug view: %d    sun elevation: %.0f    coverage: %.2f\nWeather: %s  (P = next)    K lightning   C clear   V dense   X remove   O storm eye on/off\nTrue position: %.0f, %.0f, %.0f    local: %.0f, %.0f, %.0f    origin shifts: %d\nCell: %s    cells ready: %d / %d    view: %.0f km    cloud memory: %.0f MB    storm override: %s" % [
		names[probe.state], probe.cloudiness, probe.density_here, "" if cpu_ready else "   (baking...)",
		camera.global_position.y, effect.debug_mode, sun_elevation, effect.coverage, PRESETS[preset_index]["name"],
		effect.get_true_position(camera.global_position).x, effect.get_true_position(camera.global_position).y, effect.get_true_position(camera.global_position).z,
		camera.global_position.x, camera.global_position.y, camera.global_position.z, shift_count,
		str(effect.get_cell_at(camera.global_position)), effect.get_ready_cell_count(), effect.get_grid_cell_count(), effect.get_view_distance() / 1000.0, effect.get_memory_mb(), "on" if storm_override.enabled else "off"]
	hud.text += "\nWarping (N): %s    anvils (J): %s    sun re-bake (U): %s    Y = swing sun 90 degrees" % [
		"on" if effect.warp_enabled else "off", "on" if effect.anvil_enabled else "off",
		"amortized" if effect.amortize_sun_rebake else "immediate"]
	hud.text += "\nTower: %.0f km away  (%s)   L = landmark on/off" % [landmark.true_distance / 1000.0, "drawn at a parked distance" if landmark.is_proxied else "drawn at its real position"]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera.rotation.y -= event.relative.x * 0.002
		camera.rotation.x = clampf(camera.rotation.x - event.relative.y * 0.002, -1.5, 1.5)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_F1:
				effect.debug_mode = (effect.debug_mode + 1) % 5
			KEY_L:
				landmark.enabled = not landmark.enabled
			KEY_O:
				storm_override.enabled = not storm_override.enabled
				effect.refresh_overrides()
			KEY_P:
				preset_index = (preset_index + 1) % PRESETS.size()
				_apply_preset(preset_index)
			KEY_K:
				_flash()
			KEY_C:
				_spawn_effector(0.0, 1.0)
			KEY_V:
				_spawn_effector(1.0, 0.0)
			KEY_X:
				for n in get_tree().get_nodes_in_group("demo_effectors"):
					n.queue_free()
			KEY_B:
				effect.cloud_seed += 1
			KEY_M:
				var vp := get_viewport()
				vp.msaa_3d = Viewport.MSAA_DISABLED if vp.msaa_3d != Viewport.MSAA_DISABLED else Viewport.MSAA_4X
			KEY_BRACKETLEFT:
				effect.coverage = clampf(effect.coverage - 0.05, 0.0, 1.0)
			KEY_BRACKETRIGHT:
				effect.coverage = clampf(effect.coverage + 0.05, 0.0, 1.0)
			KEY_T:
				sun_elevation = clampf(sun_elevation + 5.0, 5.0, 85.0)
				_update_sun()
			KEY_G:
				sun_elevation = clampf(sun_elevation - 5.0, 5.0, 85.0)
				_update_sun()
			KEY_Y:
				sun_azimuth = fposmod(sun_azimuth + 90.0, 360.0)
				_update_sun()
			KEY_U:
				effect.amortize_sun_rebake = not effect.amortize_sun_rebake
			KEY_N:
				effect.warp_enabled = not effect.warp_enabled
			KEY_J:
				effect.anvil_enabled = not effect.anvil_enabled
