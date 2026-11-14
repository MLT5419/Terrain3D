# Copyright © 2026 Terrain3D Contributors.
@tool
extends EditorInspectorPlugin

func _can_handle(object: Object) -> bool:
	return object is Terrain3D or object is Terrain3DLayer or object is Terrain3DTextureAsset or object is Terrain3DLayerSlot or object is Terrain3DAttachmentGroup

func _parse_begin(object: Object) -> void:
	var button := Button.new()
	button.text = "Regenerate Terrain Programs"
	button.tooltip_text = "Rebuild program-owned outputs, including programs configured for manual updates."
	button.pressed.connect(func():
		if not is_instance_valid(object):
			return
		if object is Terrain3D or object is Terrain3DLayer:
			object.regenerate_programs()
		elif object is Terrain3DAttachmentGroup:
			var host: Terrain3D = object.terrain if object.terrain else Terrain3DPlacementSolver.resolve_host(object)
			if host:
				host.regenerate_programs()
		else:
			for slot: Resource in object.programs:
				if slot is Terrain3DProgramSlot:
					slot.regenerate()
	)
	add_custom_control(button)
