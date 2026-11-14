# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DScatterData
extends Resource
## Source instances survive holes, masks, disabled layers, and palette recompilation.

const FORMAT_VERSION := 1
@export_storage var version := FORMAT_VERSION
@export_storage var records: Dictionary = {}
@export_storage var next_id := 1
@export var seed := 5419:
	set(value):
		seed = value
		emit_changed()
## Height-channel coverage is the suppression weight, not a height contribution.
@export var mask: Terrain3DLayerData = Terrain3DLayerData.new():
	set(value):
		if mask and mask.changed.is_connected(_mask_changed):
			mask.changed.disconnect(_mask_changed)
		mask = value
		if mask:
			mask.changed.connect(_mask_changed)
		emit_changed()

func _mask_changed() -> void:
	emit_changed()

func add_instance(slot: int, pose: Transform3D, color: Color = Color.WHITE, offset: float = 0.0, align_normal: bool = false, notify: bool = true) -> String:
	var id := "%s:%s" % [seed, next_id]
	next_id += 1
	records[id] = {"slot": slot, "transform": pose, "color": color, "offset": offset, "align_normal": align_normal}
	if notify:
		emit_changed()
	return id

func remove_instance(id: String) -> void:
	if records.erase(id):
		emit_changed()

func clone_source() -> Terrain3DScatterData:
	var copy := Terrain3DScatterData.new()
	copy.version = version
	copy.records = records.duplicate(true)
	copy.next_id = next_id
	copy.seed = seed
	copy.mask = mask.clone_source() if mask else null
	return copy

func get_used_slots() -> Array[int]:
	var result: Array[int] = []
	for record: Dictionary in records.values():
		var slot: int = record.get("slot", -1)
		if not result.has(slot):
			result.append(slot)
	return result

func get_bounds() -> Rect2:
	var result := mask.get_bounds() if mask else Rect2()
	for record: Dictionary in records.values():
		var pose: Transform3D = record.transform
		var point := Rect2(Vector2(pose.origin.x, pose.origin.z) - Vector2.ONE * 0.5, Vector2.ONE)
		result = result.merge(point) if result.has_area() else point
	return result

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
