# Copyright © 2026 Terrain3D Contributors.
@tool
extends RefCounted

func describe() -> Dictionary:
	return {"reads": [], "writes": ["height"], "version": 1}

func generate(context: Object, output: Object) -> bool:
	var noise := FastNoiseLite.new()
	noise.seed = context.get_seed()
	noise.frequency = context.parameter(&"frequency", 0.035)
	var amplitude: float = context.parameter(&"amplitude", 6.0)
	var base: float = context.parameter(&"base_height", 0.0)
	for point: Vector2 in context.sample_points():
		output.write_height(point, base + amplitude * noise.get_noise_2dv(point))
	return true
