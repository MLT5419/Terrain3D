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
	_hash = "Terrain3D-unified-cache-v4|" + _platform_name + "|" + "|".join(features)
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


func _export_file(path: String, type: String, features: PackedStringArray) -> void:
	# Authoring masters and cached variants are not runtime dependencies. Selected
	# cooked copies live separately and are reached through the exported assets.
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
	if resource is Terrain3DTextureAsset and not resource.get_runtime_material_cache():
		return _runtime_layer(resource, resource.material_texture_size, resolve_compression(Terrain3DTextureCache.AUTO))
	return null


func _cooked_cache(cache: Terrain3DTextureCache) -> Terrain3DTextureCache:
	var path := COOKED_DIRECTORY.path_join(cache.signature + "_" + Terrain3DTextureCache.compression_name(cache.compression) + ".res")
	if cache.save_external(path) != OK:
		push_error("Terrain3D: Could not save the platform texture cache: " + path)
		return null
	return ResourceLoader.load(path, "Terrain3DTextureCache", ResourceLoader.CACHE_MODE_REPLACE) as Terrain3DTextureCache


func _runtime_layer(asset: Terrain3DTextureAsset, size: int, compression: int = Terrain3DTextureCache.BC7) -> Terrain3DTextureAsset:
	if not asset or asset.get_runtime_material_cache():
		return asset
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
	layer.albedo_texture = null
	layer.normal_texture = null
	layer.set_runtime_material_cache(true)
	layer.material_texture_size = size
	layer.set_material_settings(settings)
	layer.set_prepared_cache(null)
	layer.set_texture_cache(cache)
	return layer
