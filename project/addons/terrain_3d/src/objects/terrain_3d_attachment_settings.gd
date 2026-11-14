# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DAttachmentSettings
extends Resource
## Shared placement policy for scene objects and painted instances.

enum Mode { KEEP_OFFSET, SNAP, ALIGN_NORMAL, FOOTPRINT_MAX, FOOTPRINT_MIN, FOOTPRINT_AVERAGE, FOOTPRINT_PLANE, NONE }
@export var mode: Mode = Mode.KEEP_OFFSET
## Anchor and support points are in the object's own coordinates.
@export var anchor := Vector3.ZERO
@export var anchor_marker: NodePath
@export var support_points := PackedVector3Array()
@export_range(0, 90, 0.1) var max_tilt_degrees := 30.0
@export var height_offset := 0.0
## Positions follow the Stamp scale; asset geometry keeps its authored local size by default.
@export var inherit_parent_scale := false
@export var require_all_supports := true
@export var hide_without_surface := false

func clone_policy() -> Terrain3DAttachmentSettings:
	return duplicate(true) as Terrain3DAttachmentSettings

func fingerprint() -> int:
	return hash([mode, anchor, anchor_marker, support_points, max_tilt_degrees, height_offset, inherit_parent_scale, require_all_supports, hide_without_surface])
