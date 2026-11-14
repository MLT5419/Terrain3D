# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DPlacementSolver
extends RefCounted
## Stateless solver: always starts from an authored pose, never from its previous output.

static func resolve_host(node: Node) -> Terrain3D:
	var parent := node.get_parent()
	var preview: Terrain3D
	while parent:
		if parent is Terrain3D:
			return parent
		if not preview and parent is Terrain3DLayer:
			preview = parent.get_terrain()
		parent = parent.get_parent()
	return preview

static func layer_enabled(node: Node) -> bool:
	var parent := node.get_parent()
	while parent:
		if parent is Terrain3D:
			break
		if parent is Terrain3DLayer and not parent.enabled:
			return false
		parent = parent.get_parent()
	return true

static func parent_rotation(node: Node3D) -> Basis:
	var bases: Array[Basis] = []
	var current := node
	while current:
		bases.append(current.transform.basis.orthonormalized())
		if current.top_level:
			break
		current = current.get_parent_node_3d()
	var result := Basis.IDENTITY
	for index in range(bases.size() - 1, -1, -1):
		result = result * bases[index]
	return result

static func authored_global(parent: Node3D, local: Transform3D, inherit_scale: bool) -> Transform3D:
	if not parent:
		return local
	var result := parent.global_transform * local
	if not inherit_scale:
		result.basis = parent_rotation(parent) * local.basis
	return result

static func _height(terrain: Terrain3D, point: Vector3) -> float:
	return terrain.data.get_surface_height(point) if terrain and terrain.data else NAN

static func _tilted(basis: Basis, normal: Vector3, limit: float) -> Basis:
	if not normal.is_finite() or normal.length_squared() < 0.000001:
		return basis
	normal = normal.normalized()
	var angle := Vector3.UP.angle_to(normal)
	if angle > deg_to_rad(limit) and angle > 0.00001:
		normal = Vector3.UP.slerp(normal, deg_to_rad(limit) / angle)
	return Basis(Quaternion(Vector3.UP, normal)) * basis

static func solve(terrain: Terrain3D, authored: Transform3D, policy: Terrain3DAttachmentSettings, offset: float = 0.0) -> Dictionary:
	if policy.mode == Terrain3DAttachmentSettings.Mode.NONE:
		return {"valid": true, "transform": authored}
	if not terrain or not terrain.data:
		return {"valid": false}
	var result := authored
	var footprint := policy.mode in [policy.Mode.FOOTPRINT_MAX, policy.Mode.FOOTPRINT_MIN, policy.Mode.FOOTPRINT_AVERAGE, policy.Mode.FOOTPRINT_PLANE]
	var supports := policy.support_points if footprint and not policy.support_points.is_empty() else PackedVector3Array([policy.anchor])
	if policy.mode == policy.Mode.ALIGN_NORMAL:
		result.basis = _tilted(authored.basis, terrain.data.get_normal(authored * policy.anchor), policy.max_tilt_degrees)
	if policy.mode == policy.Mode.FOOTPRINT_PLANE and supports.size() >= 3:
		var xx := 0.0
		var xz := 0.0
		var zz := 0.0
		var sx := 0.0
		var sz := 0.0
		var sh := 0.0
		var xh := 0.0
		var zh := 0.0
		var count := 0
		for support in supports:
			var delta := authored.basis * support
			var h := _height(terrain, authored.origin + delta)
			if not is_finite(h):
				if policy.require_all_supports:
					return {"valid": false}
				continue
			xx += delta.x * delta.x
			xz += delta.x * delta.z
			zz += delta.z * delta.z
			sx += delta.x
			sz += delta.z
			sh += h
			xh += delta.x * h
			zh += delta.z * h
			count += 1
		var matrix := Basis(Vector3(xx, xz, sx), Vector3(xz, zz, sz), Vector3(sx, sz, count))
		if absf(matrix.determinant()) > 0.000001:
			var fit := matrix.inverse() * Vector3(xh, zh, sh)
			result.basis = _tilted(authored.basis, Vector3(-fit.x, 1, -fit.y), policy.max_tilt_degrees)
	var heights: Array[float] = []
	for support in supports:
		var delta := result.basis * support
		var h := _height(terrain, authored.origin + delta)
		if not is_finite(h):
			if policy.require_all_supports:
				return {"valid": false}
			continue
		heights.append(h - delta.y)
	if heights.is_empty():
		return {"valid": false}
	var height := 0.0
	if policy.mode == policy.Mode.FOOTPRINT_MAX:
		height = heights.max()
	elif policy.mode == policy.Mode.FOOTPRINT_MIN:
		height = heights.min()
	else:
		for value in heights:
			height += value / heights.size()
	result.origin.y = height + policy.height_offset + (0.0 if policy.mode == policy.Mode.SNAP else offset)
	return {"valid": true, "transform": result}
