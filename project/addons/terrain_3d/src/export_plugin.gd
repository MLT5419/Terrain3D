# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Editor Export Plugin for Terrain3D
@tool
extends EditorExportPlugin

# Export PBR layers with baked data only. The editor resources keep their editable sources.

var plugin: EditorPlugin
var _hash: String


func _get_name() -> String:
	return "Terrain3DExportPlugin"

	
func _begin_customize_resources(platform: EditorExportPlatform, features: PackedStringArray) -> bool:
	# Bump this version when the exported cache layout changes.
	_hash = "Terrain3D-PBR-cache-v2"
	for feat: String in features:
		_hash += feat
	_hash += platform.get_os_name()
	return true
	
	
func _customize_resource(resource: Resource, path: String) -> Resource:
	if resource is Terrain3DAssets:
		var size := 0
		for asset: Terrain3DTextureAsset in resource.texture_list:
			if asset and asset.source_mode == Terrain3DTextureAsset.SOURCE_MATERIAL:
				size = maxi(size, asset.material_texture_size)
		if size == 0:
			return null
		var assets := Terrain3DAssets.new()
		assets.resource_name = resource.resource_name
		assets.mesh_list = resource.mesh_list
		var layers: Array[Terrain3DTextureAsset] = []
		for asset: Terrain3DTextureAsset in resource.texture_list:
			layers.append(_runtime_layer(asset, size))
		assets.texture_list = layers
		return assets
	if resource is Terrain3DTextureAsset:
		if resource.source_mode == Terrain3DTextureAsset.SOURCE_MATERIAL and resource.material:
			return _runtime_layer(resource, resource.material_texture_size)
		return null
	#if resource is Terrain3DRegion:
		#var region: Terrain3DRegion = resource.duplicate(true)
		#if region.compressed_color_map != null:
			## Read only compressed color map
			#region.clear_color_map()
		#else:
			## Editable, uncompressed color map
			#region.clear_compressed_color_map()
		#return region
	return null # No changes


func _runtime_layer(asset: Terrain3DTextureAsset, size: int) -> Terrain3DTextureAsset:
	if not asset or asset.source_mode != Terrain3DTextureAsset.SOURCE_MATERIAL:
		return asset
	# Already customized as a child of Terrain3DAssets: keep the shared array resolution.
	if not asset.material:
		return asset
	if asset.bake_material(size) != OK:
		push_error("Terrain3D: Cannot export PBR layer '%s'; its material cache could not be baked." % asset.name)
		return asset
	var cache := asset.get_material_cache()
	var signature := asset.get_material_cache_signature()
	var settings := asset.get_material_settings()
	var layer := asset.duplicate() as Terrain3DTextureAsset
	layer.material = null
	layer.set_runtime_material_cache(true)
	layer.material_texture_size = size
	layer.albedo_texture = null
	layer.normal_texture = null
	layer.set_material_cache(cache)
	layer.set_material_cache_signature(signature)
	layer.set_material_settings(settings)
	return layer
	
	
func _get_customization_configuration_hash() -> int:
	return hash(_hash)
	# DEVELOPMENT ONLY: Forces Godot to skip the cache and run every time
	#return hash(Time.get_ticks_msec())
