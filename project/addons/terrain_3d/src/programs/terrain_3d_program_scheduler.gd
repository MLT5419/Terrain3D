# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DProgramScheduler
extends RefCounted
## Synchronous, chunked transactions. Language-neutral runners never receive writable source data.

const CHUNK := 32
const FOUNDATION := "res://addons/terrain_3d/src/programs/builtin/foundation.gd"
var stack: Terrain3DLayerStack
var errors := PackedStringArray()
var entries: Array[Dictionary] = []
var active := false
var generation_count := 0
var _sessions := {}
var _pending := {}
var _accepted := {}
var _available := {}
var _authoring: Array[Terrain3DLayer] = []
var _scene_root: Node3D
var _nodes := {}
var _placements := {}
var _forced := false
var _revision := 0
var _merged := {}
var _merged_accepted := {}
var _merge_signatures := {}
var _watched := {}
var _resource_versions := {}

func initialize(owner_stack: Terrain3DLayerStack) -> void:
	stack = owner_stack

func request_regenerate() -> void:
	_forced = true
	stack.invalidate()

func _nearest_layer(node: Node) -> Terrain3DLayer:
	var parent := node.get_parent()
	while parent and parent != stack.host:
		if parent is Terrain3DLayer:
			return parent
		parent = parent.get_parent()
	return null

func collect(authoring: Array[Terrain3DLayer]) -> void:
	entries.clear()
	errors.clear()
	_authoring = authoring.duplicate()
	_add_slots(stack.host.programs, null, &"", "terrain")
	var source_assets := stack.host.get_source_assets()
	for index in source_assets.texture_list.size():
		var asset := source_assets.texture_list[index]
		if not asset:
			continue
		var role: StringName = asset.role_key if not asset.role_key.is_empty() else StringName("base.material_%s" % index)
		_add_slots(asset.programs, null, role, "base/%s" % index)
	for layer in authoring:
		if not layer.participates():
			continue
		var path := str(stack.host.get_path_to(layer))
		_add_slots(layer.programs, layer, &"", path)
		for index in layer.slots.size():
			var material := layer.slots[index]
			if not material:
				continue
			var slots: Array = material.programs
			if slots.is_empty() and material.inherit_asset_programs:
				var asset := layer.resolve_slot(index, stack.host.has_meta("_terrain3d_preview_owner") and not stack.exporting)
				if asset:
					slots = asset.programs
			_add_slots(slots, layer, material.key, path + "/material/" + str(material.key))
	var root: Node = stack.host
	var preview_id: int = stack.host.get_meta("_terrain3d_preview_owner", 0)
	if preview_id and is_instance_id_valid(preview_id):
		root = instance_from_id(preview_id)
	var nodes: Array[Node] = [root]
	nodes.append_array(root.find_children("*", "", true, false))
	for node in nodes:
		if node is Terrain3DAttachmentGroup and node.terrain_interaction and node.enabled and not node._blocked() and Terrain3DPlacementSolver.layer_enabled(node) and (node.terrain == stack.host or Terrain3DPlacementSolver.resolve_host(node) == stack.host):
			_add_interactions(node)
	active = not entries.is_empty()

func _add_slots(slots: Array, owner: Terrain3DLayer, role: StringName, scope_key: String) -> void:
	var keys := {}
	for value in slots:
		if not value is Terrain3DProgramSlot:
			errors.append("Programs must contain Terrain3DProgramSlot resources.")
			continue
		var slot := value as Terrain3DProgramSlot
		if not slot.enabled:
			continue
		if slot.key.is_empty() or keys.has(slot.key):
			errors.append("Program keys must be nonempty and unique in " + scope_key)
			continue
		keys[slot.key] = true
		slot.register_host(stack.host)
		var refs: Array[Dictionary] = []
		var reference_root: Node = owner if owner else stack.host
		for path in slot.references:
			var node := reference_root.get_node_or_null(path) as Node3D
			if not node:
				errors.append("Missing program reference: " + str(path))
			else:
				refs.append({"pose": authoring_pose(node), "id": str(stack.host.get_path_to(node)), "node": node})
		entries.append({"id": scope_key + "/" + str(slot.key) + "/" + slot.uid, "slot": slot, "owner": owner, "role": role, "references": refs, "reads": [], "writes": []})

static func authoring_pose(node: Node3D) -> Transform3D:
	var current: Node = node
	while current:
		if current is Terrain3DAttachmentGroup:
			var group := current as Terrain3DAttachmentGroup
			for id: String in group._targets():
				var target: Node3D = group._targets()[id]
				if (target == node or target.is_ancestor_of(node)) and group.source and group.source.records.has(id):
					var local: Transform3D = group._edited_record(id, target).rest if group._is_editing(target) else group.source.records[id].rest
					var rest := group._authored(target, local, group._policy(target))
					return rest * target.global_transform.affine_inverse() * node.global_transform
		current = current.get_parent()
	return node.global_transform

func _add_interactions(group: Terrain3DAttachmentGroup) -> void:
	var interaction := group.terrain_interaction
	if interaction.mode == Terrain3DTerrainInteraction.Mode.DISABLED:
		return
	var owner := _nearest_layer(group)
	for id: String in group._targets():
		var target: Node3D = group._targets()[id]
		var pose := authoring_pose(target)
		var anchor := interaction.anchor
		if not interaction.anchor_marker.is_empty():
			var marker := target.get_node_or_null(interaction.anchor_marker) as Node3D
			if marker:
				anchor = target.to_local(marker.global_position)
		var world_bounds := Rect2(Vector2(pose.origin.x, pose.origin.z), Vector2.ZERO)
		for point in interaction.footprint:
			var p := pose * Vector3(point.x, anchor.y, point.y)
			world_bounds = world_bounds.expand(Vector2(p.x, p.z))
		world_bounds = world_bounds.grow(interaction.margin + interaction.falloff + interaction.clearance + stack.host.vertex_spacing)
		var bounds := Rect2(owner.source_position(world_bounds.position) if owner else world_bounds.position, Vector2.ZERO)
		for corner in [world_bounds.end, Vector2(world_bounds.position.x, world_bounds.end.y), Vector2(world_bounds.end.x, world_bounds.position.y)]:
			bounds = bounds.expand(owner.source_position(corner) if owner else corner)
		var slot := Terrain3DProgramSlot.new()
		slot.uid = "interaction:" + id
		slot.key = &"foundation"
		slot.program = FOUNDATION
		slot.placement = Terrain3DProgramSlot.Placement.AFTER_AUTHORING
		slot.height_mode = Terrain3DLayer.HeightMode.REPLACE
		slot.bounds = bounds
		var scope_key := "interaction/" + str(stack.host.get_path_to(group)) + "/" + id
		entries.append({"id": scope_key, "slot": slot, "owner": owner, "role": &"", "references": [{"pose": pose, "interaction": interaction, "anchor": anchor, "id": scope_key, "node": target}], "reads": [], "writes": []})
		if interaction.decal_albedo or interaction.decal_emission:
			var decal := Terrain3DProgramSlot.new()
			decal.uid = slot.uid + ":decal"
			decal.stage = Terrain3DProgramSlot.Stage.CONTENT
			decal.bounds = bounds
			decal.program = "res://addons/terrain_3d/src/programs/builtin/foundation_decal.gd"
			entries.append({"id": scope_key + "/decal", "slot": decal, "owner": owner, "role": &"", "references": [{"pose": pose, "interaction": interaction, "anchor": anchor, "id": scope_key, "node": target}], "reads": [], "writes": []})

func _owner_fingerprint(owner: Terrain3DLayer) -> int:
	if not owner:
		return hash([stack.host.vertex_spacing])
	var values: Array = [owner.global_transform, owner.height_opacity, owner.paint_enabled, owner.instance_opacity, owner.instance_placement.fingerprint() if owner.instance_placement else 0, owner.bindings.fingerprint() if owner.bindings else 0, owner.data.spacing if owner.data else stack.host.vertex_spacing]
	for slot in owner.slots:
		values.append([slot.key, slot.default_resource, slot.preview_resource] if slot else null)
	for slot in owner.instance_slots:
		values.append(slot.fingerprint() if slot else 0)
	if owner is Terrain3DStamp:
		values.append([owner.pivot, owner.height_scale, owner.reference_height])
	return hash(values)

func poll_fingerprint() -> int:
	var value := 0
	for entry in entries:
		var poses: Array = []
		for ref in entry.references:
			poses.append([ref.pose, ref.get("anchor"), ref.interaction.fingerprint() if ref.has("interaction") else 0])
		value = hash([value, entry.id, entry.role, entry.slot.fingerprint(), poses, _owner_fingerprint(entry.owner)])
	return value

func _resource_changed(id: int) -> void:
	_resource_versions[id] = int(_resource_versions.get(id, 0)) + 1
	if is_instance_valid(stack) and stack.is_inside_tree():
		stack.invalidate()

func _input_fingerprint(value: Variant, depth: int = 0, watch: bool = true) -> int:
	if depth > 32:
		return 0
	if value is Resource:
		var id: int = value.get_instance_id()
		if watch and not _watched.has(id):
			_watched[id] = value
			value.changed.connect(_resource_changed.bind(id))
		return hash([id, _resource_versions.get(id, 0)])
	if value is Array or value is Dictionary:
		var result := 0
		for key: Variant in value:
			result = hash([result, _input_fingerprint(value[key] if value is Dictionary else key, depth + 1, watch)])
		return result
	return hash(value)

func _callback(runner: Object, snake: StringName, pascal: StringName) -> StringName:
	return snake if runner.has_method(snake) else (pascal if runner.has_method(pascal) else &"")

func _open(entry: Dictionary) -> bool:
	var slot: Terrain3DProgramSlot = entry.slot
	if not slot.program.get_extension() in ["gd", "cs"] or not FileAccess.file_exists(slot.program):
		errors.append("Missing .gd/.cs program: " + slot.program)
		return false
	if slot.program.get_extension() == "cs" and not ClassDB.class_exists(&"CSharpScript"):
		errors.append("C# programs require Godot .NET and a compiled project assembly: " + slot.program)
		return false
	var script := load(slot.program) as Script
	if not script or not script.can_instantiate() or not ClassDB.is_parent_class(script.get_instance_base_type(), &"RefCounted"):
		errors.append("Program must be an instantiable RefCounted/Resource script. Build C# scripts before generating: " + slot.program)
		return false
	if Engine.is_editor_hint() and not script.is_tool():
		errors.append("Editor programs require @tool / [Tool]: " + slot.program)
		return false
	var code := slot.program + ":" + str(hash([script.get_source_code().hash(), _input_fingerprint(script)]))
	if _sessions.has(entry.id) and _sessions[entry.id].code != code:
		_close(entry.id)
	if not _sessions.has(entry.id):
		var runner: RefCounted = script.new()
		if not runner:
			errors.append("Could not construct the program without arguments: " + slot.program)
			return false
		var generate := _callback(runner, &"generate", &"Generate")
		if generate.is_empty():
			errors.append("Program must implement bool generate(context, output) / Generate(context, output).")
			return false
		var spec := {}
		var describe := _callback(runner, &"describe", &"Describe")
		if not describe.is_empty():
			var described: Variant = runner.call(describe)
			if not described is Dictionary:
				errors.append("describe()/Describe() must return a Dictionary.")
				return false
			spec = described
		_sessions[entry.id] = {"runner": runner, "code": code, "generate": generate, "spec": spec, "attached": false, "context": null, "signature": 0, "built": false}
	entry.reads = Array(_sessions[entry.id].spec.get("reads", []))
	entry.writes = Array(_sessions[entry.id].spec.get("writes", []))
	if slot.stage == Terrain3DProgramSlot.Stage.HEIGHT and (entry.reads.has("final_height") or entry.reads.has("final_material")):
		errors.append("A height program cannot read final_height/final_material; that would feed its output back into its input.")
	if slot.stage == Terrain3DProgramSlot.Stage.SURFACE and entry.reads.has("final_material"):
		errors.append("A surface program cannot depend on final_material.")
	return errors.is_empty()

func _ordered_entries(stage: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var waiting: Array[Dictionary] = []
	for entry in entries:
		if entry.slot.stage == stage:
			waiting.append(entry)
	while not waiting.is_empty():
		var progress := false
		for entry in waiting.duplicate():
			var blocked := false
			for read: String in entry.reads:
				if not read.begins_with("mask:") and not read.begins_with("mask?:"):
					continue
				var token := read.replace("mask?:", "mask:")
				var found := false
				for producer in entries:
					if producer.writes.has(token):
						found = true
						if producer.id == entry.id or producer.slot.stage > stage:
							errors.append("Cyclic or later-stage mask dependency: " + token)
							return []
						if waiting.has(producer):
							blocked = true
				if not found and read.begins_with("mask:"):
					errors.append("Missing mask dependency: " + read)
					return []
			if not blocked:
				result.append(entry)
				waiting.erase(entry)
				progress = true
		if not progress:
			errors.append("Cyclic program dependencies.")
			return []
	return result

func _source_order() -> Array:
	var order: Array = []
	for entry in entries:
		if not entry.owner and entry.slot.placement == Terrain3DProgramSlot.Placement.BEFORE_AUTHORING:
			order.append(entry)
	for owner in _authoring:
		for placement in 2:
			if placement == 1:
				order.append(owner)
			for entry in entries:
				if entry.owner == owner and entry.slot.placement == placement:
					order.append(entry)
	for entry in entries:
		if not entry.owner and entry.slot.placement == Terrain3DProgramSlot.Placement.AFTER_AUTHORING:
			order.append(entry)
	return order

func _sources(available: Dictionary, exclude: String = "", stop_at: String = "") -> Array[Terrain3DLayer]:
	var result: Array[Terrain3DLayer] = []
	for item: Variant in _source_order():
		if item is Terrain3DLayer:
			result.append(item)
		elif item.id == stop_at:
			break
		elif item.id != exclude and available.has(item.id):
			var combined := _merge_entry(item.id)
			if combined:
				result.append(combined.layer)
	return result

func _merge_entry(id: String) -> Terrain3DProgramOutput:
	var outputs: Dictionary = _pending.get(id, {})
	if outputs.is_empty():
		return null
	var signature := hash(outputs.values())
	if _merged.has(id) and _merge_signatures.get(id, 0) == signature:
		return _merged[id]["output"]
	var first: Terrain3DProgramOutput = outputs.values()[0]
	var layer := Terrain3DGeneratedLayer.new()
	layer.host = stack.host
	layer.owner_layer = first.layer.owner_layer
	layer.name = "_Program_" + id.sha256_text().left(20)
	layer.slots = first.layer.slots
	layer.instance_slots = first.layer.instance_slots
	layer.bindings = first.layer.bindings
	layer.height_mode = first.layer.height_mode
	layer.height_opacity = first.layer.height_opacity
	layer.paint_enabled = first.layer.paint_enabled
	layer.instance_opacity = first.layer.instance_opacity
	layer.instance_placement = first.layer.instance_placement
	layer.data = Terrain3DLayerData.new()
	layer.data.spacing = first.layer.data.spacing
	layer.scatter_data = Terrain3DScatterData.new()
	layer.scatter_data.seed = first.layer.scatter_data.seed
	stack.host.add_child(layer, false, Node.INTERNAL_MODE_BACK)
	var combined := Terrain3DProgramOutput.new()
	combined.layer = layer
	combined._context = first._context
	for chunk: Vector2i in outputs:
		var output: Terrain3DProgramOutput = outputs[chunk]
		_merge_data(layer.data, output.layer.data, output._context.get_bounds())
		for key: StringName in output.masks:
			if not combined.masks.has(key):
				combined.masks[key] = Terrain3DLayerData.new()
				combined.masks[key].spacing = layer.data.spacing
			_merge_data(combined.masks[key], output.masks[key], output._context.get_bounds())
		for record_id: String in output.layer.scatter_data.records:
			layer.scatter_data.records[str(chunk) + ":" + record_id] = output.layer.scatter_data.records[record_id]
	if _merged.has(id) and (not _merged_accepted.has(id) or _merged[id]["output"] != _merged_accepted[id]["output"]):
		_merged[id]["output"].layer.free()
	_merged[id] = {"output": combined}
	_merge_signatures[id] = signature
	return combined

func _merge_data(target: Terrain3DLayerData, patch: Terrain3DLayerData, bounds: Rect2) -> void:
	var first := Vector2i((bounds.position / patch.spacing).ceil())
	var last := Vector2i((bounds.end / patch.spacing).ceil())
	var clip := Rect2i(first, last - first)
	for key: Vector2i in patch.chunks:
		var region := Rect2i(key * Terrain3DLayerData.CHUNK_SIZE, Vector2i.ONE * Terrain3DLayerData.CHUNK_SIZE).intersection(clip)
		if not region.has_area():
			continue
		var local := Rect2i(region.position - key * Terrain3DLayerData.CHUNK_SIZE, region.size)
		for channel: int in patch.chunks[key]:
			target._image(key, channel, true).blit_rect(patch.chunks[key][channel], local, local.position)
	if patch.sample_bounds.has_area():
		target.sample_bounds = target.sample_bounds.merge(patch.sample_bounds) if target.sample_bounds.has_area() else patch.sample_bounds
	target._used_slots_dirty = true

func _snapshot(sources: Array[Terrain3DLayer]) -> Terrain3DProgramSnapshot:
	var result := Terrain3DProgramSnapshot.new()
	result.base = stack._base
	result.sources = sources.duplicate()
	result.assets = stack.host.get_source_assets()
	result.spacing = stack.host.vertex_spacing
	result.region_size = stack.host.region_size
	for id: String in _available:
		var combined := _merge_entry(id)
		if combined:
			for key: StringName in combined.masks:
				result.masks.append({"key": key, "data": combined.masks[key], "layer": combined.layer})
	return result

func build(authoring: Array[Terrain3DLayer], areas: Array[Rect2], full: bool) -> bool:
	collect(authoring)
	if not errors.is_empty():
		return false
	for entry in entries:
		if not _open(entry):
			return false
	_pending = _accepted.duplicate()
	_merged = _merged_accepted.duplicate()
	_available = {}
	_revision = stack.revision
	for stage in 3:
		var ordered := _ordered_entries(stage)
		if not errors.is_empty():
			return false
		for entry in ordered:
			var sources := _sources(_available, entry.id)
			if stage == Terrain3DProgramSlot.Stage.HEIGHT:
				sources = _sources(_available, entry.id, entry.id)
			if not _run(entry, _snapshot(sources), areas, full):
				return false
			_available[entry.id] = true
	return true

func _run(entry: Dictionary, snapshot: Terrain3DProgramSnapshot, areas: Array[Rect2], full: bool) -> bool:
	var slot: Terrain3DProgramSlot = entry.slot
	var session: Dictionary = _sessions[entry.id]
	if entry.owner and not entry.owner.is_transform_valid():
		errors.append("Program owner has an unsupported heightfield transform: " + entry.id)
		return false
	var signature := hash([entry.role, slot.fingerprint(), _input_fingerprint([slot.parameters, slot.resources, entry.references.map(func(ref: Dictionary): return ref.get("interaction"))]), entry.references.map(func(ref: Dictionary): return [ref.pose, ref.get("anchor"), ref.interaction.fingerprint() if ref.has("interaction") else 0]), _owner_fingerprint(entry.owner)])
	var needs: bool = not session.built or signature != session.signature or _forced
	if session.built and (not Engine.is_editor_hint() or slot.update_mode == Terrain3DProgramSlot.UpdateMode.MANUAL) and not _forced:
		_available[entry.id] = true
		return true
	var spacing := slot.sample_spacing
	if spacing <= 0:
		spacing = entry.owner.data.spacing if entry.owner and entry.owner.data else stack.host.vertex_spacing
	if not slot.bounds.has_area() or not slot.bounds.position.is_finite() or not slot.bounds.size.is_finite() or spacing < 0.001 or not is_finite(spacing):
		errors.append("Program bounds and spacing must be finite and positive: " + entry.id)
		return false
	var first := Vector2i((slot.bounds.position / spacing / CHUNK).floor())
	var last := Vector2i((slot.bounds.end / spacing / CHUNK).ceil())
	if (last.x - first.x) * (last.y - first.y) > 4096:
		errors.append("Program exceeds 4096 source chunks; reduce its bounds or increase spacing.")
		return false
	var chunks: Dictionary = {} if needs else _accepted.get(entry.id, {}).duplicate()
	_pending[entry.id] = chunks
	for y in range(first.y, last.y):
		for x in range(first.x, last.x):
			var chunk := Vector2i(x, y)
			var bounds := Rect2(Vector2(chunk * CHUNK) * spacing, Vector2.ONE * CHUNK * spacing).intersection(slot.bounds)
			var depends: bool = not entry.reads.is_empty() or not entry.role.is_empty()
			var dirty: bool = needs or (full and depends) or not chunks.has(chunk)
			var world := Rect2(entry.owner._source_to_world(bounds.position) if entry.owner else bounds.position, Vector2.ZERO)
			for corner in [bounds.end, Vector2(bounds.position.x, bounds.end.y), Vector2(bounds.end.x, bounds.position.y)]:
				world = world.expand(entry.owner._source_to_world(corner) if entry.owner else corner)
			for area in areas:
				dirty = dirty or (depends and world.grow(spacing * 2).intersects(area, true))
			if not dirty:
				continue
			var context := Terrain3DProgramContext.new()
			context._snapshot = snapshot
			context._entry = entry
			context._references.assign(entry.references.duplicate(true))
			for reference in context._references:
				for earlier_id: String in _available:
					if earlier_id == entry.id:
						continue
					for earlier: Terrain3DProgramOutput in _pending.get(earlier_id, {}).values():
						if earlier.placements.has(reference.id):
							reference.pose = earlier.placements[reference.id]
			context._bounds = bounds
			context._spacing = spacing
			context._chunk = chunk
			context._revision = _revision
			var layer := Terrain3DGeneratedLayer.new()
			layer.host = stack.host
			layer.owner_layer = entry.owner
			layer.name = "_Program_" + (entry.id + str(chunk)).sha256_text().left(20)
			layer.data = Terrain3DLayerData.new()
			layer.data.spacing = spacing
			layer.scatter_data = Terrain3DScatterData.new()
			layer.scatter_data.seed = slot.seed
			layer.height_mode = slot.height_mode
			layer.slots.assign(slot.material_slots if not slot.material_slots.is_empty() else (entry.owner.slots if entry.owner else []))
			layer.instance_slots.assign(slot.instance_slots if not slot.instance_slots.is_empty() else (entry.owner.instance_slots if entry.owner else []))
			if entry.owner:
				layer.bindings = entry.owner.bindings
				layer.height_opacity = entry.owner.height_opacity
				layer.paint_enabled = entry.owner.paint_enabled
				layer.instance_opacity = entry.owner.instance_opacity
				layer.instance_placement = entry.owner.instance_placement
			stack.host.add_child(layer, false, Node.INTERNAL_MODE_BACK)
			var output := Terrain3DProgramOutput.new()
			output.layer = layer
			output._context = context
			if not session.attached:
				var attach := _callback(session.runner, &"on_attach", &"OnAttach")
				if not attach.is_empty():
					session.runner.call(attach, context)
				session.attached = true
			var success: Variant = session.runner.call(session.generate, context, output)
			layer.data.end_edit()
			if success != true or not context._errors.is_empty() or not output._errors.is_empty() or stack.revision != _revision:
				layer.free()
				errors.append("%s: generation failed or its inputs changed. %s %s" % [entry.id, "; ".join(context._errors), "; ".join(output._errors)])
				return false
			chunks[chunk] = output
			stack._dirty_areas.append(world.grow(spacing))
			session.context = context
			generation_count += 1
	_pending[entry.id] = chunks
	session.pending_signature = signature
	return true

func candidate_sources() -> Array[Terrain3DLayer]:
	return _sources(_available)

func accept() -> void:
	var live := {}
	for entry in entries:
		live[entry.id] = true
	for id: String in _pending.keys():
		if not live.has(id):
			_pending.erase(id)
	for id: String in _merged.keys():
		if not live.has(id):
			_merged.erase(id)
	_dispose_outputs(_merged_accepted, _merged)
	_merged_accepted = _merged
	_dispose_outputs(_accepted, _pending)
	_accepted = _pending
	_placements.clear()
	for outputs: Dictionary in _accepted.values():
		for output: Terrain3DProgramOutput in outputs.values():
			_placements.merge(output.placements, true)
	for id: String in _sessions.keys():
		if not live.has(id):
			_close(id)
		else:
			var session: Dictionary = _sessions[id]
			if session.has("pending_signature"):
				session.signature = session.pending_signature
				session.erase("pending_signature")
				session.built = true
				session.notify = true
	_forced = false
	_update_nodes()

func notify_applied() -> void:
	for session: Dictionary in _sessions.values():
		if session.get("notify", false):
			session.notify = false
			var applied := _callback(session.runner, &"on_applied", &"OnApplied")
			if not applied.is_empty():
				session.runner.call(applied, session.context)

func reject() -> void:
	for session: Dictionary in _sessions.values():
		session.erase("pending_signature")
	_dispose_outputs(_pending, _accepted)
	_pending = _accepted
	_dispose_outputs(_merged, _merged_accepted)
	_merged = _merged_accepted

func _dispose_outputs(old: Dictionary, keep: Dictionary, deferred: bool = false) -> void:
	var retained := {}
	for outputs: Dictionary in keep.values():
		for output: Terrain3DProgramOutput in outputs.values():
			retained[output] = true
	for outputs: Dictionary in old.values():
		for output: Terrain3DProgramOutput in outputs.values():
			if not retained.has(output) and is_instance_valid(output.layer):
				if deferred:
					output.layer.queue_free()
				else:
					output.layer.free()

func _close(id: String) -> void:
	var session: Dictionary = _sessions[id]
	var detach := _callback(session.runner, &"on_detach", &"OnDetach")
	if not detach.is_empty():
		session.runner.call(detach, session.context)
	_sessions.erase(id)

func shutdown() -> void:
	for id: int in _watched:
		var resource: Resource = _watched[id]
		var callback := _resource_changed.bind(id)
		if resource.changed.is_connected(callback):
			resource.changed.disconnect(callback)
	_watched.clear()
	for id: String in _sessions.keys():
		_close(id)
	_dispose_outputs(_accepted, {}, true)
	_dispose_outputs(_merged_accepted, {}, true)
	_accepted.clear()
	_merged_accepted.clear()
	if is_instance_valid(_scene_root):
		_scene_root.queue_free()

func planned_pose(id: String, fallback: Transform3D) -> Transform3D:
	return _placements.get(id, fallback)

func suppresses(world: Vector3, category: StringName) -> bool:
	for id: String in _merged_accepted:
		var output: Terrain3DProgramOutput = _merged_accepted[id]["output"]
		if output.masks.has(&"terrain.clearance"):
			var refs := output._context._references
			var categories: Array = refs[0].interaction.excluded_categories if not refs.is_empty() and refs[0].has("interaction") else [&"vegetation"]
			if categories.has(category) and output.masks[&"terrain.clearance"].sample_coverage(output.layer.source_position(Vector2(world.x, world.z)), 0) >= 0.5:
				return true
	return false

func _update_nodes() -> void:
	var wanted := {}
	for entry_id: String in _accepted:
		for chunk: Vector2i in _accepted[entry_id]:
			var output: Terrain3DProgramOutput = _accepted[entry_id][chunk]
			for id: String in output.nodes:
				var key := entry_id + "/" + str(chunk) + "/" + id
				var record: Dictionary = output.nodes[id]
				var options: Dictionary = record.options
				var pose := output.layer.instance_world_pose(record.pose, options.get("inherit_scale", false))
				if options.get("snap", record.kind == &"decal"):
					var policy := Terrain3DAttachmentSettings.new()
					policy.mode = Terrain3DAttachmentSettings.Mode.SNAP
					policy.height_offset = options.get("height_offset", 0.02)
					var projection := Terrain3DPlacementSolver.solve(stack.host, pose, policy)
					if not projection.get("valid", false):
						continue
					pose = projection.transform
				wanted[key] = true
				if not is_instance_valid(_scene_root):
					_scene_root = Node3D.new()
					_scene_root.name = "_Terrain3DPrograms"
					stack.host.add_child(_scene_root, false, Node.INTERNAL_MODE_BACK)
				var signature := hash([record, _input_fingerprint(record, 0, false)])
				if _nodes.has(key) and _nodes[key].signature != signature:
					_nodes[key].node.free()
					_nodes.erase(key)
				if not _nodes.has(key):
					var node: Node3D
					if record.kind == &"decal":
						var decal := Decal.new()
						decal.texture_albedo = record.textures.get("albedo")
						decal.texture_normal = record.textures.get("normal")
						decal.texture_orm = record.textures.get("orm")
						decal.texture_emission = record.textures.get("emission")
						decal.size = record.size
						decal.modulate = options.get("modulate", Color.WHITE)
						decal.cull_mask = options.get("cull_mask", stack.host.render_layers)
						decal.distance_fade_enabled = options.get("distance_fade", true)
						decal.distance_fade_begin = options.get("fade_begin", 80.0)
						node = decal
					else:
						var mesh := MeshInstance3D.new()
						mesh.mesh = record.mesh
						mesh.material_override = record.material
						if options.get("collision", false):
							mesh.create_trimesh_collision()
						node = mesh
					node.name = "Output_" + key.sha256_text().left(20)
					_scene_root.add_child(node)
					_nodes[key] = {"node": node, "signature": signature}
				_nodes[key].node.global_transform = pose
	for key: String in _nodes.keys():
		if not wanted.has(key):
			_nodes[key].node.free()
			_nodes.erase(key)

func promote_nodes(scene: Node) -> Array[Node]:
	var result: Array[Node] = []
	if not is_instance_valid(_scene_root):
		return result
	var host := _scene_root.get_parent()
	host.remove_child(_scene_root)
	host.add_child(_scene_root)
	result.append(_scene_root)
	result.append_array(_scene_root.find_children("*", "", true, false))
	for node in result:
		node.owner = scene
	# These nodes now belong to the exported scene, including after it leaves the tree.
	_scene_root = null
	_nodes.clear()
	return result
