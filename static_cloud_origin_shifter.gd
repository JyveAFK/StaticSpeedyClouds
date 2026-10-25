class_name StaticCloudOriginShifter
extends Node
## Floating origin: when the player strays too far from (0,0,0), moves the whole world back so the player is
## near the origin again, and tells the clouds, so they stay in the same place in the true world.
##
## Everything the player can see or touch must be a descendant of `world_root` (terrain, ships, effectors,
## the camera itself...), because that one node is what gets moved. Rigid bodies and anything else that
## stores absolute positions may need handling: connect to `origin_shifted`, which gives the shift applied.
## If your game already has a floating-origin system, skip this node and just call
## StaticCloudEffect.shift_origin(shift) from it with the same shift you apply to the world.

## Emitted after the world has been moved by `shift` (new position = old position + shift).
signal origin_shifted(shift: Vector3)

## The cloud effect to keep in sync. Leave empty to use StaticCloudEffect.active.
@export var effect: StaticCloudEffect
## Watched for distance from the origin (the player or the camera). Must be inside world_root.
@export var target: Node3D
## The node that is moved. Typically the root of the level.
@export var world_root: Node3D
## Shift when the target is further than this (metres) from the origin.
@export var threshold := 5000.0
## Shifts are rounded to a multiple of this (metres), which keeps tiling world-space textures in step.
@export var snap := 1000.0
## Also recentre height. Usually leave off, so the cloud layer's altitude stays small and stable.
@export var shift_vertical := false


func _process(_delta: float) -> void:
	if target == null or world_root == null:
		return
	var p := target.global_position
	var d := Vector3(p.x, p.y if shift_vertical else 0.0, p.z)
	if d.length() < threshold:
		return
	if snap > 0.0:
		d = (d / snap).round() * snap
	if d == Vector3.ZERO:
		return
	shift_world(-d)


## Move the whole world by `shift` and keep the clouds in step.
func shift_world(shift: Vector3) -> void:
	world_root.global_position += shift
	var fx := effect if effect != null else StaticCloudEffect.active
	if fx != null:
		fx.shift_origin(shift)
	origin_shifted.emit(shift)
