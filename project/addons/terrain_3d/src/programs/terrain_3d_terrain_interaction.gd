# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DTerrainInteraction
extends Resource
## Explicit model-to-terrain authority. Furniture is outside the contact footprint calculation.

enum Mode { DISABLED, TERRAIN_FOLLOWS_MODEL, PLACE_THEN_TERRAFORM }
@export var mode: Mode = Mode.TERRAIN_FOLLOWS_MODEL
@export var footprint := PackedVector2Array([Vector2(-2, -2), Vector2(2, -2), Vector2(2, 2), Vector2(-2, 2)])
@export var anchor := Vector3.ZERO
@export var anchor_marker: NodePath
@export_range(0, 100, 0.1) var margin := 0.5
@export_range(0, 100, 0.1) var falloff := 2.0
@export var height_offset := 0.0
@export_range(0, 10000, 0.1) var maximum_cut := 100.0
@export_range(0, 10000, 0.1) var maximum_fill := 100.0
@export_range(0, 100, 0.1) var clearance := 1.0
@export var excluded_categories: Array[StringName] = [&"vegetation"]
@export var decal_albedo: Texture2D
@export var decal_normal: Texture2D
@export var decal_orm: Texture2D
@export var decal_emission: Texture2D
@export var decal_modulate := Color.WHITE
@export_range(0.01, 100, 0.1) var decal_depth := 4.0

func fingerprint() -> int:
	return hash([mode, footprint, anchor, anchor_marker, margin, falloff, height_offset, maximum_cut, maximum_fill, clearance, excluded_categories, decal_albedo, decal_normal, decal_orm, decal_emission, decal_modulate, decal_depth])
