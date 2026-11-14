# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DProgramSlot
extends Resource
## Language-neutral program configuration. Execution state is owned by each host binding.

enum Stage { HEIGHT, SURFACE, CONTENT }
enum UpdateMode { AUTOMATIC, MANUAL }
enum Placement { BEFORE_AUTHORING, AFTER_AUTHORING }
@export var key: StringName = &"program"
@export var enabled := true
## A GDScript or C# class extending RefCounted/Resource, implementing generate/Generate.
@export_file("*.gd", "*.cs") var program: String
@export var stage: Stage = Stage.HEIGHT
@export var update_mode: UpdateMode = UpdateMode.AUTOMATIC
@export var placement: Placement = Placement.BEFORE_AUTHORING
@export var seed := 5419
## Source coordinates, in meters. Stamp placement is applied by the host.
@export var bounds := Rect2(-16, -16, 32, 32)
## Zero uses the owner's source spacing, or the terrain's vertex spacing.
@export_range(0, 100, 0.25, "or_greater") var sample_spacing := 0.0
@export var parameters: Dictionary = {}
## Declare external assets here so they are visible to export dependency discovery.
@export var resources: Dictionary[StringName, Resource] = {}
## Paths relative to the owning Layer, or Terrain3D for a terrain/base-material program.
@export var references: Array[NodePath] = []
@export var material_slots: Array[Terrain3DLayerSlot] = []
@export var instance_slots: Array[Terrain3DInstanceSlot] = []
@export var height_mode: Terrain3DLayer.HeightMode = Terrain3DLayer.HeightMode.ADD
@export_storage var uid: String = Crypto.new().generate_random_bytes(12).hex_encode()
@export_tool_button("Regenerate") var regenerate_action: Callable = regenerate
var _hosts := {}

func fingerprint() -> int:
	var code := FileAccess.get_file_as_string(program).hash() if not program.is_empty() and FileAccess.file_exists(program) else 0
	var value := hash([key, enabled, program, code, stage, update_mode, placement, seed, bounds, sample_spacing, parameters, resources, references, material_slots, instance_slots, height_mode])
	for slot in material_slots:
		if slot:
			value = hash([value, slot.key, slot.default_resource, slot.preview_resource])
	for slot in instance_slots:
		value = hash([value, slot.fingerprint() if slot else 0])
	return value

func register_host(host: Terrain3D) -> void:
	_hosts[host.get_instance_id()] = weakref(host)

func regenerate() -> void:
	for id in _hosts.keys():
		var host: Terrain3D = _hosts[id].get_ref()
		if is_instance_valid(host):
			host.regenerate_programs()
		else:
			_hosts.erase(id)
