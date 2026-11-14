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

@export var meshes: Dictionary[StringName, Terrain3DMeshAsset] = {}:
	set(value):
		meshes = value
		emit_changed()
@export var scenes: Dictionary[StringName, PackedScene] = {}:
	set(value):
		scenes = value
		emit_changed()

func resolve_instance(key: StringName, kind: int) -> Resource:
	return meshes.get(key) if kind == Terrain3DInstanceSlot.Kind.MESH else scenes.get(key)

func fingerprint() -> int:
	return hash([materials, meshes, scenes])
