# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DLayerSlot
extends Resource
## A stable material role. Array position is the local paint ID; never reorder painted slots.
@export var programs: Array[Terrain3DProgramSlot] = []
@export var inherit_asset_programs := true

## Stable material role, for example surface.ground or ruins.special_stone.
@export var key: StringName = &"surface.ground":
	set(value):
		key = value
		emit_changed()
## Used when neither the instance nor its terrain supplies a binding for this role.
@export var default_resource: Terrain3DTextureAsset:
	set(value):
		default_resource = value
		emit_changed()
## Standalone editor preview only. Never an implicit material for attached/exported terrain.
@export var preview_resource: Terrain3DTextureAsset:
	set(value):
		preview_resource = value
		emit_changed()
