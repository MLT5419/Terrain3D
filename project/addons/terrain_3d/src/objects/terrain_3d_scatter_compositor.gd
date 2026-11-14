# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DScatterCompositor
extends RefCounted
## Derived instance output owned by one terrain, never by a shared source resource.

var remaps := {}
var _scene_root: Node3D
var _scenes := {}
var _output_hash := 0
var _palette_hash := 0
var _base_gaps := {}

func resolve_palette(stack: Terrain3DLayerStack, resources: Array[Terrain3DMeshAsset]) -> bool:
	remaps.clear()
	var identities := {}
	for index in resources.size():
		if not resources[index]:
			stack.errors.append("Base terrain has an empty mesh entry.")
			return false
		identities[resources[index].get_instance_id()] = index
		stack._watch(resources[index])
	for layer in stack.layers:
		if not layer.participates() or not layer.scatter_data:
			continue
		if layer.scatter_data.version != Terrain3DScatterData.FORMAT_VERSION:
			stack.errors.append("%s: unsupported instance data version." % layer.name)
			return false
		if layer.instance_slots.size() > Terrain3DAssets.MAX_MESHES:
			stack.errors.append("%s: a layer supports at most 256 local instance slots." % layer.name)
			return false
		var keys := {}
		for slot in layer.instance_slots:
			if not slot or slot.key.is_empty() or keys.has(slot.key):
				stack.errors.append("%s: instance slot keys must be nonempty and unique." % layer.name)
				return false
			keys[slot.key] = true
		var map := {}
		for local_id in layer.scatter_data.get_used_slots() if layer.instance_mode != Terrain3DLayer.InstanceMode.MASK_LOWER else []:
			if local_id >= 0 and local_id < layer.instance_slots.size() and layer.instance_slots[local_id] and not layer.instance_slots[local_id].enabled:
				continue
			var resource := layer.resolve_instance_slot(local_id, stack.host.has_meta("_terrain3d_preview_owner") and not stack.exporting)
			if not resource:
				stack.errors.append("%s: no instance resource bound to local slot %s." % [layer.name, local_id])
				return false
			var slot := layer.instance_slots[local_id]
			var mesh_id := -1
			if slot.kind == Terrain3DInstanceSlot.Kind.MESH:
				var identity := resource.get_instance_id()
				if not identities.has(identity):
					identities[identity] = resources.size()
					resources.append(resource)
				mesh_id = identities[identity]
				stack._watch(resource)
			elif not _valid_scene(resource):
				stack.errors.append("%s: instance scenes need a Node3D root and cannot contain terrain authoring nodes." % layer.name)
				return false
			map[local_id] = {"resource": resource, "mesh": mesh_id, "key": slot.key, "category": slot.category}
		remaps[layer.get_instance_id()] = map
	if resources.size() > Terrain3DAssets.MAX_MESHES:
		stack.errors.append("The composed terrain exceeds 256 mesh assets. Reuse resources or change bindings.")
		return false
	return true

func _valid_scene(scene: PackedScene, seen: Dictionary = {}, check_root: bool = true) -> bool:
	if seen.has(scene):
		return true
	seen[scene] = true
	var state := scene.get_state()
	var root_type := state.get_node_type(0)
	if check_root and not root_type.is_empty() and not ClassDB.is_parent_class(root_type, &"Node3D"):
		return false
	for index in state.get_node_count():
		var nested := state.get_node_instance(index)
		if nested and not _valid_scene(nested, seen, false):
			return false
		if state.get_node_type(index) == &"Terrain3D":
			return false
		for property in state.get_node_property_count(index):
			var value: Variant = state.get_node_property_value(index, property)
			if value is Script:
				while value:
					if value.get_global_name() in [&"Terrain3DLayer", &"Terrain3DAttachmentGroup"]:
						return false
					value = value.get_base_script()
	return true

static func _fraction(id: String, seed_value: int) -> float:
	return float(hash([id, seed_value]) & 0x7fffffff) / 2147483648.0

func capture_base(stack: Terrain3DLayerStack) -> void:
	_base_gaps.clear()
	for location: Vector2i in stack._base:
		var region: Terrain3DRegion = stack._base[location]
		var region_offset := Vector3(location.x, 0, location.y) * stack.host.region_size * stack.host.vertex_spacing
		for mesh_id: int in region.instances:
			for cell: Vector2i in region.instances[mesh_id]:
				var triple: Array = region.instances[mesh_id][cell]
				for index in triple[0].size():
					var pose: Transform3D = triple[0][index]
					pose.origin += region_offset
					var height := stack.host.data.get_surface_height(pose.origin)
					_base_gaps[_base_id(location, mesh_id, cell, index)] = pose.origin.y - height if is_finite(height) else 0.0

static func _base_id(location: Vector2i, mesh_id: int, cell: Vector2i, index: int) -> String:
	return "base:%s:%s:%s:%s" % [location, mesh_id, cell, index]

func compose(stack: Terrain3DLayerStack) -> void:
	var host := stack.host
	var records: Array[Dictionary] = []
	var base_policy := Terrain3DAttachmentSettings.new()
	for location: Vector2i in stack._base:
		var region: Terrain3DRegion = stack._base[location]
		if region.is_deleted():
			continue
		var region_offset := Vector3(location.x, 0, location.y) * host.region_size * host.vertex_spacing
		for mesh_id: int in region.instances:
			for cell: Vector2i in region.instances[mesh_id]:
				var triple: Array = region.instances[mesh_id][cell]
				for index in triple[0].size():
					var pose: Transform3D = triple[0][index]
					pose.origin += region_offset
					var id := _base_id(location, mesh_id, cell, index)
					records.append({"id": id, "mesh": mesh_id, "key": StringName("base.mesh_%s" % mesh_id), "category": &"mesh", "pose": pose, "policy": base_policy, "offset": _base_gaps.get(id, 0.0), "color": triple[1][index] if index < triple[1].size() else Color.WHITE})
	for layer in stack.layers:
		if not layer.participates() or not layer.scatter_data or not layer.is_transform_valid():
			continue
		var source := layer.scatter_data
		if layer.instance_mode != Terrain3DLayer.InstanceMode.ADD and source.mask:
			for index in range(records.size() - 1, -1, -1):
				var record := records[index]
				if (not layer.mask_keys.is_empty() and not layer.mask_keys.has(record.key)) or (not layer.mask_categories.is_empty() and not layer.mask_categories.has(record.category)):
					continue
				var point: Vector3 = record.pose.origin
				var coverage := source.mask.sample_coverage(layer.source_position(Vector2(point.x, point.z)), 0) * layer.instance_opacity
				if _fraction(record.id, source.seed) < coverage:
					records.remove_at(index)
		if layer.instance_mode == Terrain3DLayer.InstanceMode.MASK_LOWER:
			continue
		# Ignore temporary viewport/editor ancestors so previews, reloads and exports agree.
		var layer_key := str(host.get_path_to(layer))
		for id: String in source.records:
			if _fraction(id, source.seed) >= layer.instance_opacity:
				continue
			var source_record: Dictionary = source.records[id]
			var slot: Dictionary = remaps.get(layer.get_instance_id(), {}).get(source_record.slot, {})
			if slot.is_empty():
				continue
			var policy := layer.instance_placement.clone_policy() if layer.instance_placement else Terrain3DAttachmentSettings.new()
			if source_record.get("align_normal", false):
				policy.mode = Terrain3DAttachmentSettings.Mode.ALIGN_NORMAL
			policy.height_offset += source_record.get("offset", 0.0)
			var pose := layer.instance_world_pose(source_record.transform, policy.inherit_parent_scale)
			var record: Dictionary = slot.duplicate()
			record.merge({"id": layer_key + ":" + id, "pose": pose, "policy": policy, "offset": 0.0, "color": source_record.get("color", Color.WHITE)})
			records.append(record)
	var output := {}
	var wanted := {}
	for record in records:
		var scene_node: Node3D
		if record.mesh < 0:
			scene_node = _ensure_scene(host, record.id, record.resource)
			if not scene_node:
				continue
			record.pose = Transform3D(record.pose) * Transform3D(_scenes[record.id].rest)
			if not record.policy.anchor_marker.is_empty():
				var marker := scene_node.get_node_or_null(record.policy.anchor_marker) as Node3D
				if marker:
					record.policy.anchor = scene_node.to_local(marker.global_position)
		var projection := Terrain3DPlacementSolver.solve(host, record.pose, record.policy, record.offset)
		if not projection.get("valid", false):
			continue
		var pose: Transform3D = projection.transform
		if record.mesh < 0:
			wanted[record.id] = true
			scene_node.global_transform = pose
			continue
		# The base snapshot already includes each mesh asset's offset.
		if record.has("resource"):
			var mesh: Terrain3DMeshAsset = record.resource
			pose.origin += pose.basis.y * mesh.height_offset
		var location := host.data.get_region_location(pose.origin)
		if not host.data.has_region(location):
			continue
		var local := pose
		local.origin -= Vector3(location.x, 0, location.y) * host.region_size * host.vertex_spacing
		var cell := Vector2i(floori(local.origin.x / host.vertex_spacing / 32), floori(local.origin.z / host.vertex_spacing / 32))
		if not output.has(location):
			output[location] = {}
		if not output[location].has(record.mesh):
			output[location][record.mesh] = {}
		if not output[location][record.mesh].has(cell):
			var transforms: Array[Transform3D] = []
			output[location][record.mesh][cell] = [transforms, PackedColorArray(), true]
		output[location][record.mesh][cell][0].append(local)
		output[location][record.mesh][cell][1].append(record.color)
	for id: String in _scenes.keys():
		if not wanted.has(id):
			_scenes[id].node.free()
			_scenes.erase(id)
	var signature := hash(output)
	var palette_signature := hash(host.get_assets().mesh_list)
	var changed := signature != _output_hash or palette_signature != _palette_hash
	for region: Terrain3DRegion in host.data.get_regions_active():
		var instances: Dictionary = output.get(region.location, {})
		if hash(region.instances) != hash(instances):
			region.instances = instances
			changed = true
	if changed:
		host.get_instancer().update_mmis(-1, Vector2i(2147483647, 2147483647), true)
	_output_hash = signature
	_palette_hash = palette_signature

func _ensure_scene(host: Terrain3D, id: String, resource: PackedScene) -> Node3D:
	if not is_instance_valid(_scene_root):
		_scene_root = Node3D.new()
		_scene_root.name = "_Terrain3DScenes"
		host.add_child(_scene_root, false, Node.INTERNAL_MODE_BACK)
	if _scenes.has(id) and _scenes[id].resource != resource:
		_scenes[id].node.free()
		_scenes.erase(id)
	if not _scenes.has(id):
		var raw := resource.instantiate()
		if not raw is Node3D:
			push_error("Terrain3D instance scenes need a Node3D root: " + resource.resource_path)
			raw.free()
			return null
		var node := raw as Node3D
		node.name = "Instance_" + id.sha256_text().left(16)
		_scene_root.add_child(node)
		_scenes[id] = {"node": node, "resource": resource, "rest": node.transform}
	return _scenes[id].node

func promote_scenes(scene: Node, directory: String, context: String) -> Dictionary:
	var nodes: Array[Node] = []
	var files := PackedStringArray()
	if not is_instance_valid(_scene_root):
		return {"nodes": nodes, "files": files}
	var host := _scene_root.get_parent()
	host.remove_child(_scene_root)
	host.add_child(_scene_root)
	nodes.append(_scene_root)
	var cooked := {}
	for record: Dictionary in _scenes.values():
		var node: Node = record.node
		if node.scene_file_path.is_empty():
			var resource: PackedScene = record.resource
			if not cooked.has(resource):
				var identity := resource.resource_path if not resource.resource_path.is_empty() else str(node.name)
				var path := directory.path_join("scene_" + (context + identity).sha256_text() + ".scn")
				if ResourceSaver.save(resource, path, ResourceSaver.FLAG_COMPRESS) != OK:
					push_error("Terrain3D: Could not save instance scene: " + path)
					return {"nodes": nodes, "files": files, "error": ERR_CANT_CREATE}
				cooked[resource] = path
				files.append(path)
			node.scene_file_path = cooked[resource]
		nodes.append(node)
	for node in nodes:
		node.owner = scene
	return {"nodes": nodes, "files": files}
