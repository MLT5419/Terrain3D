# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DProgramContext
extends RefCounted
## Variant-compatible API: C# uses GodotObject.Call; GDScript calls the same methods directly.

var _snapshot: Terrain3DProgramSnapshot
var _entry: Dictionary
var _references: Array[Dictionary] = []
var _bounds := Rect2()
var _spacing := 1.0
var _chunk := Vector2i.ZERO
var _revision := 0
var _errors := PackedStringArray()

func get_bounds() -> Rect2:
	return _bounds

func get_spacing() -> float:
	return _spacing

func get_chunk() -> Vector2i:
	return _chunk

func get_seed() -> int:
	return _entry.slot.seed

func get_revision() -> int:
	return _revision

func parameter(key: StringName, fallback: Variant = null) -> Variant:
	return _entry.slot.parameters.get(key, fallback)

func resource(key: StringName) -> Resource:
	return _entry.slot.resources.get(key)

func sample_points() -> PackedVector2Array:
	var result := PackedVector2Array()
	var first := Vector2i((_bounds.position / _spacing).ceil())
	var last := Vector2i((_bounds.end / _spacing).ceil())
	for y in range(first.y, last.y):
		for x in range(first.x, last.x):
			result.append(Vector2(x, y) * _spacing)
	return result

func to_world(point: Vector2) -> Vector2:
	var owner: Terrain3DLayer = _entry.owner
	return owner._source_to_world(point) if owner else point

func to_source(world: Vector2) -> Vector2:
	var owner: Terrain3DLayer = _entry.owner
	return owner.source_position(world) if owner else world

func to_source_height(world_height: float) -> float:
	var owner: Terrain3DLayer = _entry.owner
	return owner.source_height(world_height) if owner else world_height

func height(point: Vector2) -> float:
	if not _entry.reads.has("height") and not _entry.reads.has("final_height"):
		fail("Declare height/final_height in describe()/Describe() before querying height.")
		return NAN
	return _snapshot.height(to_world(point))

func slope(point: Vector2) -> float:
	if not _entry.reads.has("height") and not _entry.reads.has("final_height"):
		fail("Declare height/final_height before querying slope.")
		return 90
	var world := to_world(point)
	var step := _snapshot.spacing
	var h := _snapshot.height(world)
	var hx := _snapshot.height(world + Vector2(step, 0))
	var hz := _snapshot.height(world + Vector2(0, step))
	if not is_finite(h) or not is_finite(hx) or not is_finite(hz):
		return 90
	return rad_to_deg(Vector3.UP.angle_to(Vector3(h - hx, step, h - hz).normalized()))

func coverage(point: Vector2, role: StringName = &"") -> float:
	var bound: StringName = _entry.role
	var world := to_world(point)
	var owner: Terrain3DLayer = _entry.owner
	var value := 1.0
	if not bound.is_empty():
		if _entry.slot.stage == Terrain3DProgramSlot.Stage.HEIGHT and owner:
			value = 0
			if owner.data:
				var local := owner.source_position(world)
				var bits := owner.data.get_control(Vector2i((local / owner.data.spacing).round()))
				if bits & 1 and owner.data.sample_coverage(local, 1) > 0:
					fail("GPU autoshader coverage is unavailable to height programs.")
					return 0
				var blend := float((bits >> 14) & 255) / 255.0
				for index in 2:
					var id: int = (bits >> (22 if index else 27)) & 31
					if id < owner.slots.size() and owner.slots[id] and owner.slots[id].key == bound:
						value += (blend if index else 1 - blend) * owner.data.sample_coverage(local, 1)
		else:
			value = _snapshot.role_weight(world, bound, owner, true)
	if not role.is_empty():
		value *= _snapshot.role_weight(world, role)
	if value < 0:
		fail("GPU autoshader coverage is unavailable to programs; use an explicit surface classifier or named mask.")
		return 0
	return value

func mask_weight(key: StringName, point: Vector2) -> float:
	var token := "mask:" + str(key)
	var optional := "mask?:" + str(key)
	if not _entry.reads.has(token) and not _entry.reads.has(optional):
		fail("Declare the mask dependency in describe()/Describe(): " + token)
		return 0
	return _snapshot.mask_weight(to_world(point), key)

func random_at(point: Vector2, stream: int = 0) -> float:
	return float(hash([get_seed(), _entry.slot.uid, Vector2i((point / _spacing).round()), stream]) & 0x7fffffff) / 2147483648.0

func reference_pose(index: int = 0) -> Transform3D:
	if index < 0 or index >= _references.size():
		fail("Missing reference pose %s." % index)
		return Transform3D.IDENTITY
	return _references[index].pose

func reference_resource(index: int = 0) -> Resource:
	return _references[index].get("interaction") if index >= 0 and index < _references.size() else null

func reference_anchor(index: int = 0) -> Vector3:
	return _references[index].get("anchor", Vector3.ZERO) if index >= 0 and index < _references.size() else Vector3.ZERO

func world_pose_to_source(pose: Transform3D) -> Transform3D:
	var owner: Terrain3DLayer = _entry.owner
	if not owner:
		return pose
	var point := owner.source_position(Vector2(pose.origin.x, pose.origin.z))
	var basis := Terrain3DPlacementSolver.parent_rotation(owner).inverse() * pose.basis
	var local_y := (pose.origin.y - owner.global_position.y) / owner.global_basis.y.y if absf(owner.global_basis.y.y) > 0.00001 else 0.0
	return Transform3D(basis, Vector3(point.x, local_y, point.y))

func reference_id(index: int = 0) -> String:
	return _references[index].get("id", "") if index >= 0 and index < _references.size() else ""

func fail(message: String) -> void:
	if not _errors.has(message):
		_errors.append(message)
