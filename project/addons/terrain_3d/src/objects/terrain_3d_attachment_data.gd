# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DAttachmentData
extends Resource
## Persistent authoring transforms and terrain-relative offsets, indexed by stable target IDs.

@export_storage var records: Dictionary = {}
var _owner_id := 0

func _init() -> void:
	resource_local_to_scene = true

func clone_source() -> Terrain3DAttachmentData:
	var copy := Terrain3DAttachmentData.new()
	copy.records = records.duplicate(true)
	return copy
