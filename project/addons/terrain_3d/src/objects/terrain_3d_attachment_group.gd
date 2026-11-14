# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DAttachmentGroup
extends Node3D
## CHILDREN solves each direct scene root; RIGID solves this whole assembly and stops descent.

enum Processing { CHILDREN, RIGID }
const ID_META := &"_terrain3d_attachment_id"
@export var processing: Processing = Processing.CHILDREN
@export var settings: Terrain3DAttachmentSettings = Terrain3DAttachmentSettings.new()
@export var source: Terrain3DAttachmentData = Terrain3DAttachmentData.new()
@export var terrain: Terrain3D
@export var enabled := true
@export var runtime_follow := false
@export var terrain_interaction: Terrain3DTerrainInteraction
@export_tool_button("Capture Current Offsets") var capture_action: Callable = capture_offsets
@export_tool_button("Update Attachments") var update_action: Callable = update_attachments
# This is per scene instance; shared source resources never receive derived transforms.
@export_storage var solved_transforms: Dictionary = {}
var _host: Terrain3D
var _last_applied: Dictionary = {}
var _poll := 0.0
var _solving := false
var _solved_once := false
var _state_hash := 0
var _interaction_hash := 0

func _ready() -> void:
	if not source:
		source = Terrain3DAttachmentData.new()
	if source._owner_id and source._owner_id != get_instance_id():
		source = source.clone_source()
	source._owner_id = get_instance_id()
	solved_transforms = solved_transforms.duplicate()
	_last_applied = solved_transforms.duplicate()
	call_deferred("update_attachments")

func _exit_tree() -> void:
	_disconnect_host()

func _process(delta: float) -> void:
	_poll += delta
	if _poll < 0.15:
		return
	_poll = 0.0
	if terrain_interaction:
		var host := terrain if terrain else Terrain3DPlacementSolver.resolve_host(self)
		if host:
			var state := hash([terrain_interaction.fingerprint(), enabled, global_transform if processing == Processing.CHILDREN else source.records])
			if state != _interaction_hash:
				_interaction_hash = state
				var stack := host.ensure_layer_stack()
				if stack:
					stack.invalidate()
	if not Engine.is_editor_hint() and _solved_once and not runtime_follow:
		return
	update_attachments()

func _notification(what: int) -> void:
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		update_attachments(true)
		if source and not source.is_built_in() and not source.resource_path.is_empty():
			ResourceSaver.save(source, "", ResourceSaver.FLAG_COMPRESS)

func _disconnect_host() -> void:
	if is_instance_valid(_host) and _host.data:
		for signal_name in [&"height_maps_changed", &"maps_changed", &"maps_edited"]:
			if _host.data.is_connected(signal_name, _surface_changed):
				_host.data.disconnect(signal_name, _surface_changed)

func _surface_changed(_area: Variant = null) -> void:
	if Engine.is_editor_hint() or runtime_follow or not _solved_once:
		call_deferred("update_attachments", true)

func _blocked() -> bool:
	var parent := get_parent()
	while parent:
		if parent is Terrain3DAttachmentGroup and parent.processing == Processing.RIGID:
			return true
		if parent is Terrain3D:
			break
		parent = parent.get_parent()
	return false

func _targets() -> Dictionary:
	if processing == Processing.RIGID:
		return {"self": self}
	var result := {}
	for child in get_children():
		if not child is Node3D or child is Terrain3DAttachmentGroup:
			continue
		if _contains_surface_source(child):
			continue
		var id: String = child.get_meta(ID_META, "")
		if id.is_empty() or result.has(id):
			var original := id
			id = Crypto.new().generate_random_bytes(12).hex_encode()
			child.set_meta(ID_META, id)
			# Duplicating a solved child also duplicates its metadata and compensated scale.
			# Copy its source pose, rather than treating that scale as a new authored scale.
			if source and source.records.has(original) and result.has(original):
				var record: Dictionary = source.records[original].duplicate(true)
				var previous: Transform3D = result[original].transform
				var rest: Transform3D = record.rest
				var delta: Vector3 = child.transform.origin - previous.origin
				rest.origin += delta
				rest.basis = child.transform.basis * previous.basis.inverse() * rest.basis
				record.rest = rest
				record.offset += (global_basis * delta).y
				source.records[id] = record
				_last_applied[id] = child.transform
				solved_transforms[id] = child.transform
		result[id] = child
	return result

func _contains_surface_source(node: Node) -> bool:
	if node is Terrain3D or node is Terrain3DLayer:
		return true
	for child in node.get_children():
		if _contains_surface_source(child):
			return true
	return false

func _policy(target: Node3D) -> Terrain3DAttachmentSettings:
	var policy := settings.clone_policy()
	if not policy.anchor_marker.is_empty():
		var marker := target.get_node_or_null(policy.anchor_marker) as Node3D
		if marker:
			policy.anchor = target.to_local(marker.global_position)
	return policy

func _authored(target: Node3D, local: Transform3D, policy: Terrain3DAttachmentSettings) -> Transform3D:
	if target.top_level:
		return local
	return Terrain3DPlacementSolver.authored_global(target.get_parent_node_3d(), local, policy.inherit_parent_scale)

func _capture(target: Node3D, policy: Terrain3DAttachmentSettings, keep: bool = true) -> Dictionary:
	var pose := _authored(target, target.transform, policy)
	var projection := Terrain3DPlacementSolver.solve(_host, pose, policy)
	var offset := 0.0
	if keep and projection.get("valid", false):
		offset = pose.origin.y - Transform3D(projection.transform).origin.y
	return {"rest": target.transform, "offset": offset, "captured": projection.get("valid", false), "visible": target.visible}

func _is_editing(target: Node3D) -> bool:
	if not Engine.is_editor_hint() or not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return false
	var selected := EditorInterface.get_selection().get_selected_nodes()
	var node: Node = target
	while node and node != _host:
		if selected.has(node):
			return true
		node = node.get_parent()
	return false

func _apply_record(id: String, record: Dictionary, local: Transform3D) -> void:
	source.records[id] = record.duplicate(true)
	var target: Node3D = _targets().get(id)
	if target:
		target.transform = local
		_last_applied[id] = local
		solved_transforms[id] = local
	source.emit_changed()

func _record_manual_edit(id: String, target: Node3D, policy: Terrain3DAttachmentSettings) -> void:
	var old: Dictionary = source.records[id].duplicate(true)
	var previous: Transform3D = _last_applied.get(id, target.transform)
	var record: Dictionary = old.duplicate(true)
	var rest: Transform3D = old.rest
	rest.origin = target.transform.origin
	# Apply the user's change to the source basis, excluding the solver's scale/tilt.
	rest.basis = target.transform.basis * previous.basis.inverse() * rest.basis
	record.rest = rest
	var parent := target.get_parent_node_3d()
	var delta := target.transform.origin - previous.origin
	record.offset += (parent.global_basis * delta).y if parent and not target.top_level else delta.y
	source.records[id] = record
	if Engine.is_editor_hint() and _host:
		var plugin := _host.get_plugin()
		if plugin and plugin.has_method("get_undo_redo"):
			var history: EditorUndoRedoManager = plugin.get_undo_redo()
			var undo := history.get_history_undo_redo(history.get_object_history_id(self))
			var title := undo.get_current_action_name() if undo else ""
			if title not in ["Translate", "Rotate", "Scale", "Transform"]:
				title = "Transform Surface Attachment"
			history.create_action(title, UndoRedo.MERGE_ALL, self)
			history.add_undo_method(self, &"_apply_record", id, old, previous)
			history.add_do_method(self, &"_apply_record", id, record.duplicate(true), target.transform)
			history.commit_action(false)
	source.emit_changed()

func update_attachments(force: bool = false) -> void:
	if _solving or not is_inside_tree() or _blocked() or not settings or not source:
		return
	if processing == Processing.RIGID and _contains_surface_source(self):
		return
	if not Engine.is_editor_hint() and _solved_once and not runtime_follow and not force:
		return
	var resolved := terrain if terrain else Terrain3DPlacementSolver.resolve_host(self)
	if resolved != _host:
		_disconnect_host()
		_host = resolved
	if not is_instance_valid(_host) or not _host.data:
		return
	for signal_name in [&"height_maps_changed", &"maps_changed", &"maps_edited"]:
		if not _host.data.is_connected(signal_name, _surface_changed):
			_host.data.connect(signal_name, _surface_changed)
	var targets := _targets()
	var state := hash([global_transform, processing, enabled, Terrain3DPlacementSolver.layer_enabled(self), settings.fingerprint(), targets.keys(), source.records])
	var changed := force or state != _state_hash
	_state_hash = state
	_solving = true
	var complete := true
	for id: String in targets:
		var target: Node3D = targets[id]
		if _is_editing(target):
			continue
		var policy := _policy(target)
		if not source.records.has(id):
			var preserve := policy.mode in [policy.Mode.KEEP_OFFSET, policy.Mode.ALIGN_NORMAL]
			source.records[id] = _capture(target, policy, preserve)
			changed = true
		elif _last_applied.has(id) and not target.transform.is_equal_approx(_last_applied[id]):
			_record_manual_edit(id, target, policy)
			changed = true
		if not changed:
			continue
		var record: Dictionary = source.records[id]
		var authored := _authored(target, record.rest, policy)
		var projection := Terrain3DPlacementSolver.solve(_host, authored, policy, record.offset)
		if not record.captured and projection.get("valid", false):
			record = _capture(target, policy, policy.mode in [policy.Mode.KEEP_OFFSET, policy.Mode.ALIGN_NORMAL])
			source.records[id] = record
			projection = Terrain3DPlacementSolver.solve(_host, _authored(target, record.rest, policy), policy, record.offset)
		var participating := Terrain3DPlacementSolver.layer_enabled(self)
		if enabled and terrain_interaction and terrain_interaction.mode != Terrain3DTerrainInteraction.Mode.DISABLED:
			# The model supplies the reference plane; do not add its old ground gap again.
			var pose := authored
			if terrain_interaction.mode == Terrain3DTerrainInteraction.Mode.PLACE_THEN_TERRAFORM and _host.get_layer_stack():
				var key := "interaction/" + str(_host.get_path_to(self)) + "/" + id
				pose = _host.get_layer_stack().program_scheduler.planned_pose(key, authored)
			target.transform = target.get_parent_node_3d().global_transform.affine_inverse() * pose if target.get_parent_node_3d() and not target.top_level else pose
		elif enabled and projection.get("valid", false):
			var solved: Transform3D = projection.transform
			target.transform = target.get_parent_node_3d().global_transform.affine_inverse() * solved if target.get_parent_node_3d() and not target.top_level else solved
		else:
			complete = complete and projection.get("valid", false)
			if not enabled:
				target.transform = record.rest
		target.visible = record.visible and participating and (projection.get("valid", false) or not policy.hide_without_surface)
		_last_applied[id] = target.transform
		solved_transforms[id] = target.transform
	_solving = false
	_solved_once = complete

func capture_offsets() -> void:
	update_attachments()
	if not _host:
		return
	var before := source.records.duplicate(true)
	var after := before.duplicate(true)
	var targets := _targets()
	for id: String in targets:
		var target: Node3D = targets[id]
		var policy := _policy(target)
		var rest: Transform3D = after[id].rest
		rest.origin = target.transform.origin
		var pose := _authored(target, rest, policy)
		var projection := Terrain3DPlacementSolver.solve(_host, pose, policy)
		after[id] = {"rest": rest, "offset": target.global_position.y - Transform3D(projection.get("transform", pose)).origin.y, "captured": projection.get("valid", false), "visible": before[id].visible}
	var plugin := _host.get_plugin()
	if Engine.is_editor_hint() and plugin and plugin.has_method("get_undo_redo"):
		var history: EditorUndoRedoManager = plugin.get_undo_redo()
		history.create_action("Capture Surface Attachment Offsets", UndoRedo.MERGE_DISABLE, self)
		history.add_undo_method(self, &"_restore_records", source, before)
		history.add_do_method(self, &"_restore_records", source, after)
		history.commit_action()
	else:
		_restore_records(source, after)
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()

func _restore_records(resource: Terrain3DAttachmentData, records: Dictionary) -> void:
	resource.records = records.duplicate(true)
	resource.emit_changed()
	update_attachments(true)

func rebase_authored_origin(delta: Vector3) -> void:
	if processing != Processing.RIGID or not source or not source.records.has("self"):
		return
	if source._owner_id and source._owner_id != get_instance_id():
		source = source.clone_source()
	source._owner_id = get_instance_id()
	var rest: Transform3D = source.records.self.rest
	rest.origin += delta
	source.records.self.rest = rest
	for poses in [_last_applied, solved_transforms]:
		if poses.has("self"):
			var pose: Transform3D = poses.self
			pose.origin += delta
			poses.self = pose
	source.emit_changed()

func editor_setup(plugin: EditorPlugin) -> void:
	var host := terrain if terrain else Terrain3DPlacementSolver.resolve_host(self)
	if host:
		host.set_plugin(plugin)

func _get_configuration_warnings() -> PackedStringArray:
	if _contains_surface_source(self):
		return PackedStringArray(["Attachment containers cannot drive Terrain3D or editing layers. Place the container alongside height contributors to avoid a surface/placement cycle."])
	if _blocked():
		return PackedStringArray(["An ancestor uses Rigid processing. This container follows that assembly without solving its children again."])
	if is_inside_tree() and not terrain and not Terrain3DPlacementSolver.resolve_host(self):
		return PackedStringArray(["Place this container under Terrain3D, a Layer or a Stamp, or assign its Terrain explicitly."])
	return PackedStringArray()

static func solve_for_host(host: Terrain3D) -> void:
	var root: Node = host
	var id: int = host.get_meta("_terrain3d_preview_owner", 0)
	if id and is_instance_id_valid(id):
		root = instance_from_id(id)
	var nodes: Array[Node] = [root]
	nodes.append_array(root.find_children("*", "", true, false))
	for node in nodes:
		if node is Terrain3DAttachmentGroup and (node.terrain == host or Terrain3DPlacementSolver.resolve_host(node) == host):
			node.update_attachments(true)
