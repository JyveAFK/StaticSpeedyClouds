@tool
class_name StaticCloudVolume
extends RefCounted
## CPU copy of the streamed cloud grid, for gameplay queries (rough density only, no fine detail).
## A low-resolution atlas of the 3x3 cells, read back from the GPU. Replaced whenever a cell finishes generating.

var data := PackedByteArray()          # R16F atlas, x fastest, then y, then z
var grid := 3
var res := 0                           # texels per cell (x and y)
var zres := 0                          # slices through the slab
var cell_size := 1.0
var base_altitude := 0.0
var thickness := 1.0
var slot_cells: Array[Vector2i] = []   # which world cell is stored in each slot (slot = x + y * grid)
var slot_ready := PackedByteArray()    # 1 if that slot holds a finished cell


func is_valid() -> bool:
	var n := grid * res
	return res > 0 and zres > 0 and data.size() == n * n * zres * 2


func _texel(x: int, y: int, z: int) -> float:
	var n := grid * res
	return data.decode_half((posmod(x, n) + posmod(y, n) * n + z * n * n) * 2)


## True if the cell containing this TRUE world position (x, z) is loaded and generated.
func is_loaded(tx: float, tz: float) -> bool:
	if not is_valid():
		return false
	var cx := floori(tx / cell_size)
	var cz := floori(tz / cell_size)
	var s := posmod(cx, grid) + posmod(cz, grid) * grid
	return slot_ready[s] == 1 and slot_cells[s] == Vector2i(cx, cz)


## Trilinear density (0..1) at a TRUE world position (x and z are not wrapped).
## Returns 0 outside the cloud slab or in a cell that is not loaded.
func sample_true(tx: float, ty: float, tz: float) -> float:
	if not is_valid():
		return 0.0
	var h := (ty - base_altitude) / thickness * zres - 0.5
	if h < -0.5 or h > zres - 0.5:
		return 0.0
	var cx := floori(tx / cell_size)
	var cz := floori(tz / cell_size)
	var sx := posmod(cx, grid)
	var sz := posmod(cz, grid)
	var s := sx + sz * grid
	if slot_ready[s] == 0 or slot_cells[s] != Vector2i(cx, cz):
		return 0.0
	var gx := (sx + (tx / cell_size - cx)) * res - 0.5
	var gy := (sz + (tz / cell_size - cz)) * res - 0.5
	var x0 := floori(gx)
	var y0 := floori(gy)
	var z0 := floori(h)
	var fx := gx - x0
	var fy := gy - y0
	var fz := h - z0
	var z1 := clampi(z0 + 1, 0, zres - 1)
	z0 = clampi(z0, 0, zres - 1)
	var r := 0.0
	for dz in 2:
		var z := z1 if dz == 1 else z0
		var wz := fz if dz == 1 else 1.0 - fz
		for dy in 2:
			var wy := fy if dy == 1 else 1.0 - fy
			for dx in 2:
				var wx := fx if dx == 1 else 1.0 - fx
				r += _texel(x0 + dx, y0 + dy, z) * wx * wy * wz
	return r
