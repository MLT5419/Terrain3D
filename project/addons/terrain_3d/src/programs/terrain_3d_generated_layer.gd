# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DGeneratedLayer
extends Terrain3DLayer
## Internal contribution. Never subscribes to authoring invalidation or saves source resources.

var host: Terrain3D
var owner_layer: Terrain3DLayer

func _ready() -> void:
	set_process(false)

func _exit_tree() -> void:
	pass

func _notification(_what: int) -> void:
	pass

func _changed() -> void:
	pass

func _data_changed() -> void:
	pass

func get_terrain() -> Terrain3D:
	return host

func participates() -> bool:
	return enabled and (not owner_layer or owner_layer.participates())

func uses_local_transform() -> bool:
	return true

func is_transform_valid() -> bool:
	return not owner_layer or owner_layer.is_transform_valid()

func source_position(world: Vector2) -> Vector2:
	return owner_layer.source_position(world) if owner_layer else world

func _source_to_world(source: Vector2) -> Vector2:
	return owner_layer._source_to_world(source) if owner_layer else source

func source_bounds() -> Rect2:
	if not data:
		return Rect2()
	var area := data.get_bounds().grow(data.spacing)
	var result := Rect2(_source_to_world(area.position), Vector2.ZERO)
	for corner in [area.end, Vector2(area.position.x, area.end.y), Vector2(area.end.x, area.position.y)]:
		result = result.expand(_source_to_world(corner))
	return result

func height_value(value: float) -> float:
	return owner_layer.height_value(value) if owner_layer else value

func source_height(value: float) -> float:
	return owner_layer.source_height(value) if owner_layer else value

func instance_world_pose(pose: Transform3D, inherit_scale: bool) -> Transform3D:
	return owner_layer.instance_world_pose(pose, inherit_scale) if owner_layer else pose
