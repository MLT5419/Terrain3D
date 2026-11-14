# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
@tool
extends EditorExportPlugin

const COOKED_DIRECTORY := "res://.godot/terrain3d_export"
var plugin: EditorPlugin
var _hash: String
var _platform_name := ""
var _features := PackedStringArray()
var _staged_resources := {}
var _staged_files := {}


func _get_name() -> String:
	return "Terrain3DExportPlugin"


func _begin_customize_resources(platform: EditorExportPlatform, features: PackedStringArray) -> bool:
	_platform_name = platform.get_os_name()
	_features = features
	# Change when the resource layout or export conversion policy changes.
	_hash = "Terrain3D-program-bake-v1|" + _platform_name + "|" + "|".join(features)
	_hash += "|" + str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "gl_compatibility"))
	_hash += "|" + str(ProjectSettings.get_setting("rendering/renderer/rendering_method.mobile", "mobile"))
	return true


func _export_begin(features: PackedStringArray, is_debug: bool, path: String, flags: int) -> void:
	_platform_name = get_export_platform().get_os_name()
	_features = features
	_staged_resources.clear()
	_staged_files.clear()


func _get_customization_configuration_hash() -> int:
	return hash(_hash)


func _begin_customize_scenes(platform: EditorExportPlatform, features: PackedStringArray) -> bool:
	return true


func _layer_manifest(path: String) -> String:
	return COOKED_DIRECTORY.path_join("layers_" + (path + _hash).sha256_text() + ".cfg")


func _contains_layers(scene: PackedScene, seen: Dictionary = {}) -> bool:
	if seen.has(scene.get_instance_id()):
		return false
	seen[scene.get_instance_id()] = true
	var state := scene.get_state()
	for node in state.get_node_count():
		var instance := state.get_node_instance(node)
		if instance and _contains_layers(instance, seen):
			return true
		for property in state.get_node_property_count(node):
			var value: Variant = state.get_node_property_value(node, property)
			if _has_programs(value):
				return true
			if value is Script:
				while value:
					if value.get_global_name() in [&"Terrain3DLayer", &"Terrain3DAttachmentGroup"]:
						return true
					value = value.get_base_script()
	return false


func _has_programs(value: Variant) -> bool:
	if value is Terrain3DProgramSlot:
		return true
	if value is Terrain3DAssets:
		for asset in value.texture_list:
			if asset and not asset.programs.is_empty():
				return true
	elif value is Terrain3DTextureAsset or value is Terrain3DLayerSlot:
		return not value.programs.is_empty()
	elif value is Array:
		for entry in value:
			if _has_programs(entry):
				return true
	return false


func _stage_file(path: String) -> void:
	if not _staged_files.has(path) and FileAccess.file_exists(path):
		add_file(path, FileAccess.get_file_as_bytes(path), false)
		_staged_files[path] = true


func _customize_scene(scene: Node, path: String) -> Node:
	var layers: Array[Terrain3DLayer] = []
	var attachments: Array[Terrain3DAttachmentGroup] = []
	var terrains: Array[Terrain3D] = []
	var nodes: Array[Node] = [scene]
	for node in scene.find_children("*", "", true, false):
		if node.owner:
			nodes.append(node)
	var original_owners := {}
	var owner_nodes := {}
	for node in nodes:
		original_owners[node.get_instance_id()] = node.owner.get_instance_id() if node.owner else 0
		if node.owner:
			owner_nodes[node.owner.get_instance_id()] = node.owner
		if node is Terrain3DLayer:
			layers.append(node)
		if node is Terrain3DAttachmentGroup:
			attachments.append(node)
		if node is Terrain3D:
			terrains.append(node)
	if layers.is_empty() and attachments.is_empty() and not terrains.any(func(host: Terrain3D): return _has_programs(host.programs) or _has_programs(host.assets)):
		return null
	# A real World3D makes the ordinary compositor usable here; it is removed before packing.
	var view := SubViewport.new()
	view.own_world_3d = true
	view.disable_3d = true
	Engine.get_main_loop().root.add_child(view)
	view.add_child(scene)
	var hosts := {}
	for layer in layers:
		layer._ensure_host()
		hosts[layer.get_terrain()] = true
	for host in terrains:
		if _has_programs(host.programs) or _has_programs(host.assets):
			hosts[host] = true
	for attachment in attachments:
		if attachment.terrain_interaction and attachment.terrain_interaction.mode != Terrain3DTerrainInteraction.Mode.DISABLED:
			attachment.update_attachments(true)
			var host: Terrain3D = attachment.terrain if attachment.terrain else Terrain3DPlacementSolver.resolve_host(attachment)
			if host:
				hosts[host] = true
	var manifest := ConfigFile.new()
	var paths := PackedStringArray()
	var promoted_hosts: Array[Terrain3D] = []
	var promoted_scenes: Array[Node] = []
	DirAccess.make_dir_recursive_absolute(COOKED_DIRECTORY)
	for host: Terrain3D in hosts:
		var stack: Terrain3DLayerStack = host.ensure_layer_stack()
		stack.exporting = true
		if stack.recompose(true) != OK:
			# A slot-only prefab is an authoring template. Its placed instances are baked
			# in their enclosing scene with that instance's bindings, never preview assets.
			if host.has_meta("_terrain3d_preview_owner") and not stack.errors.is_empty() and Array(stack.errors).all(func(message: String): return message.contains("no material bound") or message.contains("no instance resource bound")):
				var template: Node = instance_from_id(host.get_meta("_terrain3d_preview_owner"))
				template.set_meta("_terrain3d_layer_template", true)
				get_export_platform().add_message(EditorExportPlatform.EXPORT_MESSAGE_WARNING, "Terrain3D", "%s is an unbound authoring template; only its bound placements can be baked." % path)
				continue
			get_export_platform().add_message(EditorExportPlatform.EXPORT_MESSAGE_ERROR, "Terrain3D", "Cannot bake %s: %s" % [path, "; ".join(stack.errors)])
			view.remove_child(scene)
			view.free()
			return null
		var bake := Terrain3DLayerBake.new()
		bake.vertex_spacing = host.vertex_spacing
		bake.region_size = host.region_size
		bake.assets = _customize_resource(host.get_assets(), "")
		for region: Terrain3DRegion in host.data.get_regions_active():
			bake.regions.append(region.duplicate(true))
		var owner_node: Node = instance_from_id(host.get_meta("_terrain3d_preview_owner")) if host.has_meta("_terrain3d_preview_owner") else host
		var bake_path := COOKED_DIRECTORY.path_join("layer_" + (path + str(scene.get_path_to(owner_node)) + _hash).sha256_text() + ".res")
		DirAccess.make_dir_recursive_absolute(COOKED_DIRECTORY)
		if ResourceSaver.save(bake, bake_path, ResourceSaver.FLAG_COMPRESS) != OK:
			get_export_platform().add_message(EditorExportPlatform.EXPORT_MESSAGE_ERROR, "Terrain3D", "Could not save " + bake_path)
			continue
		bake = ResourceLoader.load(bake_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		if owner_node is Terrain3DLayer:
			# Turn the temporary preview host into the exported standalone terrain.
			# Its generated children remain internal; the terrain itself becomes owned.
			owner_node.remove_child(host)
			owner_node.add_child(host)
			host.owner = scene
			promoted_hosts.append(host)
			host.remove_meta("_terrain3d_preview_owner")
		host.set_meta("_terrain3d_layer_bake", bake)
		host.data_directory = ""
		host.assets = bake.assets
		host.layer_bindings = null
		host.programs = []
		host.free_editor_textures = false
		paths.append(bake_path)
		_stage_file(bake_path)
		_stage_references(bake)
		var output := stack.scatter.promote_scenes(scene, COOKED_DIRECTORY, path + _hash)
		if output.get("error", OK) != OK:
			get_export_platform().add_message(EditorExportPlatform.EXPORT_MESSAGE_ERROR, "Terrain3D", "Could not save full scene instances in " + path)
			view.remove_child(scene)
			view.free()
			return null
		promoted_scenes.append_array(output.nodes)
		promoted_scenes.append_array(stack.program_scheduler.promote_nodes(scene))
		for scene_path: String in output.files:
			paths.append(scene_path)
			_stage_file(scene_path)
			_stage_references(ResourceLoader.load(scene_path))
	# A classic terrain with attachment groups keeps its external region files. Stage
	# its cooked palette as well, including when Godot reuses this customized scene.
	for host in terrains:
		if hosts.has(host):
			continue
		var assets := _customize_resource(host.get_source_assets(), "")
		var asset_path := COOKED_DIRECTORY.path_join("assets_" + (path + str(scene.get_path_to(host)) + _hash).sha256_text() + ".res")
		if ResourceSaver.save(assets, asset_path, ResourceSaver.FLAG_COMPRESS) != OK:
			get_export_platform().add_message(EditorExportPlatform.EXPORT_MESSAGE_ERROR, "Terrain3D", "Could not save " + asset_path)
			continue
		host.assets = ResourceLoader.load(asset_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		paths.append(asset_path)
		_stage_file(asset_path)
		_stage_references(host.assets)
	manifest.set_value("layers", "bakes", paths)
	manifest.save(_layer_manifest(path))
	for attachment in attachments:
		attachment.update_attachments(true)
	var markers: Array[Node3D] = []
	var replaced_owners := {}
	for layer in layers + attachments:
		# Plain markers preserve node paths/groups without retaining prefab source
		# dependencies or running authoring scripts in the exported game.
		var marker := Node3D.new()
		marker.name = layer.name
		marker.transform = layer.transform
		marker.visible = layer.visible
		markers.append(marker)
		original_owners[marker.get_instance_id()] = original_owners.get(layer.get_instance_id(), 0)
		replaced_owners[layer.get_instance_id()] = true
		layer.replace_by(marker, true)
		if layer == scene:
			scene = marker
		layer.free()
	for node in nodes + markers:
		if is_instance_valid(node) and node != scene:
			var owner_id: int = original_owners.get(node.get_instance_id(), 0)
			var desired: Node = null if replaced_owners.has(owner_id) else owner_nodes.get(owner_id)
			# Keep ordinary scene ownership (scripts may use owner). Authoring roots
			# lose their source scene and their direct owned nodes become scene-owned.
			node.owner = desired if is_instance_valid(desired) and desired.is_ancestor_of(node) else scene
	for node in promoted_hosts + promoted_scenes:
		if is_instance_valid(node) and node != scene:
			node.owner = scene
	view.remove_child(scene)
	view.free()
	return scene


func _export_file(path: String, type: String, features: PackedStringArray) -> void:
	# Authoring masters and cached variants are not runtime dependencies. Selected
	# cooked copies live separately and are reached through the exported assets.
	if type == "PackedScene" and _contains_layers(ResourceLoader.load(path)):
		var manifest := ConfigFile.new()
		if manifest.load(_layer_manifest(path)) == OK:
			for bake_path: String in manifest.get_value("layers", "bakes", PackedStringArray()):
				_stage_file(bake_path)
				_stage_references(ResourceLoader.load(bake_path))
		return
	if type == "Terrain3DTextureCache" and not path.begins_with(COOKED_DIRECTORY + "/"):
		skip()
	elif type in ["Terrain3DAssets", "Terrain3DTextureAsset", "PackedScene"] or path.get_extension() in ["res", "tres", "tscn", "scn"]:
		_stage_references(ResourceLoader.load(path))


func _stage_references(value: Variant, depth: int = 0) -> void:
	if depth > 64:
		return
	if value is Array or value is Dictionary:
		for entry: Variant in value:
			_stage_references(value[entry] if value is Dictionary else entry, depth + 1)
		return
	if not value is Resource or _staged_resources.has(value.get_instance_id()):
		return
	_staged_resources[value.get_instance_id()] = true
	if value is Terrain3DAssets or value is Terrain3DTextureAsset:
		var runtime := _customize_resource(value, "")
		var layers: Array = runtime.texture_list if runtime is Terrain3DAssets else [runtime]
		for layer: Terrain3DTextureAsset in layers:
			if not layer:
				continue
			var cache := layer.get_texture_cache()
			if cache and cache.resource_path.begins_with(COOKED_DIRECTORY + "/") and not _staged_files.has(cache.resource_path):
				add_file(cache.resource_path, FileAccess.get_file_as_bytes(cache.resource_path), false)
				_staged_files[cache.resource_path] = true
	elif value is PackedScene:
		var state: SceneState = value.get_state()
		for node in state.get_node_count():
			for property in state.get_node_property_count(node):
				_stage_references(state.get_node_property_value(node, property), depth + 1)
	elif not (value is Terrain3DTextureCache or value is Image or value is Texture or value is Material or value is Mesh or value is Script):
		for property: Dictionary in value.get_property_list():
			if property.usage & PROPERTY_USAGE_STORAGE:
				_stage_references(value.get(property.name), depth + 1)


func resolve_compression(requested: int) -> int:
	if requested != Terrain3DTextureCache.AUTO:
		return requested
	var renderer: String = ProjectSettings.get_setting("rendering/renderer/rendering_method", "gl_compatibility")
	if _platform_name in ["Android", "iOS"]:
		renderer = ProjectSettings.get_setting("rendering/renderer/rendering_method.mobile", renderer)
		return Terrain3DTextureCache.ETC2 if renderer == "gl_compatibility" else Terrain3DTextureCache.ASTC_4X4
	if _platform_name == "Web" or "web" in _features:
		return Terrain3DTextureCache.ETC2
	return Terrain3DTextureCache.BC3 if renderer == "gl_compatibility" else Terrain3DTextureCache.BC7


func _customize_resource(resource: Resource, path: String) -> Resource:
	if resource is Terrain3DAssets:
		var size: int = resource.get_texture_array_size()
		var compression := resolve_compression(resource.texture_compression)
		var assets := Terrain3DAssets.new()
		assets.resource_name = resource.resource_name
		assets.mesh_list = resource.mesh_list
		assets.texture_compression = compression
		assets.texture_resolution = size
		var layers: Array[Terrain3DTextureAsset] = []
		for asset: Terrain3DTextureAsset in resource.texture_list:
			layers.append(_runtime_layer(asset, size, compression))
		assets.texture_list = layers
		return assets
	if resource is Terrain3DTextureAsset and (not resource.get_runtime_material_cache() or not resource.programs.is_empty()):
		return _runtime_layer(resource, resource.material_texture_size, resolve_compression(Terrain3DTextureCache.AUTO))
	return null


func _cooked_cache(cache: Terrain3DTextureCache) -> Terrain3DTextureCache:
	var path := COOKED_DIRECTORY.path_join(cache.signature + "_" + Terrain3DTextureCache.compression_name(cache.compression) + ".res")
	if cache.save_external(path) != OK:
		push_error("Terrain3D: Could not save the platform texture cache: " + path)
		return null
	return ResourceLoader.load(path, "Terrain3DTextureCache", ResourceLoader.CACHE_MODE_REPLACE) as Terrain3DTextureCache


func _runtime_layer(asset: Terrain3DTextureAsset, size: int, compression: int = Terrain3DTextureCache.BC7) -> Terrain3DTextureAsset:
	if not asset:
		return asset
	if asset.get_runtime_material_cache():
		if asset.programs.is_empty():
			return asset
		var stripped := asset.duplicate() as Terrain3DTextureAsset
		stripped.programs = []
		return stripped
	if asset.prepare_texture_cache(size) != OK:
		push_error("Terrain3D: Cannot prepare texture layer '%s' for export." % asset.name)
		return asset
	var preview := asset.get_prepared_cache()
	var cache := asset.get_encoded_cache(compression)
	asset.set_prepared_cache(preview)
	if not cache:
		push_error("Terrain3D: The requested texture encoder is unavailable for layer '%s'." % asset.name)
		return asset
	cache = _cooked_cache(cache)
	if not cache:
		return asset
	var settings := asset.get_material_settings()
	var layer := asset.duplicate() as Terrain3DTextureAsset
	layer.material = null
	layer.programs = []
	layer.albedo_texture = null
	layer.normal_texture = null
	layer.set_runtime_material_cache(true)
	layer.material_texture_size = size
	layer.set_material_settings(settings)
	layer.set_prepared_cache(null)
	layer.set_texture_cache(cache)
	return layer
