# Copyright © 2026 Terrain3D Contributors.
@tool
extends EditorNode3DGizmoPlugin

func _init() -> void:
	create_material("paint_layer", Color(0.25, 0.7, 1.0))
	create_material("stamp", Color(1.0, 0.6, 0.15))

func _has_gizmo(node: Node3D) -> bool:
	return node is Terrain3DLayer

func _get_gizmo_name() -> String:
	return "Terrain Layer"

func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var layer := gizmo.get_node_3d() as Terrain3DLayer
	if not layer.data:
		return
	var rect := layer.data.get_bounds()
	var points := PackedVector3Array()
	var corners := [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]
	for index in 4:
		for corner: Vector2 in [corners[index], corners[(index + 1) % 4]]:
			var world := layer._source_to_world(corner)
			points.append(layer.to_local(Vector3(world.x, layer.global_position.y, world.y)))
	gizmo.add_lines(points, get_material("stamp" if layer.uses_local_transform() else "paint_layer", gizmo))
	gizmo.add_collision_segments(points)
