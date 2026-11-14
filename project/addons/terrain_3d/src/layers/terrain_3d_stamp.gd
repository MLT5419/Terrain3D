# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DStamp
extends Terrain3DLayer
## A reusable local heightfield. Rotation is around Y; vertical motion offsets its height.

@export var height_scale := 1.0:
	set(value):
		height_scale = value
		_changed()
## Source elevation removed before scaling; independent from the horizontal pivot.
@export var reference_height := 0.0:
	set(value):
		reference_height = value
		_changed()
@export var heightmap: Texture2D
@export_tool_button("Import Heightmap") var import_action: Callable = import_heightmap
@export var capture_bounds := Rect2(0, 0, 32, 32)
@export_tool_button("Capture Terrain Region") var capture_action: Callable = capture_terrain_region

func capture_terrain_region() -> void:
	var host := get_terrain()
	if not host or not capture_bounds.has_area():
		return
	var step := host.vertex_spacing
	var first := Vector2i((capture_bounds.position / step).floor())
	var last := Vector2i((capture_bounds.end / step).ceil())
	var captured := Terrain3DLayerData.new()
	captured.spacing = step
	var palette: Array[Terrain3DLayerSlot] = []
	var ids := {}
	var assets := host.get_assets()
	captured.begin_edit()
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			var world := Vector3(x * step, 0, y * step)
			var height := host.data.get_height(world)
			var region := host.data.get_regionp(world)
			if not region or not is_finite(height):
				continue
			var source_pixel := host.data.world_to_pixelv(world)
			var bits := region.control_map.get_data().decode_u32((source_pixel.y * host.region_size + source_pixel.x) * 4)
			var pair := [(bits >> 27) & 31, (bits >> 22) & 31]
			for id: int in pair:
				if not ids.has(id):
					var slot := Terrain3DLayerSlot.new()
					slot.key = StringName("capture.material_%s" % id)
					slot.default_resource = assets.get_texture_asset(id)
					ids[id] = palette.size()
					palette.append(slot)
			var pixel := Vector2i(x, y) - first
			captured.set_pixel(pixel, 0, Color(height, 0, 0, 1), 1, false)
			captured.set_control(pixel, (bits & 0x003fffff) | (int(ids[pair[0]]) << 27) | (int(ids[pair[1]]) << 22))
			captured.set_pixel(pixel, 2, host.data.get_color(world), 1, false)
	captured.end_edit()
	var centered := captured.get_bounds().get_center()
	commit_configuration("Capture Terrain Stamp", {"data": data, "slots": slots.duplicate(), "pivot": pivot, "global_transform": global_transform},
		{"data": captured, "slots": palette, "pivot": centered, "global_transform": Transform3D(Basis.IDENTITY, Vector3(first.x * step + centered.x, 0, first.y * step + centered.y))})

func import_heightmap() -> void:
	if not heightmap:
		return
	var image := heightmap.get_image()
	if image.is_compressed() and image.decompress() != OK:
		push_error("The heightmap cannot be decoded.")
		return
	var imported := Terrain3DLayerData.new()
	imported.spacing = data.spacing if data else preview_vertex_spacing
	imported.import_heightmap(image)
	commit_configuration("Import Terrain Stamp", {"data": data, "pivot": pivot}, {"data": imported, "pivot": imported.get_bounds().get_center()})

func height_value(source: float) -> float:
	return (source - reference_height) * height_scale * global_transform.basis.y.y + global_position.y

func source_height(value: float) -> float:
	return (value - global_position.y) / (height_scale * global_transform.basis.y.y) + reference_height
