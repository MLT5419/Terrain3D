# Copyright © 2026 Terrain3D Contributors.
@tool
extends RefCounted

func describe() -> Dictionary:
	return {"reads": ["final_height"], "writes": ["material", "mask:surface.grass"], "version": 1}

func generate(context: Object, output: Object) -> bool:
	var maximum: float = context.parameter(&"maximum_slope", 30.0)
	var grass := StringName(context.parameter(&"grass_role", "surface.grass"))
	var rock := StringName(context.parameter(&"rock_role", "surface.rock"))
	for point: Vector2 in context.sample_points():
		if not is_finite(context.height(point)):
			continue
		var grassy: bool = context.slope(point) <= maximum
		output.write_material(point, grass if grassy else rock)
		output.write_mask(&"surface.grass", point, 1.0 if grassy else 0.0)
	return true
