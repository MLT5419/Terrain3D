# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DScatterBrush
extends RefCounted
## Editor stroke adapter. Only source records and source suppression coverage are edited.

static func paint(layer: Terrain3DLayer, center: Vector3, brush: Dictionary, operation: int, stroke: Dictionary, camera_angle: float = 0) -> void:
	var source := layer.scatter_data
	var host := layer.get_terrain()
	var radius := maxf(brush.get("size", 10.0) * 0.5, 0.05)
	var strength := clampf(brush.get("strength", 0.1), 0.01, 100)
	var pressure: float = brush.get("mouse_pressure", 1.0)
	strength *= pressure if pressure > 0 else 1.0
	var selected: Array = brush.get("mesh_asset_ids", [])
	var erase: bool = layer.erase_mode or operation == Terrain3DEditor.SUBTRACT or brush.get("modifier_ctrl", false)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([source.seed, source.next_id, stroke.get("step", 0)])
	brush = brush.duplicate()
	brush["_scatter_rotation"] = rng.randf() * PI * brush.get("brush_spin_speed", 0.0) + (camera_angle if brush.get("align_to_view", false) else 0.0)
	stroke.step = int(stroke.get("step", 0)) + 1
	if brush.get("on_collision", false):
		if not stroke.get("collision_warning", false):
			push_warning("Layer instances attach to the composed terrain. Collision-ray placement is available on the base terrain only.")
			stroke.collision_warning = true
		return
	if erase:
		for id: String in source.records.keys():
			var record: Dictionary = source.records[id]
			var local: Transform3D = record.transform
			var world := layer._source_to_world(Vector2(local.origin.x, local.origin.z))
			if (selected.is_empty() or selected.has(record.slot)) and rng.randf() < _alpha(brush, (world - Vector2(center.x, center.z)) / radius) * minf(strength, 1):
				source.records.erase(id)
				stroke.changed = true
	elif layer.instance_mode != Terrain3DLayer.InstanceMode.MASK_LOWER:
		var density: float = PI * radius * radius * layer.paint_density * strength * 0.02
		stroke.density = float(stroke.get("density", 0.99)) + density
		var count := mini(floori(stroke.density), 2000)
		stroke.density -= count
		for index in count:
			if selected.is_empty():
				break
			var slot_id: int = selected[rng.randi_range(0, selected.size() - 1)]
			if slot_id < 0 or slot_id >= layer.instance_slots.size():
				continue
			var angle := rng.randf() * TAU
			var distance := sqrt(rng.randf()) * radius
			var world := center + Vector3(cos(angle), 0, sin(angle)) * distance
			if rng.randf() > _alpha(brush, Vector2(world.x - center.x, world.z - center.z) / radius):
				continue
			var height := host.data.get_surface_height(world)
			if not is_finite(height):
				continue
			var normal := host.data.get_normal(world)
			var slope := rad_to_deg(Vector3.UP.angle_to(normal)) if normal.is_finite() else 0.0
			var range_value: Vector2 = brush.get("slope", Vector2(0, 90))
			if slope < range_value.x or slope > range_value.y:
				continue
			var point := layer.source_position(Vector2(world.x, world.z))
			var spin := deg_to_rad(brush.get("fixed_spin", 0.0) + rng.randf() * brush.get("random_spin", 360.0))
			var tilt := deg_to_rad(brush.get("fixed_tilt", 0.0) + rng.randf_range(-1, 1) * brush.get("random_tilt", 10.0))
			var scale_value := maxf(0.01, brush.get("fixed_scale", 100.0) * 0.01 + rng.randf_range(-1, 1) * brush.get("random_scale", 0.0) * 0.01)
			var basis := Basis(Vector3.UP, spin) * Basis(Vector3.RIGHT, tilt)
			basis = basis.scaled(Vector3.ONE * scale_value)
			# Source yaw excludes the layer's placement rotation.
			basis = Terrain3DPlacementSolver.parent_rotation(layer).inverse() * basis
			var color: Color = brush.get("vertex_color", Color.WHITE)
			color.h = fposmod(color.h + rng.randf_range(-1, 1) * brush.get("random_hue", 0.0) / 360.0, 1.0)
			color.v = maxf(0, color.v - rng.randf() * brush.get("random_darken", 0.0) * 0.01)
			var offset: float = brush.get("height_offset", 0.0) + rng.randf_range(-1, 1) * brush.get("random_height", 0.0)
			var local_y := 0.0
			if layer.instance_placement and layer.instance_placement.mode == Terrain3DAttachmentSettings.Mode.NONE and absf(layer.global_basis.y.y) > 0.00001:
				local_y = (height + offset - layer.global_position.y) / layer.global_basis.y.y
			source.add_instance(slot_id, Transform3D(basis, Vector3(point.x, local_y, point.y)), color, offset, brush.get("align_to_normal", false), false)
			stroke.changed = true
	if layer.instance_mode != Terrain3DLayer.InstanceMode.ADD:
		stroke.changed = _paint_mask(layer, center, radius, strength, erase, brush) or stroke.get("changed", false)
	if stroke.get("changed", false):
		source.emit_changed()

static func _alpha(brush: Dictionary, point: Vector2) -> float:
	if point.length_squared() > 1:
		return 0
	point = point.rotated(-float(brush.get("_scatter_rotation", 0.0)))
	var images: Array = brush.get("brush", [])
	if images.is_empty() or not images[0] is Image:
		return 1
	var image: Image = images[0]
	var uv := (point + Vector2.ONE) * 0.5
	return pow(clampf(image.get_pixel(mini(int(uv.x * image.get_width()), image.get_width() - 1), mini(int(uv.y * image.get_height()), image.get_height() - 1)).r, 0, 1), brush.get("gamma", 1.0))

static func _paint_mask(layer: Terrain3DLayer, center: Vector3, radius: float, strength: float, erase: bool, brush: Dictionary) -> bool:
	var mask := layer.scatter_data.mask
	if not mask:
		mask = Terrain3DLayerData.new()
		layer.scatter_data.mask = mask
	var source_bounds := Rect2(layer.source_position(Vector2(center.x - radius, center.z - radius)), Vector2.ZERO)
	for corner in [Vector2(center.x + radius, center.z - radius), Vector2(center.x + radius, center.z + radius), Vector2(center.x - radius, center.z + radius)]:
		source_bounds = source_bounds.expand(layer.source_position(corner))
	var first := Vector2i((source_bounds.position / mask.spacing).floor())
	var last := Vector2i((source_bounds.end / mask.spacing).ceil())
	var changed := false
	mask.begin_edit()
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			var pixel := Vector2i(x, y)
			var point := layer._source_to_world(Vector2(pixel) * mask.spacing)
			var alpha := _alpha(brush, (point - Vector2(center.x, center.z)) / radius) * strength
			if alpha <= 0:
				continue
			var coverage := mask.get_pixel(pixel, Terrain3DLayerData.MASK).r
			if (erase and coverage <= 0) or (not erase and coverage >= 1):
				continue
			changed = true
			if erase:
				mask.erase(pixel, 0, alpha, false)
			else:
				mask.set_pixel(pixel, 0, Color.WHITE, minf(1, coverage + alpha), false)
	mask.end_edit()
	return changed
