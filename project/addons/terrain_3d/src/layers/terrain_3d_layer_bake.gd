# Copyright © 2026 Terrain3D Contributors.
class_name Terrain3DLayerBake
extends Resource
## Exported result. Contains no layer source maps, material slots, or authoring bindings.

@export_storage var regions: Array[Terrain3DRegion] = []
@export_storage var assets: Terrain3DAssets
@export_storage var vertex_spacing := 1.0
@export_storage var region_size := 64

func apply(host: Terrain3D) -> void:
	host.vertex_spacing = vertex_spacing
	host.region_size = region_size
	host.free_editor_textures = false
	var compiled := Terrain3DAssets.new()
	compiled.texture_compression = assets.texture_compression
	compiled.texture_resolution = assets.texture_resolution
	var textures: Array[Terrain3DTextureAsset] = []
	for asset in assets.texture_list:
		textures.append(asset.duplicate())
	compiled.texture_list = textures
	var meshes: Array[Terrain3DMeshAsset] = []
	for asset in assets.mesh_list:
		meshes.append(asset.duplicate())
	compiled.mesh_list = meshes
	host.set_effective_assets(compiled)
	for region in regions:
		host.data.add_region(region.duplicate(true), false)
	host.data.update_maps()
	host.get_instancer().update_mmis(-1, Vector2i(2147483647, 2147483647), true)
