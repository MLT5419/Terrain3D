# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DLayer
extends Node3D
## Editable non-destructive terrain contribution. Sibling order is bottom to top.

enum HeightMode { ADD, REPLACE }
enum InstanceMode { ADD, MASK_LOWER, REPLACE }
signal layer_changed
@export var programs: Array[Terrain3DProgramSlot] = []
@export_tool_button("Regenerate Programs") var regenerate_programs_action: Callable = regenerate_programs
## Source-space placement origin. Center Pivot preserves the terrain and child placement.
@export var pivot := Vector2.ZERO:
	set(value):
		pivot = value
		_changed()
@export_tool_button("Center Pivot") var center_action: Callable = center_pivot
@export_storage var _placement_editor_version := 0

## Source maps. Save externally for collaboration; Make Data Unique before editing an independent copy.
@export var data: Terrain3DLayerData:
	set(value):
		if data and data.changed.is_connected(_data_changed):
			data.changed.disconnect(_data_changed)
		data = value
		if data:
			data.changed.connect(_data_changed)
		_changed()
## Local paint palette. Keep the order stable after painting.
@export var slots: Array[Terrain3DLayerSlot] = []:
	set(value):
		slots = value
		_changed()
## Optional skin for this instance, overriding the parent terrain's bindings.
@export var bindings: Terrain3DLayerBindings:
	set(value):
		bindings = value
		_changed()
## Include this layer in the terrain result. This is independent from Node3D visibility.
@export var enabled := true:
	set(value):
		enabled = value
		_changed()
@export var locked := false
@export var height_mode: HeightMode = HeightMode.ADD:
	set(value):
		height_mode = value
		_changed()
@export_range(0.0, 1.0) var height_opacity := 1.0:
	set(value):
		height_opacity = clampf(value, 0, 1)
		_changed()
@export var paint_enabled := true:
	set(value):
		paint_enabled = value
		_changed()
## Brushes erase this layer's coverage, exposing the layers below.
@export var erase_mode := false
@export_group("Instances")
@export var scatter_data: Terrain3DScatterData:
	set(value):
		if scatter_data and scatter_data.changed.is_connected(_changed):
			scatter_data.changed.disconnect(_changed)
		scatter_data = value
		if scatter_data:
			scatter_data.changed.connect(_changed)
		_changed()
@export var instance_slots: Array[Terrain3DInstanceSlot] = []
@export var instance_mode: InstanceMode = InstanceMode.ADD
@export_range(0, 1, 0.01) var instance_opacity := 1.0
## Instances per square meter at full brush strength; opacity thins existing records separately.
@export_range(0.001, 100, 0.01, "or_greater") var paint_density := 1.0
## Empty filters affect all lower instances. Both filters must match when supplied.
@export var mask_keys: Array[StringName] = []
@export var mask_categories: Array[StringName] = []
@export var instance_placement: Terrain3DAttachmentSettings = Terrain3DAttachmentSettings.new()
@export_tool_button("Create Instance Data") var create_instances_action: Callable = create_instance_data
@export_tool_button("Make Instances Unique") var unique_instances_action: Callable = make_instances_unique
@export_group("Standalone")
@export_range(0.25, 100.0) var preview_vertex_spacing := 1.0
@export var preview_material: Terrain3DMaterial
@export_tool_button("Create Layer Data") var create_data_action: Callable = create_data
@export_tool_button("Make Data Unique") var unique_data_action: Callable = make_data_unique

var _preview_host: Terrain3D
var _last_host: Terrain3D
var _poll_time := 0.0
var _state_hash: int
var _edit_assets: Terrain3DAssets
var _baked_only := false
var _before_chunks := {}
var _before_bounds := Rect2i()
var _stroke_changed := false
var _instance_stroke := {}
var _instances_before: Terrain3DScatterData

func _init() -> void:
	instance_placement.mode = Terrain3DAttachmentSettings.Mode.SNAP

func _ready() -> void:
	# Older paint layers were locked automatically. Migrate that lock once; later
	# locks applied with Godot's own Lock command remain under the user's control.
	if _placement_editor_version == 0:
		if not self is Terrain3DStamp and has_meta("_edit_lock_"):
			remove_meta("_edit_lock_")
		_placement_editor_version = 1
	set_notify_transform(true)
	set_process(true)
	_ensure_host()

func _exit_tree() -> void:
	if is_instance_valid(_last_host) and not _last_host.is_queued_for_deletion():
		var stack := _last_host.get_layer_stack()
		if stack:
			stack.call_deferred("invalidate")

func _process(delta: float) -> void:
	_poll_time += delta
	if _poll_time < 0.2:
		return
	_poll_time = 0.0
	_ensure_host()
	var state := hash([slots, bindings.fingerprint() if bindings else 0, enabled, get_index(), height_mode, height_opacity, paint_enabled, instance_mode, instance_opacity, mask_keys, mask_categories, instance_placement.fingerprint() if instance_placement else 0, scatter_data])
	for slot in slots:
		if slot:
			state = hash([state, slot.key, slot.default_resource, slot.preview_resource])
	for slot in instance_slots:
		state = hash([state, slot.fingerprint() if slot else 0])
	if state != _state_hash:
		_state_hash = state
		_changed()

func regenerate_programs() -> void:
	var host := get_terrain()
	if host:
		host.regenerate_programs()

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		# Moving a node changes its placement, not its palette or source counts.
		if is_inside_tree():
			update_configuration_warnings()
			update_gizmos()
			var host := get_terrain()
			if host and host.get_layer_stack():
				host.get_layer_stack().invalidate_layer(self)
	elif what == NOTIFICATION_EDITOR_PRE_SAVE:
		var host := get_terrain()
		if host and host.get_layer_stack():
			host.get_layer_stack().prepare_save()
		if data and not data.is_built_in() and not data.resource_path.is_empty():
			var error := ResourceSaver.save(data, "", ResourceSaver.FLAG_COMPRESS)
			if error != OK:
				push_error("Could not save terrain layer data: " + data.resource_path)
		if scatter_data and not scatter_data.is_built_in() and not scatter_data.resource_path.is_empty():
			if ResourceSaver.save(scatter_data, "", ResourceSaver.FLAG_COMPRESS) != OK:
				push_error("Could not save terrain instance data: " + scatter_data.resource_path)
		if host:
			for index in slots.size():
				var asset := resolve_slot(index, is_instance_valid(_preview_host))
				if asset and asset.prepare_texture_cache(host.get_assets().get_texture_array_size()) == OK:
					asset.get_encoded_cache(host.get_assets().get_active_texture_compression())
					if not asset.is_built_in() and not asset.resource_path.is_empty():
						ResourceSaver.save(asset)

func _changed() -> void:
	_edit_assets = null
	if is_inside_tree():
		update_configuration_warnings()
		update_gizmos()
		layer_changed.emit()
		var host := get_terrain()
		if host and host.get_layer_stack():
			host.get_layer_stack().invalidate_layer(self)

func _data_changed() -> void:
	var host := get_terrain() if is_inside_tree() else null
	if not host or not host.get_layer_stack() or not data.last_changed_bounds.has_area():
		_changed()
		return
	var bounds := data.last_changed_bounds
	var world := Rect2(_source_to_world(bounds.position), Vector2.ZERO)
	for corner in [bounds.end, Vector2(bounds.position.x, bounds.end.y), Vector2(bounds.end.x, bounds.position.y)]:
		world = world.expand(_source_to_world(corner))
	_edit_assets = null
	host.get_layer_stack().remember_layer_bounds(self)
	host.get_layer_stack().invalidate_area(world)
	update_gizmos()
	layer_changed.emit()

func _parent_terrain() -> Terrain3D:
	var parent := get_parent()
	var preview: Terrain3D
	while parent:
		if parent is Terrain3D:
			return parent
		if not preview and parent is Terrain3DLayer and is_instance_valid(parent._preview_host) and not parent._preview_host.is_queued_for_deletion():
			preview = parent._preview_host
		parent = parent.get_parent()
	return preview

func participates() -> bool:
	return enabled and Terrain3DPlacementSolver.layer_enabled(self)

func get_terrain() -> Terrain3D:
	return _parent_terrain() if _parent_terrain() else _preview_host

func _ensure_host() -> void:
	if not is_inside_tree():
		return
	var parent := _parent_terrain()
	if not parent:
		var ancestor := get_parent()
		while ancestor:
			if ancestor is Terrain3DLayer and not ancestor.is_node_ready():
				call_deferred("_ensure_host")
				return
			ancestor = ancestor.get_parent()
	if not Engine.is_editor_hint() and not parent and has_meta("_terrain3d_layer_template"):
		if not _baked_only:
			push_error("This layer is a slot-only authoring template. Place it under Terrain3D and bind its materials before export.")
			_baked_only = true
		return
	if parent and is_instance_valid(_preview_host):
		remove_child(_preview_host)
		_preview_host.queue_free()
		_preview_host = null
	if not parent and not is_instance_valid(_preview_host):
		_preview_host = Terrain3D.new()
		_preview_host.name = "_Terrain3DPreview"
		_preview_host.set_meta("_terrain3d_preview_owner", get_instance_id())
		_preview_host.free_editor_textures = false
		_preview_host.vertex_spacing = preview_vertex_spacing
		_preview_host.region_size = Terrain3D.SIZE_64
		if preview_material:
			_preview_host.material = preview_material.duplicate(true)
		else:
			var material := Terrain3DMaterial.new()
			material.world_background = Terrain3DMaterial.NONE
			_preview_host.material = material
		add_child(_preview_host, false, Node.INTERNAL_MODE_BACK)
		_preview_host.region_size = Terrain3D.SIZE_64
	var host := get_terrain()
	var bake_owner: Node = parent if parent else self
	var bake: Resource = bake_owner.get_meta("_terrain3d_layer_bake") if bake_owner.has_meta("_terrain3d_layer_bake") else null
	if bake and not Engine.is_editor_hint():
		if not _baked_only:
			_baked_only = true
			if not parent:
				bake.call("apply", host)
		return
	if host != _last_host:
		var stack := host.ensure_layer_stack()
		if stack:
			_last_host = host
			stack.invalidate()
		else:
			call_deferred("_ensure_host")

func source_position(world: Vector2) -> Vector2:
	return planar_transform().affine_inverse() * world + pivot if is_transform_valid() else Vector2(INF, INF)

func is_transform_valid() -> bool:
	var basis := (global_transform if is_inside_tree() else transform).basis
	return absf(basis.x.y) < 0.00001 and absf(basis.z.y) < 0.00001 and absf(basis.y.x) < 0.00001 and absf(basis.y.z) < 0.00001 and absf(basis.y.y) > 0.00001 and absf(planar_transform().determinant()) > 0.00001

func uses_local_transform() -> bool:
	return true

func planar_transform() -> Transform2D:
	var pose := global_transform if is_inside_tree() else transform
	return Transform2D(Vector2(pose.basis.x.x, pose.basis.x.z), Vector2(pose.basis.z.x, pose.basis.z.z), Vector2(pose.origin.x, pose.origin.z))

func source_bounds() -> Rect2:
	if not data or not is_transform_valid():
		return Rect2()
	var bounds := data.get_bounds().grow(data.spacing)
	var result := Rect2(_source_to_world(bounds.position), Vector2.ZERO)
	for corner in [bounds.end, Vector2(bounds.position.x, bounds.end.y), Vector2(bounds.end.x, bounds.position.y)]:
		result = result.expand(_source_to_world(corner))
	return result

func height_value(source: float) -> float:
	return source * global_basis.y.y + global_position.y

func source_height(value: float) -> float:
	return (value - global_position.y) / global_basis.y.y

func resolve_slot(index: int, preview: bool = false) -> Terrain3DTextureAsset:
	if index < 0 or index >= slots.size() or not slots[index]:
		return null
	var slot := slots[index]
	var resource: Terrain3DTextureAsset = bindings.resolve(slot.key) if bindings else null
	var host := get_terrain()
	if not resource and host and host.layer_bindings and host.layer_bindings.has_method("resolve"):
		resource = host.layer_bindings.call("resolve", slot.key)
	if not resource:
		resource = slot.default_resource
	if not resource and preview:
		resource = slot.preview_resource
	return resource

func get_edit_assets() -> Terrain3DAssets:
	if _edit_assets:
		return _edit_assets
	_edit_assets = Terrain3DAssets.new()
	var textures: Array[Terrain3DTextureAsset] = []
	for index in mini(slots.size(), Terrain3DAssets.MAX_TEXTURES):
		var asset := resolve_slot(index, is_instance_valid(_preview_host))
		asset = asset.duplicate() if asset else Terrain3DTextureAsset.new()
		asset.id = index
		asset.name = str(slots[index].key) if slots[index] else "Missing slot"
		textures.append(asset)
	_edit_assets.texture_list = textures
	var meshes: Array[Terrain3DMeshAsset] = []
	for index in mini(instance_slots.size(), Terrain3DAssets.MAX_MESHES):
		var resource := resolve_instance_slot(index, is_instance_valid(_preview_host))
		var mesh: Terrain3DMeshAsset
		if resource is Terrain3DMeshAsset:
			mesh = resource.duplicate()
		else:
			mesh = Terrain3DMeshAsset.new()
			if resource is PackedScene:
				mesh.set_meta("_terrain3d_scene_preview", resource)
		mesh.id = index
		mesh.name = str(instance_slots[index].key) if instance_slots[index] else "Missing slot"
		mesh.enabled = instance_slots[index].enabled if instance_slots[index] else false
		var count := 0
		if scatter_data:
			for record: Dictionary in scatter_data.records.values():
				if record.slot == index:
					count += 1
		mesh.set_meta("_terrain3d_source_count", count)
		meshes.append(mesh)
	_edit_assets.mesh_list = meshes
	return _edit_assets

func resolve_instance_slot(index: int, preview: bool = false) -> Resource:
	if index < 0 or index >= instance_slots.size() or not instance_slots[index]:
		return null
	var slot := instance_slots[index]
	var resource := bindings.resolve_instance(slot.key, slot.kind) if bindings else null
	var host := get_terrain()
	if not resource and host and host.layer_bindings is Terrain3DLayerBindings:
		resource = host.layer_bindings.resolve_instance(slot.key, slot.kind)
	if not resource:
		resource = slot.default_mesh if slot.kind == Terrain3DInstanceSlot.Kind.MESH else slot.default_scene
	if not resource and preview:
		resource = slot.preview_mesh if slot.kind == Terrain3DInstanceSlot.Kind.MESH else slot.preview_scene
	return resource

func instance_world_pose(local: Transform3D, inherit_scale: bool) -> Transform3D:
	var point := _source_to_world(Vector2(local.origin.x, local.origin.z))
	var basis := global_basis if inherit_scale else Terrain3DPlacementSolver.parent_rotation(self)
	return Transform3D(basis * local.basis, Vector3(point.x, global_position.y + global_basis.y.y * local.origin.y, point.y))

func source_content_bounds() -> Rect2:
	var result := data.get_bounds() if data else Rect2()
	if scatter_data:
		var instances := scatter_data.get_bounds()
		result = result.merge(instances) if result.has_area() else instances
	var configurations: Array = programs.duplicate()
	for index in slots.size():
		if not slots[index]:
			continue
		configurations.append_array(slots[index].programs)
		if slots[index].programs.is_empty() and slots[index].inherit_asset_programs:
			var asset := resolve_slot(index, is_instance_valid(_preview_host))
			if asset:
				configurations.append_array(asset.programs)
	for slot: Terrain3DProgramSlot in configurations:
		if slot and slot.enabled and slot.bounds.has_area():
			result = result.merge(slot.bounds) if result.has_area() else slot.bounds
	return result

func create_instance_data() -> void:
	if not scatter_data:
		var created := Terrain3DScatterData.new()
		created.mask.spacing = get_terrain().vertex_spacing if get_terrain() else preview_vertex_spacing
		commit_configuration("Create Terrain Instance Data", {"scatter_data": null}, {"scatter_data": created})

func make_instances_unique() -> void:
	if scatter_data:
		commit_configuration("Make Terrain Instances Unique", {"scatter_data": scatter_data}, {"scatter_data": scatter_data.clone_source()})

func make_data_unique() -> void:
	if data:
		commit_configuration("Make Terrain Layer Data Unique", {"data": data}, {"data": data.clone_source()})

func create_data() -> void:
	if not data:
		var created := Terrain3DLayerData.new()
		created.spacing = get_terrain().vertex_spacing if get_terrain() else preview_vertex_spacing
		commit_configuration("Create Terrain Layer Data", {"data": null}, {"data": created})

func apply_configuration(properties: Dictionary) -> void:
	var children: Dictionary = properties.get("_pivot_children", {})
	for property: String in properties:
		if property != "_pivot_children":
			set(property, properties[property])
	for path: NodePath in children:
		var child := get_node_or_null(path) as Node3D
		if child:
			var pose: Transform3D = children[path]
			var delta := pose.origin - child.transform.origin
			child.transform = pose
			if child is Terrain3DAttachmentGroup:
				child.rebase_authored_origin(delta)
	_changed()

func _pivot_children(delta: Vector2 = Vector2.ZERO) -> Dictionary:
	var result := {}
	for child in get_children():
		if child is Node3D and not child.top_level:
			var pose: Transform3D = child.transform
			pose.origin += Vector3(delta.x, 0, delta.y)
			result[get_path_to(child)] = pose
	return result

func set_pivot_preserving_position(value: Vector2) -> void:
	var delta := value - pivot
	var pose := global_transform
	pose.origin += pose.basis * Vector3(delta.x, 0, delta.y)
	apply_configuration({"pivot": value, "global_transform": pose, "_pivot_children": _pivot_children(-delta)})

func center_pivot() -> void:
	var bounds := source_content_bounds()
	if bounds.has_area():
		var centered := bounds.get_center()
		var pose := global_transform
		var delta := centered - pivot
		pose.origin += pose.basis * Vector3(delta.x, 0, delta.y)
		commit_configuration("Center Terrain Layer Pivot", {"pivot": pivot, "global_transform": global_transform, "_pivot_children": _pivot_children()}, {"pivot": centered, "global_transform": pose, "_pivot_children": _pivot_children(-delta)})

func commit_configuration(title: String, before: Dictionary, after: Dictionary) -> void:
	var host := get_terrain()
	var plugin := host.get_plugin() if host else null
	if Engine.is_editor_hint() and plugin and plugin.has_method("create_undo_action"):
		plugin.call("create_undo_action", title)
		plugin.call("add_undo_method", apply_configuration.bind(before))
		plugin.call("add_do_method", apply_configuration.bind(after))
		apply_configuration(after)
		plugin.call("commit_action", false)
	else:
		apply_configuration(after)
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()

func begin_operation(tool: int, operation: int) -> bool:
	_instances_before = null
	if tool == Terrain3DEditor.INSTANCER:
		if locked or not participates() or not scatter_data or not is_transform_valid():
			push_warning("Enable and unlock the layer, then use Create Instance Data before painting instances.")
			return false
		_instances_before = scatter_data.clone_source()
		_instance_stroke = {}
		return true
	if locked or not participates() or not data:
		push_warning("Unlock and enable this layer, and assign its data before editing.")
		return false
	if tool not in [Terrain3DEditor.SCULPT, Terrain3DEditor.HEIGHT, Terrain3DEditor.TEXTURE, Terrain3DEditor.COLOR, Terrain3DEditor.ROUGHNESS]:
		push_warning("This tool edits the base terrain or instances. Layer editing supports heights, materials, color and roughness.")
		return false
	if not is_transform_valid():
		return false
	if tool in [Terrain3DEditor.SCULPT, Terrain3DEditor.HEIGHT] and (height_opacity <= 0.00001 or absf(height_value(1) - height_value(0)) < 0.00001):
		push_warning("Height painting requires a nonzero height opacity and height scale.")
		return false
	_before_chunks = {}
	_before_bounds = data.sample_bounds
	_stroke_changed = false
	return true

func _source_to_world(source: Vector2) -> Vector2:
	return planar_transform() * (source - pivot)

func paint_brush(position_world: Vector3, camera_angle: float, brush: Dictionary, tool: int, operation: int) -> void:
	if tool == Terrain3DEditor.INSTANCER:
		Terrain3DScatterBrush.paint(self, position_world, brush, operation, _instance_stroke, camera_angle)
		return
	var diameter: float = maxf(brush.get("size", 10.0), 0.1)
	var center := Vector2(position_world.x, position_world.z)
	var world_bounds := Rect2(center - Vector2.ONE * diameter * 0.5, Vector2.ONE * diameter)
	var source_bounds := Rect2(source_position(world_bounds.position), Vector2.ZERO)
	for corner in [world_bounds.end, Vector2(world_bounds.end.x, world_bounds.position.y), Vector2(world_bounds.position.x, world_bounds.end.y)]:
		source_bounds = source_bounds.expand(source_position(corner))
	var first := Vector2i((source_bounds.position / data.spacing).floor())
	var last := Vector2i((source_bounds.end / data.spacing).ceil())
	var strength: float = brush.get("strength", 0.1)
	var pressure: float = brush.get("mouse_pressure", 1.0)
	strength *= pressure if pressure > 0.0 else 1.0
	var brush_image: Image = brush.get("brush_image")
	var old_data := data.clone_source(Rect2i(first - Vector2i.ONE, last - first + Vector2i.ONE * 3)) if operation == Terrain3DEditor.AVERAGE else data
	var stack: Terrain3DLayerStack = get_terrain().get_layer_stack()
	data.begin_edit()
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			var pixel := Vector2i(x, y)
			var world := _source_to_world(Vector2(pixel) * data.spacing)
			var uv := (world - center) / diameter
			if brush.get("align_to_view", false):
				uv = uv.rotated(-camera_angle)
			uv += Vector2.ONE * 0.5
			if uv.x < 0 or uv.y < 0 or uv.x >= 1 or uv.y >= 1:
				continue
			var alpha := brush_image.get_pixelv(Vector2i(uv * Vector2(brush_image.get_size()))).r if brush_image else maxf(0, 1.0 - (uv - Vector2.ONE * 0.5).length() * 2.0)
			alpha = pow(clampf(alpha, 0, 1), brush.get("gamma", 1.0))
			if alpha < 0.001:
				continue
			var channel := 0 if tool in [Terrain3DEditor.SCULPT, Terrain3DEditor.HEIGHT] else (1 if tool == Terrain3DEditor.TEXTURE else 2)
			var amount := clampf(alpha * strength, 0, 1)
			var chunk := data._chunk_key(pixel)
			if not _before_chunks.has(chunk):
				_before_chunks[chunk] = data.copy_chunk(chunk)
			if erase_mode:
				data.erase(pixel, channel, amount, false)
			elif channel == 0:
				var value := data.get_pixel(pixel, 0).r
				var lower := stack.height_before(self, world)
				var current := stack.height_through(self, world, old_data)
				var desired := current
				if operation == Terrain3DEditor.AVERAGE:
					var average := 0.0
					for offset in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
						average += stack.height_through(self, _source_to_world(Vector2(pixel + offset) * data.spacing), old_data) * 0.2
					desired = lerpf(current, average, amount)
				elif tool == Terrain3DEditor.HEIGHT or operation == Terrain3DEditor.REPLACE:
					desired = lerpf(current, brush.get("height", 0.0), amount)
				else:
					desired += alpha * strength * (-1.0 if operation == Terrain3DEditor.SUBTRACT else 1.0)
				var contribution := (desired - lower) / height_opacity if height_mode == HeightMode.ADD else (desired - lower * (1.0 - height_opacity)) / height_opacity
				value = source_height(contribution)
				data.set_pixel(pixel, 0, Color(value, 0, 0, 1), 1, false)
			elif channel == 1:
				var ids: Array = brush.get("texture_asset_ids", [0])
				if ids.is_empty() or ids[0] >= slots.size():
					continue
				if operation == Terrain3DEditor.SUBTRACT:
					data.erase(pixel, 1, amount, false)
				elif alpha >= 0.5:
					var id: int = ids[0]
					var bits := (id << 27) | (id << 22)
					if brush.get("enable_angle", false):
						bits |= (roundi(float(brush.get("angle", 0.0)) / 22.5) & 15) << 10
					data.set_control(pixel, bits, 1.0)
			else:
				var value := data.get_pixel(pixel, 2)
				if tool == Terrain3DEditor.COLOR:
					var target: Color = brush.get("color", Color.WHITE)
					var roughness := value.a
					value = value.srgb_to_linear().lerp(target.srgb_to_linear(), amount).linear_to_srgb()
					value.a = roughness
				else:
					value.a = lerpf(value.a, clampf(brush.get("roughness", 0.0) + 0.5, 0, 1), amount)
				data.set_pixel(pixel, 2, value, 1.0, false)
			_stroke_changed = true
	data.end_edit()
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()

func restore_patch(target: Terrain3DLayerData, chunks: Dictionary, bounds: Rect2i) -> void:
	target._read_control_cache.clear()
	for key: Vector2i in chunks:
		if chunks[key] == null:
			target.chunks.erase(key)
		else:
			var maps := {}
			for channel: int in chunks[key]:
				maps[channel] = chunks[key][channel].duplicate()
			target.chunks[key] = maps
	target.sample_bounds = bounds
	target._used_slots_dirty = true
	target.emit_changed()

func end_operation(plugin: Object) -> void:
	if _instances_before:
		if plugin and _instance_stroke.get("changed", false):
			plugin.call("create_undo_action", "Terrain3D Layer Instances")
			plugin.call("add_undo_method", restore_instances.bind(scatter_data, _instances_before))
			plugin.call("add_do_method", restore_instances.bind(scatter_data, scatter_data.clone_source()))
			plugin.call("commit_action", false)
		_instances_before = null
		return
	if _stroke_changed and plugin:
		var after := {}
		for key: Vector2i in _before_chunks:
			after[key] = data.copy_chunk(key)
		plugin.call("create_undo_action", "Terrain3D Layer Paint")
		plugin.call("add_undo_method", restore_patch.bind(data, _before_chunks, _before_bounds))
		plugin.call("add_do_method", restore_patch.bind(data, after, data.sample_bounds))
		plugin.call("commit_action", false)
	_before_chunks = {}

func restore_instances(target: Terrain3DScatterData, snapshot: Terrain3DScatterData) -> void:
	target.records = snapshot.records.duplicate(true)
	target.next_id = snapshot.next_id
	target.mask = snapshot.mask.clone_source() if snapshot.mask else null
	target.emit_changed()

func _get_configuration_warnings() -> PackedStringArray:
	var result := PackedStringArray()
	if not data and not scatter_data and not programs.any(func(slot: Terrain3DProgramSlot): return slot and slot.enabled):
		result.append("Assign a Terrain3DLayerData resource before painting or importing heights.")
	if not is_transform_valid():
		result.append("Terrain layers support movement, Y rotation and nonzero scale. X/Z tilt cannot be represented by a heightfield.")
	var keys := {}
	for slot in slots:
		if not slot or slot.key.is_empty() or keys.has(slot.key):
			result.append("Material slots must have unique, nonempty keys. Painted slot order is stable.")
		elif slot:
			keys[slot.key] = true
	if slots.size() > Terrain3DAssets.MAX_TEXTURES:
		result.append("A layer supports at most 32 local material slots.")
	return result
