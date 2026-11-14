# Copyright © 2026 Terrain3D Contributors.
@tool
extends EditorNode3DGizmoPlugin

func _init() -> void:
	create_material("paint_layer", Color(0.25, 0.7, 1.0))
	create_material("stamp", Color(1.0, 0.6, 0.15))
	create_material("attachment", Color(0.4, 0.9, 0.45))
	create_icon_material("origin", EditorInterface.get_editor_theme().get_icon("Node3D", "EditorIcons"))

func _has_gizmo(node: Node3D) -> bool:
	return (node is Terrain3DLayer and not node is Terrain3DGeneratedLayer) or node is Terrain3DAttachmentGroup

func _get_gizmo_name() -> String:
	return "Terrain Placement"

func _is_selectable_when_hidden() -> bool:
	return true

func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	gizmo.add_unscaled_billboard(get_material("origin", gizmo), 0.04)
	var node := gizmo.get_node_3d()
	if node is Terrain3DAttachmentGroup:
		_draw_attachment(gizmo, node)
	elif node is Terrain3DLayer:
		_draw_layer(gizmo, node)

func _surface_point(layer: Terrain3DLayer, point: Vector2) -> Vector3:
	var world := layer._source_to_world(point)
	var height := layer.global_position.y
	var host := layer.get_terrain()
	if host and host.data:
		var surface := host.data.get_surface_height(Vector3(world.x, 0, world.y))
		if is_finite(surface):
			height = surface
	return layer.to_local(Vector3(world.x, height, world.y))

func _draw_layer(gizmo: EditorNode3DGizmo, layer: Terrain3DLayer) -> void:
	if not layer.is_transform_valid():
		return
	var rect := layer.source_content_bounds()
	if not rect.has_area():
		rect = Rect2(layer.pivot - Vector2.ONE, Vector2.ONE * 2)
	var lines := PackedVector3Array()
	var triangles := PackedVector3Array()
	# A small surface proxy enables viewport picking and F framing, including generators.
	const STEPS := 4
	for y in STEPS:
		for x in STEPS:
			var a := rect.position + rect.size * Vector2(x, y) / STEPS
			var b := rect.position + rect.size * Vector2(x + 1, y) / STEPS
			var c := rect.position + rect.size * Vector2(x + 1, y + 1) / STEPS
			var d := rect.position + rect.size * Vector2(x, y + 1) / STEPS
			var points := [_surface_point(layer, a), _surface_point(layer, b), _surface_point(layer, c), _surface_point(layer, d)]
			triangles.append_array(PackedVector3Array([points[0], points[2], points[1], points[0], points[3], points[2]]))
			if y == 0: lines.append_array(PackedVector3Array([points[0], points[1]]))
			if x == STEPS - 1: lines.append_array(PackedVector3Array([points[1], points[2]]))
			if y == STEPS - 1: lines.append_array(PackedVector3Array([points[2], points[3]]))
			if x == 0: lines.append_array(PackedVector3Array([points[3], points[0]]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = triangles
	var surface := ArrayMesh.new()
	surface.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	gizmo.add_collision_triangles(surface.generate_triangle_mesh())
	gizmo.add_lines(lines, get_material("stamp" if layer is Terrain3DStamp else "paint_layer", gizmo))
	gizmo.add_collision_segments(lines)

func _draw_attachment(gizmo: EditorNode3DGizmo, group: Terrain3DAttachmentGroup) -> void:
	if not group.settings or absf(group.global_basis.determinant()) < 0.00001:
		return
	var lines := PackedVector3Array()
	var interaction := group.terrain_interaction
	var footprint := interaction.footprint if interaction else PackedVector2Array([Vector2(-1,-1), Vector2(1,-1), Vector2(1,1), Vector2(-1,1)])
	for target: Node3D in group._targets().values():
		var anchor := interaction.anchor if interaction else group.settings.anchor
		var marker_path := interaction.anchor_marker if interaction else group.settings.anchor_marker
		var marker := target.get_node_or_null(marker_path) as Node3D if not marker_path.is_empty() else null
		if marker:
			anchor = target.to_local(marker.global_position)
		for index in footprint.size():
			for point: Vector2 in [footprint[index], footprint[(index + 1) % footprint.size()]]:
				lines.append(group.to_local(target.global_transform * Vector3(point.x, anchor.y, point.y)))
	if lines.is_empty():
		lines = PackedVector3Array([Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK, Vector3.DOWN, Vector3.UP])
	gizmo.add_lines(lines, get_material("attachment", gizmo))
	gizmo.add_collision_segments(lines)
