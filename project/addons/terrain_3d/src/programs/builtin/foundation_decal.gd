# Copyright © 2026 Terrain3D Contributors.
@tool
extends RefCounted

func describe() -> Dictionary:
	return {"reads": ["final_height", "references"], "writes": ["decals"], "version": 1}

func generate(context: Object, output: Object) -> bool:
	var interaction: Terrain3DTerrainInteraction = context.reference_resource()
	var pose: Transform3D = context.reference_pose()
	var center := Vector2(pose.origin.x, pose.origin.z)
	var source: Vector2 = context.to_source(center)
	if not context.get_bounds().has_point(source):
		return true
	var bounds := Rect2(interaction.footprint[0], Vector2.ZERO)
	for point in interaction.footprint:
		bounds = bounds.expand(point)
	bounds = bounds.grow(interaction.margin + interaction.falloff)
	var textures := {"albedo": interaction.decal_albedo, "normal": interaction.decal_normal, "orm": interaction.decal_orm, "emission": interaction.decal_emission}
	output.emit_decal("foundation", context.world_pose_to_source(pose), textures, Vector3(bounds.size.x, interaction.decal_depth, bounds.size.y), {"modulate": interaction.decal_modulate})
	return true
