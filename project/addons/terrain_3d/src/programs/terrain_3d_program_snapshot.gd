# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DProgramSnapshot
extends RefCounted
## CPU query view. No renderer readback and no writable terrain handles are exposed by the API.

var base: Dictionary
var sources: Array[Terrain3DLayer] = []
var masks: Array[Dictionary] = []
var assets: Terrain3DAssets
var spacing := 1.0
var region_size := 64
var _controls := {}

func _base_sample(pixel: Vector2i) -> Dictionary:
	var location := Vector2i(floori(float(pixel.x) / region_size), floori(float(pixel.y) / region_size))
	var region: Terrain3DRegion = base.get(location)
	if not region or region.is_deleted():
		return {"height": 0.0, "control": 4, "valid": false, "exists": false}
	var local := Vector2i(posmod(pixel.x, region_size), posmod(pixel.y, region_size))
	if not _controls.has(location):
		_controls[location] = region.control_map.get_data()
	var bytes: PackedByteArray = _controls[location]
	var bits := bytes.decode_u32((local.y * region_size + local.x) * 4)
	return {"height": region.height_map.get_pixelv(local).r, "control": bits, "valid": not bool(bits & 4), "exists": true}

func _height_pixel(pixel: Vector2i) -> float:
	var sample := _base_sample(pixel)
	var value: float = sample.height
	var valid: bool = sample.valid
	var world := Vector2(pixel) * spacing
	for source in sources:
		if not source.participates() or not source.data:
			continue
		var local := source.source_position(world)
		var weight := source.data.sample_coverage(local, 0) * source.height_opacity
		if weight > 0:
			var height := source.height_value(source.data.sample(local, 0).r)
			value = value + height * weight if source.height_mode == Terrain3DLayer.HeightMode.ADD else lerpf(value, height, weight)
			var location := Vector2i(floori(float(pixel.x) / region_size), floori(float(pixel.y) / region_size))
			if not base.has(location) or base[location].is_deleted():
				valid = true
	return value if valid else NAN

func height(world: Vector2) -> float:
	var point := world / spacing
	if (point - point.round()).length_squared() < 0.0001:
		return _height_pixel(Vector2i(point.round()))
	var first := Vector2i(point.floor())
	var fraction := point - Vector2(first)
	var value := 0.0
	for y in 2:
		for x in 2:
			var weight := (fraction.x if x else 1 - fraction.x) * (fraction.y if y else 1 - fraction.y)
			if weight > 0:
				var h := _height_pixel(first + Vector2i(x, y))
				if not is_finite(h):
					return NAN
				value += h * weight
	return value

func role_pair(world: Vector2) -> Dictionary:
	var initial := _base_sample(Vector2i((world / spacing).floor()))
	var bits: int = initial.control
	if not initial.exists and is_finite(height(world)):
		bits &= ~4
	var palette: Array = []
	for index in assets.texture_list.size():
		var asset := assets.texture_list[index]
		palette.append(asset.role_key if asset and not asset.role_key.is_empty() else StringName("base.material_%s" % index))
	var owner: Terrain3DLayer
	for source in sources:
		if source.participates() and source.paint_enabled and source.data:
			var local := source.source_position(world)
			if source.data.sample_coverage(local, 1) >= 0.5:
				bits = source.data.get_control(Vector2i((local / source.data.spacing).round()))
				palette = []
				for slot in source.slots:
					palette.append(slot.key if slot else &"")
				owner = source.owner_layer if source is Terrain3DGeneratedLayer else source
	return {"bits": bits, "palette": palette, "owner": owner}

func role_weight(world: Vector2, role: StringName, owner: Terrain3DLayer = null, scoped: bool = false) -> float:
	var pair := role_pair(world)
	if scoped and pair.owner != owner:
		return 0
	if pair.bits & 4:
		return 0
	if pair.bits & 1:
		return -1 # GPU autoshader rules require an explicit CPU surface classifier.
	var ids := [(pair.bits >> 27) & 31, (pair.bits >> 22) & 31]
	var blend := float((pair.bits >> 14) & 255) / 255.0
	var weight := 0.0
	for index in 2:
		if ids[index] < pair.palette.size() and pair.palette[ids[index]] == role:
			weight += blend if index else 1 - blend
	return weight

func mask_weight(world: Vector2, key: StringName) -> float:
	var weight := 0.0
	for record in masks:
		if record.key == key:
			var source: Terrain3DGeneratedLayer = record.layer
			weight = maxf(weight, record.data.sample_coverage(source.source_position(world), 0))
	return weight
