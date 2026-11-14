# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DInstanceSlot
extends Resource
## Stable local role. Mesh assets use MultiMesh; scenes retain their complete node hierarchy.

enum Kind { MESH, SCENE }
@export var key: StringName
@export var category: StringName = &"vegetation"
@export var kind: Kind = Kind.MESH
@export var enabled := true
@export var default_mesh: Terrain3DMeshAsset
@export var preview_mesh: Terrain3DMeshAsset
@export var default_scene: PackedScene
@export var preview_scene: PackedScene

func fingerprint() -> int:
	return hash([key, category, kind, enabled, default_mesh, preview_mesh, default_scene, preview_scene])
