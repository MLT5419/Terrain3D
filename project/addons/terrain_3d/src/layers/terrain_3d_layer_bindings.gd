# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DLayerBindings
extends Resource
## Shareable skin. Keys are material roles, not GPU texture-array indices.

@export var materials: Dictionary[StringName, Terrain3DTextureAsset] = {}:
	set(value):
		materials = value
		emit_changed()

func resolve(key: StringName) -> Terrain3DTextureAsset:
	return materials.get(key)
