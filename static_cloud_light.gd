class_name StaticCloudLight
extends Node3D
## A point light that lights the CLOUDS from inside: lightning, muzzle flashes, explosions, engine glow.
## At most StaticCloudEffect.MAX_LIGHTS (6) are active at once; extra ones are ignored.
##
## It only lights the cloud volume. To light meshes as well, keep mirror_omni on: this node then creates a
## matching OmniLight3D child. Animate `energy` (a Tween works well) for flashes and flicker.

## The cloud effect to light. Leave empty to use StaticCloudEffect.active.
@export var effect: StaticCloudEffect
@export var color := Color(0.75, 0.85, 1.0)
## Brightness of the glow at the light's centre. The sun is about 3.
@export var energy := 40.0
## Distance (m) beyond which the light has no effect on the clouds.
@export var light_range := 1000.0
## Size (m) of the bright core. Larger = a wider, softer glow around the light.
@export var core_radius := 60.0
## Also create an OmniLight3D so meshes near the light are lit too.
@export var mirror_omni := true
## OmniLight3D energy = energy * this.
@export var omni_energy_scale := 0.05

var _slot := -1
var _slot_effect: StaticCloudEffect
var _omni: OmniLight3D


func _ready() -> void:
	if mirror_omni:
		_omni = OmniLight3D.new()
		add_child(_omni)


func _process(_delta: float) -> void:
	if _omni != null:
		_omni.light_color = color
		_omni.light_energy = energy * omni_energy_scale
		_omni.omni_range = light_range

	var fx := effect if effect != null else StaticCloudEffect.active
	if fx == null:
		return
	if _slot < 0 or _slot_effect != fx:
		_release()
		_slot = fx.acquire_light()
		_slot_effect = fx
		if _slot < 0:
			return
	fx.set_light(_slot, global_position, light_range, color, energy, core_radius)


func _exit_tree() -> void:
	_release()


func _release() -> void:
	if _slot >= 0 and _slot_effect != null:
		_slot_effect.release_light(_slot)
	_slot = -1
	_slot_effect = null
