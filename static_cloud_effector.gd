class_name StaticCloudEffector
extends Node3D
## A sphere that changes the clouds inside it, live (it can move, grow and shrink).
##   add_density   > 0 : creates cloud here, even in clear sky (a storm cell, an explosion plume)
##   clear_amount  > 0 : removes cloud here (a hole carved by a ship, a clearing)
## At most StaticCloudEffect.MAX_EFFECTORS (16) are active at once.
##
## Not affected by effectors: the baked sun shadowing inside clouds, so an added puff is lit as if in open sun.

## The cloud effect to modify. Leave empty to use StaticCloudEffect.active.
@export var effect: StaticCloudEffect
@export var radius := 500.0
@export_range(0.0, 1.0) var add_density := 0.0
@export_range(0.0, 1.0) var clear_amount := 0.0
## Fraction of the radius that is at full strength; the rest fades out smoothly.
@export_range(0.0, 0.99) var inner_fraction := 0.4

var _slot := -1
var _slot_effect: StaticCloudEffect


func _process(_delta: float) -> void:
	var fx := effect if effect != null else StaticCloudEffect.active
	if fx == null:
		return
	if _slot < 0 or _slot_effect != fx:
		_release()
		_slot = fx.acquire_effector()
		_slot_effect = fx
		if _slot < 0:
			return
	fx.set_effector(_slot, global_position, radius, add_density, clear_amount, inner_fraction)


func _exit_tree() -> void:
	_release()


func _release() -> void:
	if _slot >= 0 and _slot_effect != null:
		_slot_effect.release_effector(_slot)
	_slot = -1
	_slot_effect = null
