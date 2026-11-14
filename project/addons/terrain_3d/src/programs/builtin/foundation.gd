# Copyright © 2026 Terrain3D Contributors.
@tool
extends RefCounted

func describe() -> Dictionary:
	return {"reads": ["height", "references"], "writes": ["height", "mask:terrain.clearance"], "version": 1}

func generate(context: Object, output: Object) -> bool:
	var interaction: Terrain3DTerrainInteraction = context.reference_resource()
	var pose: Transform3D = context.reference_pose()
	var anchor: Vector3 = context.reference_anchor()
	if interaction.footprint.size() < 3 or absf(pose.basis.determinant()) < 0.00001:
		context.fail("Terrain interaction needs a footprint polygon and a nonsingular model transform.")
		return false
	if interaction.mode == Terrain3DTerrainInteraction.Mode.PLACE_THEN_TERRAFORM:
		var contact := pose * anchor
		var height: float = context.height(context.to_source(Vector2(contact.x, contact.z)))
		if not is_finite(height):
			context.fail("Place Then Terraform needs an existing input surface under the contact anchor.")
			return false
		pose.origin.y += height + interaction.height_offset - contact.y
	output.set_reference_placement(0, pose)
	var normal := pose.basis.inverse().transposed() * Vector3.UP
	if absf(normal.y) < 0.0001:
		context.fail("The model contact plane cannot be vertical in a heightfield.")
		return false
	var contact := pose * anchor
	if interaction.mode == Terrain3DTerrainInteraction.Mode.TERRAIN_FOLLOWS_MODEL:
		contact.y += interaction.height_offset
	var polygon := PackedVector2Array()
	for point in interaction.footprint:
		var world := pose * Vector3(point.x, anchor.y, point.y)
		polygon.append(Vector2(world.x, world.z))
	for point: Vector2 in context.sample_points():
		var world: Vector2 = context.to_world(point)
		var distance := INF
		for index in polygon.size():
			distance = minf(distance, world.distance_to(Geometry2D.get_closest_point_to_segment(world, polygon[index], polygon[(index + 1) % polygon.size()])))
		if Geometry2D.is_point_in_polygon(world, polygon):
			distance = 0
		var clearance := 1.0 - smoothstep(interaction.margin + interaction.clearance, interaction.margin + interaction.clearance + maxf(interaction.falloff, 0.001), distance)
		if clearance > 0:
			output.write_mask(&"terrain.clearance", point, clearance)
		var weight := 1.0 - smoothstep(interaction.margin, interaction.margin + maxf(interaction.falloff, 0.001), distance)
		if weight <= 0:
			continue
		var target := contact.y - (normal.x * (world.x - contact.x) + normal.z * (world.y - contact.z)) / normal.y
		var original: float = context.height(point)
		if not is_finite(original):
			original = 0
		target = clampf(target, original - interaction.maximum_cut, original + interaction.maximum_fill)
		output.write_height(point, context.to_source_height(target), weight)
	return true
