@tool
class_name StaticCloudCellOverride
extends Resource
## Replaces the procedural clouds of one grid cell with a hand-made layout.
##
## Assign textures that cover the cell exactly (u = +X across the cell, v = +Z):
##   weather_map  R = coverage (white = cloud, black = clear), G = cloud type (0 stratus, 0.5 cumulus,
##                1 towering), B = feature scale (0 big billows, 1 small puffs)
##   height_map   R = cloud-top height (black = very low, white = very high)
## Either may be left empty to keep that channel procedural.
##
## Textures can be assigned directly, or by path: path textures are loaded on a background thread when the
## player gets within two cells, so nothing stalls the game.
##
## Near the cell edge the layout blends back into the procedural clouds (blend_margin), so the border with the
## neighbouring cells stays seamless. Set blend_margin to 0 for a hard edge.
##
## Add to StaticCloudEffect.cell_overrides (inspector) or with add_cell_override().

@export var cell := Vector2i.ZERO
@export var enabled := true
@export var weather_map: Texture2D
@export_file("*.png", "*.jpg", "*.jpeg", "*.webp", "*.exr", "*.res", "*.tres") var weather_map_path := ""
@export var height_map: Texture2D
@export_file("*.png", "*.jpg", "*.jpeg", "*.webp", "*.exr", "*.res", "*.tres") var height_map_path := ""
## Fraction of the cell (from each edge) over which the layout blends into the procedural clouds.
@export_range(0.0, 0.5) var blend_margin := 0.15

# Set by the effect when a path texture could not be loaded; the cell then falls back to procedural.
var weather_failed := false
var height_failed := false


## True when every texture this override needs is available (or has failed to load and will be skipped).
func is_ready() -> bool:
	var weather_ok := weather_map != null or weather_map_path == "" or weather_failed
	var height_ok := height_map != null or height_map_path == "" or height_failed
	return weather_ok and height_ok
