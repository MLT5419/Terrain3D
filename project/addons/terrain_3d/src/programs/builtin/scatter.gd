# Copyright © 2026 Terrain3D Contributors.
@tool
extends RefCounted

func describe() -> Dictionary:
	return {"reads": ["final_height", "mask?:terrain.clearance"], "writes": ["instances"], "version": 1}

func generate(context: Object, output: Object) -> bool:
	var density: float = context.parameter(&"density", 0.15)
	var role := StringName(context.parameter(&"instance_role", "nature.grass"))
	var mask := StringName(context.parameter(&"surface_mask", ""))
	if not mask.is_empty():
		context.fail("Use a material-slot binding for surface filtering, or declare a named mask in a custom program's describe method.")
		return false
	for point: Vector2 in context.sample_points():
		if not is_finite(context.height(point)) or context.mask_weight(&"terrain.clearance", point) >= 0.5:
			continue
		if context.random_at(point) >= clampf(density * pow(context.get_spacing(), 2), 0, 1):
			continue
		var scale := lerpf(0.7, 1.3, context.random_at(point, 1))
		var basis := Basis(Vector3.UP, context.random_at(point, 2) * TAU).scaled(Vector3.ONE * scale)
		output.emit_instance(role, str(point), Transform3D(basis, Vector3(point.x, 0, point.y)))
	return true
