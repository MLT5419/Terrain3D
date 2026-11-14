# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DProgramOutput
extends RefCounted
## Buffered output; a failed build cannot partially edit the live terrain or scene.

var layer: Terrain3DGeneratedLayer
var masks: Dictionary = {}
var nodes: Dictionary = {}
var placements: Dictionary = {}
var _context: Terrain3DProgramContext
var _writes := 0
var _errors := PackedStringArray()

func _weight(point: Vector2, value: float) -> float:
	if not is_finite(value):
		fail("Output coverage must be finite.")
		return 0
	return clampf(value * _context.coverage(point), 0, 1)

func _point(point: Vector2, channel: String) -> bool:
	if not point.is_finite() or not _context.get_bounds().has_point(point):
		fail("Output point is outside its chunk: %s" % point)
		return false
	_writes += 1
	if _writes > 262144:
		fail("A chunk exceeded its output budget.")
		return false
	var stage: int = _context._entry.slot.stage
	if (channel == "height" and stage != Terrain3DProgramSlot.Stage.HEIGHT) or (channel in ["material", "color"] and stage != Terrain3DProgramSlot.Stage.SURFACE) or (channel == "content" and stage != Terrain3DProgramSlot.Stage.CONTENT):
		fail("Output '%s' is not allowed in this program stage." % channel)
		return false
	return true

func write_height(point: Vector2, value: float, coverage_value: float = 1.0) -> void:
	if _point(point, "height") and is_finite(value):
		var weight := _weight(point, coverage_value)
		if weight > 0:
			layer.data.set_pixel(Vector2i((point / _context.get_spacing()).round()), 0, Color(value, 0, 0), weight, false)
	elif not is_finite(value):
		fail("Height output must be finite.")

func write_material(point: Vector2, role: StringName, coverage_value: float = 1.0) -> void:
	if not _point(point, "material"):
		return
	var id := -1
	for index in layer.slots.size():
		if layer.slots[index] and layer.slots[index].key == role:
			id = index
	if id < 0:
		fail("Undeclared material role: " + str(role))
		return
	var weight := _weight(point, coverage_value)
	if weight > 0:
		layer.data.set_control(Vector2i((point / _context.get_spacing()).round()), (id << 27) | (id << 22), weight)

func write_color(point: Vector2, value: Color, coverage_value: float = 1.0) -> void:
	if _point(point, "color"):
		var weight := _weight(point, coverage_value)
		if weight > 0:
			layer.data.set_pixel(Vector2i((point / _context.get_spacing()).round()), 2, value, weight, false)

func write_mask(key: StringName, point: Vector2, weight: float) -> void:
	if not _point(point, "mask"):
		return
	if not _context._entry.writes.has("mask:" + str(key)):
		fail("Declare the mask output in describe()/Describe(): mask:" + str(key))
		return
	var coverage_value := _weight(point, weight)
	if coverage_value <= 0:
		return
	if not masks.has(key):
		masks[key] = Terrain3DLayerData.new()
		masks[key].spacing = _context.get_spacing()
	masks[key].set_pixel(Vector2i((point / _context.get_spacing()).round()), 0, Color.WHITE, coverage_value, false)

func emit_instance(role: StringName, id: String, pose: Transform3D, color: Color = Color.WHITE, offset: float = 0.0, align_normal: bool = false) -> void:
	var point := Vector2(pose.origin.x, pose.origin.z)
	if not _point(point, "content") or not _pose_valid(pose):
		return
	if _context.random_at(point, hash(id)) >= clampf(_context.coverage(point), 0, 1):
		return
	var slot := -1
	for index in layer.instance_slots.size():
		if layer.instance_slots[index] and layer.instance_slots[index].key == role:
			slot = index
	if slot < 0 or id.is_empty() or layer.scatter_data.records.has(id):
		fail("Unknown instance role or duplicate/empty output ID: %s / %s" % [role, id])
		return
	layer.scatter_data.records[id] = {"slot": slot, "transform": pose, "color": color, "offset": offset, "align_normal": align_normal}

func emit_mesh(id: String, pose: Transform3D, mesh: Mesh, material: Material = null, options: Dictionary = {}) -> void:
	if _node(id, pose):
		if not mesh:
			fail("Mesh output requires a Mesh resource.")
			return
		nodes[id] = {"kind": &"mesh", "pose": pose, "mesh": mesh, "material": material, "options": options.duplicate()}

func emit_decal(id: String, pose: Transform3D, textures: Dictionary, size: Vector3, options: Dictionary = {}) -> void:
	if _node(id, pose):
		for channel: Variant in textures:
			if not str(channel) in ["albedo", "normal", "orm", "emission"] or (textures[channel] != null and not textures[channel] is Texture2D):
				fail("Decal channels require Texture2D resources: " + str(channel))
				return
		if not size.is_finite() or size.x <= 0 or size.y <= 0 or size.z <= 0:
			fail("Decal size must be positive.")
			return
		nodes[id] = {"kind": &"decal", "pose": pose, "textures": textures.duplicate(), "size": size, "options": options.duplicate()}

func _node(id: String, pose: Transform3D) -> bool:
	var point := Vector2(pose.origin.x, pose.origin.z)
	if not _point(point, "content") or not _pose_valid(pose) or _context.coverage(point) <= 0:
		return false
	if id.is_empty() or nodes.has(id):
		fail("Duplicate or empty node ID: " + id)
		return false
	return true

func _pose_valid(pose: Transform3D) -> bool:
	if not pose.is_finite() or absf(pose.basis.determinant()) < 0.000001:
		fail("Output transforms must be finite and invertible.")
		return false
	return true

func set_reference_placement(index: int, pose: Transform3D) -> void:
	if _context._entry.slot.stage != Terrain3DProgramSlot.Stage.HEIGHT or not _pose_valid(pose):
		fail("Reference placements belong to the height planning stage.")
		return
	var id := _context.reference_id(index)
	if not id.is_empty():
		placements[id] = pose

func fail(message: String) -> void:
	if not _errors.has(message):
		_errors.append(message)
