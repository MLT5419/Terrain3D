# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DLayerData
extends Resource
## Sparse source maps. Coordinates are sample indices; spacing converts them to meters.
## Height zero and unpainted height are different: coverage is stored separately.

const CHUNK_SIZE := 64
const HEIGHT := 0
const CONTROL := 1
const COLOR := 2
const MASK := 3
const FORMAT_VERSION := 1

@export_storage var version: int = FORMAT_VERSION
@export_range(0.01, 100.0, 0.01, "or_greater") var spacing := 1.0:
	set(value):
		spacing = maxf(value, 0.01)
		emit_changed()
@export_storage var sample_bounds := Rect2i()
var _control_buffers: Dictionary = {}
var _read_control_cache: Dictionary = {}
var _used_slots: Dictionary = {}
var _used_slots_dirty := true
var last_changed_bounds := Rect2()
var _changed_pixels := Rect2i()
# Each chunk owns only the channels edited there. Mask RGB = height/control/color coverage.
# Replacing maps on file reload must also invalidate caches kept by a live instance.
@export_storage var chunks: Dictionary = {}:
	set(value):
		chunks = value
		_used_slots_dirty = true
		_read_control_cache.clear()
		_control_buffers.clear()
		emit_changed()

func clone_source(bounds: Rect2i = Rect2i()) -> Terrain3DLayerData:
	var copy := Terrain3DLayerData.new()
	copy.version = version
	copy.spacing = spacing
	copy.sample_bounds = sample_bounds
	for key: Vector2i in chunks:
		if bounds.has_area() and not bounds.intersects(Rect2i(key * CHUNK_SIZE, Vector2i.ONE * CHUNK_SIZE)):
			continue
		var maps := {}
		for channel: int in chunks[key]:
			maps[channel] = chunks[key][channel].duplicate()
		copy.chunks[key] = maps
	return copy

func copy_chunk(key: Vector2i) -> Variant:
	if not chunks.has(key):
		return null
	var maps := {}
	for channel: int in chunks[key]:
		maps[channel] = chunks[key][channel].duplicate()
	return maps

func begin_edit() -> void:
	_control_buffers.clear()
	_read_control_cache.clear()
	_changed_pixels = Rect2i()

func end_edit() -> void:
	for key: Vector2i in _control_buffers:
		_image(key, CONTROL, true).set_data(CHUNK_SIZE, CHUNK_SIZE, false, Image.FORMAT_RF, _control_buffers[key])
	_control_buffers.clear()
	_read_control_cache.clear()
	_used_slots_dirty = true
	_emit_changes()

func _emit_changes() -> void:
	last_changed_bounds = Rect2(Vector2(_changed_pixels.position) * spacing, Vector2(_changed_pixels.size) * spacing).grow(spacing) if _changed_pixels.has_area() else Rect2()
	emit_changed()
	last_changed_bounds = Rect2()
	_changed_pixels = Rect2i()

func get_control(pixel: Vector2i) -> int:
	var key := _chunk_key(pixel)
	var image := _image(key, CONTROL)
	if not image:
		return 0
	if not _control_buffers.has(key) and not _read_control_cache.has(key):
		_read_control_cache[key] = image.get_data()
	var bytes: PackedByteArray = _control_buffers[key] if _control_buffers.has(key) else _read_control_cache[key]
	return bytes.decode_u32((posmod(pixel.y, CHUNK_SIZE) * CHUNK_SIZE + posmod(pixel.x, CHUNK_SIZE)) * 4)

func set_control(pixel: Vector2i, control: int, coverage: float = 1.0) -> void:
	_expand_bounds(pixel)
	var key := _chunk_key(pixel)
	if not _control_buffers.has(key):
		_control_buffers[key] = _image(key, CONTROL, true).get_data()
	var bytes: PackedByteArray = _control_buffers[key]
	bytes.encode_u32((posmod(pixel.y, CHUNK_SIZE) * CHUNK_SIZE + posmod(pixel.x, CHUNK_SIZE)) * 4, control)
	_control_buffers[key] = bytes
	var local := Vector2i(posmod(pixel.x, CHUNK_SIZE), posmod(pixel.y, CHUNK_SIZE))
	var mask := _image(key, MASK, true)
	var m := mask.get_pixelv(local)
	m.g = coverage
	mask.set_pixelv(local, m)
	_used_slots_dirty = true

func get_used_slots() -> Array:
	if _used_slots_dirty:
		_used_slots.clear()
		for key: Vector2i in chunks:
			var image := _image(key, CONTROL)
			var mask := _image(key, MASK)
			if not image or not mask:
				continue
			var bytes := image.get_data()
			var masks := mask.get_data()
			for pixel in CHUNK_SIZE * CHUNK_SIZE:
				if masks[pixel * 4 + CONTROL] == 0:
					continue
				var control := bytes.decode_u32(pixel * 4)
				_used_slots[(control >> 27) & 31] = true
				_used_slots[(control >> 22) & 31] = true
		_used_slots_dirty = false
	return _used_slots.keys()

func _chunk_key(pixel: Vector2i) -> Vector2i:
	return Vector2i(floori(float(pixel.x) / CHUNK_SIZE), floori(float(pixel.y) / CHUNK_SIZE))

func _image(key: Vector2i, channel: int, create: bool = false) -> Image:
	if not chunks.has(key):
		if not create:
			return null
		chunks[key] = {}
	var maps: Dictionary = chunks[key]
	if not maps.has(channel) and create:
		var format := Image.FORMAT_RGBA8 if channel >= COLOR else Image.FORMAT_RF
		var image := Image.create(CHUNK_SIZE, CHUNK_SIZE, false, format)
		image.fill(Color(1, 1, 1, 0.5) if channel == COLOR else Color(0, 0, 0, 0))
		maps[channel] = image
	return maps.get(channel)

func get_pixel(pixel: Vector2i, channel: int) -> Color:
	var image := _image(_chunk_key(pixel), channel)
	if not image:
		return Color(1, 1, 1, 0.5) if channel == COLOR else Color(0, 0, 0, 0)
	return image.get_pixel(posmod(pixel.x, CHUNK_SIZE), posmod(pixel.y, CHUNK_SIZE))

func set_pixel(pixel: Vector2i, channel: int, value: Color, coverage: float = 1.0, notify: bool = true) -> void:
	assert(channel == HEIGHT or channel == COLOR, "Use set_control()/end_edit() for packed material IDs.")
	if channel == HEIGHT and not is_finite(value.r):
		return
	_expand_bounds(pixel)
	var key := _chunk_key(pixel)
	var local := Vector2i(posmod(pixel.x, CHUNK_SIZE), posmod(pixel.y, CHUNK_SIZE))
	_image(key, channel, true).set_pixelv(local, value)
	var mask := _image(key, MASK, true)
	var m := mask.get_pixelv(local)
	m[channel] = clampf(coverage, 0.0, 1.0)
	mask.set_pixelv(local, m)
	if notify:
		_emit_changes()

func erase(pixel: Vector2i, channel: int, amount: float = 1.0, notify: bool = true) -> void:
	var image := _image(_chunk_key(pixel), MASK)
	if not image:
		return
	var local := Vector2i(posmod(pixel.x, CHUNK_SIZE), posmod(pixel.y, CHUNK_SIZE))
	var mask := image.get_pixelv(local)
	mask[channel] = maxf(0, mask[channel] - amount)
	image.set_pixelv(local, mask)
	_used_slots_dirty = true
	_mark_pixel(pixel)
	if notify:
		_emit_changes()

func get_bounds() -> Rect2:
	return Rect2(Vector2(sample_bounds.position) * spacing, Vector2(sample_bounds.size - Vector2i.ONE) * spacing) if sample_bounds.has_area() else Rect2()

func _expand_bounds(pixel: Vector2i) -> void:
	var point := Rect2i(pixel, Vector2i.ONE)
	sample_bounds = sample_bounds.merge(point) if sample_bounds.has_area() else point
	_mark_pixel(pixel)

func _mark_pixel(pixel: Vector2i) -> void:
	var point := Rect2i(pixel, Vector2i.ONE)
	_changed_pixels = _changed_pixels.merge(point) if _changed_pixels.has_area() else point

# Height and color use coverage-premultiplied bilinear filtering, avoiding empty-border bias.
# Packed control bits must never pass through floating-point interpolation.
func sample(position: Vector2, channel: int) -> Color:
	var p := position / spacing
	if channel == CONTROL:
		return get_pixel(Vector2i(p.round()), channel)
	var origin := Vector2i(p.floor())
	var f := p - Vector2(origin)
	var result := Color(0, 0, 0, 0)
	var weight := 0.0
	for y in 2:
		for x in 2:
			var pixel := origin + Vector2i(x, y)
			var w := (f.x if x else 1.0 - f.x) * (f.y if y else 1.0 - f.y)
			w *= get_pixel(pixel, MASK)[channel]
			result += get_pixel(pixel, channel) * w
			weight += w
	return result / weight if weight > 0.000001 else Color(0, 0, 0, 0)

func sample_coverage(position: Vector2, channel: int) -> float:
	var p := position / spacing
	if channel == CONTROL:
		return get_pixel(Vector2i(p.round()), MASK)[channel]
	var origin := Vector2i(p.floor())
	var f := p - Vector2(origin)
	var result := 0.0
	for y in 2:
		for x in 2:
			result += get_pixel(origin + Vector2i(x, y), MASK)[channel] * (f.x if x else 1.0 - f.x) * (f.y if y else 1.0 - f.y)
	return result

func import_heightmap(image: Image, reference_height: float = 0.0, origin: Vector2i = Vector2i.ZERO) -> void:
	assert(image and not image.is_compressed())
	for y in image.get_height():
		for x in image.get_width():
			set_pixel(origin + Vector2i(x, y), HEIGHT, Color(image.get_pixel(x, y).r - reference_height, 0, 0, 1), 1.0, false)
	emit_changed()

func save_external(path: String) -> Error:
	if not path.begins_with("res://") or path.get_extension() != "res":
		return ERR_INVALID_PARAMETER
	var absolute := ProjectSettings.globalize_path(path.simplify_path()).simplify_path()
	var project_root := ProjectSettings.globalize_path("res://").trim_suffix("/") + "/"
	if not absolute.begins_with(project_root):
		return ERR_INVALID_PARAMETER
	var error := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if error == OK:
		error = ResourceSaver.save(self, path, ResourceSaver.FLAG_COMPRESS | ResourceSaver.FLAG_CHANGE_PATH)
		if error == OK:
			take_over_path(path)
	return error
