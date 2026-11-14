# Copyright © 2026 Terrain3D Contributors.
@tool
class_name Terrain3DLayerStack
extends Node
## Internal compositor. Original regions and source asset IDs are never overwritten by a bake.

const TILE := 32
var host: Terrain3D
var has_layers := false
var composing := false
var errors := PackedStringArray()
var layers: Array[Terrain3DLayer] = []
var _base: Dictionary = {}
var _base_ready := false
var _pending := false
var _full := true
var _dirty_areas: Array[Rect2] = []
var _previous_bounds: Dictionary = {}
var _remaps: Dictionary = {}
var _palette_signature := 0
var _poll := 0.0
var _binding_hash := 0
var _fallback := Terrain3DTextureAsset.new()
var exporting := false
var _save_frame := -1
var scatter := Terrain3DScatterCompositor.new()
var program_scheduler := Terrain3DProgramScheduler.new()
var revision := 0
var _program_hash := 0

func _ready() -> void:
	host = get_parent() as Terrain3D
	program_scheduler.initialize(self)
	invalidate()

func _process(delta: float) -> void:
	_poll += delta
	if _poll < 0.2:
		return
	_poll = 0.0
	var saved_layers := layers
	layers = []
	var preview: int = host.get_meta("_terrain3d_preview_owner", 0)
	_collect(instance_from_id(preview) if preview and is_instance_id_valid(preview) else host)
	program_scheduler.collect(layers)
	layers = saved_layers
	var program_hash := program_scheduler.poll_fingerprint()
	if program_hash != _program_hash:
		_program_hash = program_hash
		invalidate()
	var state := hash([host.vertex_spacing, host.layer_bindings.fingerprint() if host.layer_bindings is Terrain3DLayerBindings else 0, host.get_source_assets().texture_list, host.get_source_assets().mesh_list])
	if state != _binding_hash:
		_binding_hash = state
		invalidate()

func invalidate() -> void:
	revision += 1
	_full = true
	_queue()

func invalidate_area(area: Rect2) -> void:
	revision += 1
	_dirty_areas.append(area)
	_queue()

func invalidate_layer(layer: Terrain3DLayer) -> void:
	revision += 1
	_invalidate_branch(layer)
	_queue()

func _invalidate_branch(node: Node) -> void:
	if node is Terrain3D:
		return
	if node is Terrain3DLayer:
		_invalidate_one(node)
	for child in node.get_children():
		_invalidate_branch(child)

func _invalidate_one(layer: Terrain3DLayer) -> void:
	var id := layer.get_instance_id()
	if _previous_bounds.has(id):
		_dirty_areas.append(_previous_bounds[id])
	if layer.participates() and layer.data and not layer.data.chunks.is_empty():
		var area := layer.source_bounds().grow(layer.data.spacing)
		_previous_bounds[id] = area
		_dirty_areas.append(area)
	else:
		_previous_bounds.erase(id)

func remember_layer_bounds(layer: Terrain3DLayer) -> void:
	if layer.participates() and layer.data and not layer.data.chunks.is_empty():
		_previous_bounds[layer.get_instance_id()] = layer.source_bounds().grow(layer.data.spacing)

func _queue() -> void:
	if not _pending and is_inside_tree():
		_pending = true
		call_deferred("recompose")

func regenerate_programs() -> void:
	program_scheduler.request_regenerate()

func _exit_tree() -> void:
	program_scheduler.shutdown()

func reset_base() -> void:
	_base.clear()
	_base_ready = false
	has_layers = false
	_palette_signature = -1
	_previous_bounds.clear()
	invalidate()

func _collect(node: Node) -> void:
	if not is_instance_valid(node):
		return
	if node is Terrain3D and node != host:
		return
	if node is Terrain3DLayer and node.is_inside_tree():
		layers.append(node)
	for child in node.get_children():
		_collect(child)

func _copy_region(region: Terrain3DRegion) -> Terrain3DRegion:
	var copy := region.duplicate(true) as Terrain3DRegion
	copy.location = region.location
	return copy

func _capture_base() -> void:
	_base.clear()
	for region: Terrain3DRegion in host.data.get_regions_all().values():
		if region.is_deleted() and (host.data_directory.is_empty() or not FileAccess.file_exists(host.data_directory.path_join(Terrain3DUtil.location_to_filename(region.location)))):
			continue
		_base[region.location] = _copy_region(region)
	scatter.capture_base(self)
	_base_ready = true

func _resource_changed(_id: Variant = null) -> void:
	_palette_signature = -1
	invalidate()

func _watch(resource: Resource) -> void:
	if not resource:
		return
	for signal_name in [&"changed", &"setting_changed", &"file_changed", &"instancer_setting_changed"]:
		if resource.has_signal(signal_name) and not resource.is_connected(signal_name, _resource_changed):
			resource.connect(signal_name, _resource_changed)

func _resolve_palette() -> bool:
	if host.layer_bindings and not host.layer_bindings is Terrain3DLayerBindings:
		errors.append("Layer Bindings must be a Terrain3DLayerBindings resource.")
		return false
	var source := host.get_source_assets()
	var resources: Array[Terrain3DTextureAsset] = []
	var meshes: Array[Terrain3DMeshAsset] = []
	meshes.assign(source.mesh_list)
	if not scatter.resolve_palette(self, meshes):
		return false
	var identities := {}
	var signature_values: Array = [source.texture_compression, source.texture_resolution]
	for asset in source.texture_list:
		if not asset:
			errors.append("Base terrain has an empty material entry.")
			return false
		identities[asset.get_instance_id()] = resources.size()
		resources.append(asset)
		_watch(asset)
	if resources.is_empty() and not _base.is_empty():
		identities[_fallback.get_instance_id()] = 0
		resources.append(_fallback)
	_remaps.clear()
	for layer in layers:
		if not layer.participates() or not layer.data:
			continue
		if layer.data.version != Terrain3DLayerData.FORMAT_VERSION:
			errors.append("%s: unsupported layer data version." % layer.name)
			return false
		var map := {}
		var keys := {}
		for slot in layer.slots:
			if not slot or slot.key.is_empty() or keys.has(slot.key):
				errors.append("%s: material slot keys must be nonempty and unique." % layer.name)
				return false
			keys[slot.key] = true
		for local_id: int in layer.data.get_used_slots() if layer.paint_enabled else []:
			var asset := layer.resolve_slot(local_id, host.has_meta("_terrain3d_preview_owner") and not exporting)
			if not asset:
				errors.append("%s: no material bound to local slot %s." % [layer.name, local_id])
				return false
			var identity := asset.get_instance_id()
			if not identities.has(identity):
				identities[identity] = resources.size()
				resources.append(asset)
			_watch(asset)
			map[local_id] = identities[identity]
		_remaps[layer.get_instance_id()] = map
	if resources.size() > Terrain3DAssets.MAX_TEXTURES:
		errors.append("The composed terrain needs %s materials; the current GPU layout supports 32. Reuse resources or change bindings." % resources.size())
		return false
	# An untextured heightfield still needs a valid checkerboard layer.
	if resources.is_empty():
		resources.append(_fallback)
	for asset in resources:
		signature_values.append(asset.get_instance_id())
	signature_values.append("meshes")
	for asset in meshes:
		signature_values.append(asset.get_instance_id())
	var signature := hash(signature_values)
	if signature != _palette_signature:
		var compiled := Terrain3DAssets.new()
		compiled.texture_compression = source.texture_compression
		compiled.texture_resolution = source.texture_resolution
		var compiled_meshes: Array[Terrain3DMeshAsset] = []
		for index in meshes.size():
			var copy := meshes[index].duplicate() as Terrain3DMeshAsset
			copy.id = index
			compiled_meshes.append(copy)
		compiled.mesh_list = compiled_meshes
		var textures: Array[Terrain3DTextureAsset] = []
		for index in resources.size():
			var copy := resources[index].duplicate() as Terrain3DTextureAsset
			copy.id = index
			textures.append(copy)
		compiled.texture_list = textures
		var size := compiled.get_texture_array_size()
		for index in resources.size():
			if Engine.is_editor_hint():
				if resources[index].prepare_texture_cache(size) != OK:
					errors.append("Could not prepare material: " + resources[index].name)
					return false
				resources[index].get_encoded_cache(Terrain3DTextureCache.select_for_device(source.texture_compression))
			textures[index] = resources[index].duplicate()
			textures[index].id = index
			if not Engine.is_editor_hint():
				var cache := textures[index].get_texture_cache()
				if not cache or not cache.is_valid():
					errors.append("Save the layer scene in the editor before running, or export its baked result.")
					return false
				if not cache.is_valid(size):
					cache = cache.encode(Terrain3DTextureCache.RGBA8)
					if not cache:
						return false
					var resized := Terrain3DTextureCache.new()
					resized.signature = cache.signature
					resized.emission_scale = cache.emission_scale
					var images: Array[Image] = []
					for image in cache.images:
						var copy := image.duplicate() as Image
						copy.clear_mipmaps()
						copy.resize(size, size)
						copy.generate_mipmaps()
						images.append(copy)
					resized.images = images
					textures[index].set_texture_cache(resized)
					textures[index].set_prepared_cache(null)
					compiled.texture_compression = Terrain3DTextureCache.RGBA8
		compiled.texture_list = textures
		for layer in layers:
			layer._edit_assets = null
		host.set_effective_assets(compiled)
		_palette_signature = signature
		_full = true
	return true

func _tiles_for(area: Rect2, tiles: Dictionary) -> void:
	if not area.has_area():
		return
	var step := host.vertex_spacing * TILE
	var first := Vector2i((area.position / step).floor())
	var last := Vector2i((area.end / step).floor())
	var limit := host.region_size * 16 / TILE
	for y in range(maxi(first.y, -limit), mini(last.y, limit - 1) + 1):
		for x in range(maxi(first.x, -limit), mini(last.x, limit - 1) + 1):
			tiles[Vector2i(x, y)] = true

func prepare_save() -> void:
	var frame := Engine.get_process_frames()
	if _save_frame != frame:
		_save_frame = frame
		recompose(true)

func recompose(force: bool = false) -> Error:
	_pending = false
	if composing or not is_inside_tree() or not is_instance_valid(host) or not host.data:
		return ERR_BUSY
	_full = _full or force
	var previous_layers := layers.duplicate()
	var previous_active := has_layers
	layers = []
	var preview_owner: int = host.get_meta("_terrain3d_preview_owner", 0)
	if preview_owner and not is_instance_id_valid(preview_owner):
		return ERR_UNCONFIGURED
	_collect(instance_from_id(preview_owner) if preview_owner else host)
	errors.clear()
	if not _base_ready:
		_capture_base()
	if not program_scheduler.build(layers, _dirty_areas, _full):
		errors.append_array(program_scheduler.errors)
		program_scheduler.reject()
		layers = previous_layers
		has_layers = previous_active
		host.update_configuration_warnings()
		return ERR_INVALID_DATA
	layers = program_scheduler.candidate_sources()
	has_layers = not layers.is_empty() or program_scheduler.active
	if not _resolve_palette():
		program_scheduler.reject()
		layers = previous_layers
		has_layers = previous_active
		host.update_configuration_warnings()
		return ERR_INVALID_DATA
	var tiles := {}
	if _full:
		for location: Vector2i in host.data.get_region_locations():
			_tiles_for(Rect2(Vector2(location * host.region_size) * host.vertex_spacing, Vector2.ONE * host.region_size * host.vertex_spacing), tiles)
		for location: Vector2i in _base:
			_tiles_for(Rect2(Vector2(location * host.region_size) * host.vertex_spacing, Vector2.ONE * host.region_size * host.vertex_spacing), tiles)
		for area: Rect2 in _previous_bounds.values():
			_tiles_for(area, tiles)
		_previous_bounds.clear()
		for layer in layers:
			if layer.participates() and layer.data and not layer.data.chunks.is_empty():
				var area := layer.source_bounds().grow(layer.data.spacing)
				_previous_bounds[layer.get_instance_id()] = area
				_tiles_for(area, tiles)
	else:
		for area in _dirty_areas:
			_tiles_for(area, tiles)
	_dirty_areas.clear()
	_full = false
	composing = true
	has_layers = not layers.is_empty() or program_scheduler.active
	var original_locations := host.data.get_region_locations().duplicate()
	var outputs := {}
	for tile: Vector2i in tiles:
		var location := Vector2i(floori(float(tile.x * TILE) / host.region_size), floori(float(tile.y * TILE) / host.region_size))
		if not outputs.has(location):
			var existing := host.data.get_region(location)
			var maps: Array[Image] = []
			for channel in 3:
				var image := existing.get_map(channel).duplicate() as Image if existing else Image.create(host.region_size, host.region_size, false, Image.FORMAT_RGBA8 if channel == 2 else Image.FORMAT_RF)
				image.clear_mipmaps()
				maps.append(image)
			outputs[location] = maps
		_compose_tile(tile, location, outputs[location])
	# Regions introduced exclusively by removed/disabled layers disappear entirely.
	for location: Vector2i in outputs:
		var keep: bool = _base.has(location) and not _base[location].is_deleted()
		var region_bounds := Rect2(Vector2(location * host.region_size) * host.vertex_spacing, Vector2.ONE * host.region_size * host.vertex_spacing)
		for layer in layers:
			keep = keep or (layer.participates() and layer.data and not layer.data.chunks.is_empty() and region_bounds.intersects(layer.source_bounds().grow(layer.data.spacing), true))
		if keep:
			host.data._apply_layer_region(location, outputs[location])
		elif host.data.has_region(location):
			host.data.remove_regionl(location, false)
	host.data.calc_height_range(true)
	host.data.update_maps(Terrain3DRegion.TYPE_MAX, original_locations != host.data.get_region_locations(), true)
	for region: Terrain3DRegion in host.data.get_regions_active():
		region.set_edited(false)
	if host.get_collision():
		host.get_collision().update(Vector2i(2147483647, 2147483647), true)
	host.snap()
	program_scheduler.accept()
	scatter.compose(self)
	composing = false
	Terrain3DAttachmentGroup.solve_for_host(host)
	program_scheduler.notify_applied()
	if not has_layers:
		host.set_effective_assets(null)
		_base_ready = false
	host.update_configuration_warnings()
	return OK

func _compose_tile(tile: Vector2i, location: Vector2i, maps: Array[Image]) -> void:
	var region_size := host.region_size
	var first := tile * TILE
	var local := first - location * region_size
	var base: Terrain3DRegion = _base.get(location)
	if base and base.is_deleted():
		base = null
	var height_bytes := maps[0].get_data()
	var control_bytes := maps[1].get_data()
	var base_control := base.control_map.get_data() if base else PackedByteArray()
	var active: Array[Terrain3DLayer] = []
	var active_bounds: Array[Rect2] = []
	var tile_rect := Rect2(Vector2(first) * host.vertex_spacing, Vector2.ONE * TILE * host.vertex_spacing)
	for layer in layers:
		var bounds := layer.source_bounds().grow(layer.data.spacing) if layer.participates() and layer.data else Rect2()
		if layer.participates() and layer.data and bounds.intersects(tile_rect, true):
			active.append(layer)
			active_bounds.append(bounds)
	for y in TILE:
		for x in TILE:
			var pixel := local + Vector2i(x, y)
			var offset := (pixel.y * region_size + pixel.x) * 4
			var world := Vector2(first + Vector2i(x, y)) * host.vertex_spacing
			var h := base.height_map.get_pixelv(pixel).r if base else 0.0
			var control := base_control.decode_u32(offset) if base else 4
			var color := base.color_map.get_pixelv(pixel) if base else Color(1, 1, 1, 0.5)
			for index in active.size():
				if not active_bounds[index].has_point(world):
					continue
				var layer := active[index]
				var source := layer.source_position(world)
				if not source.is_finite():
					continue
				var coverage := layer.data.sample_coverage(source, 0) * layer.height_opacity
				if coverage > 0:
					var value := layer.height_value(layer.data.sample(source, 0).r)
					h = h + value * coverage if layer.height_mode == Terrain3DLayer.HeightMode.ADD else lerpf(h, value, coverage)
					if not base:
						control &= ~4
				if not layer.paint_enabled:
					continue
				# Material coverage is categorical; erasing exposes the previous layer.
				if layer.data.sample_coverage(source, 1) >= 0.5:
					var bits := layer.data.get_control(Vector2i((source / layer.data.spacing).round()))
					var remap: Dictionary = _remaps[layer.get_instance_id()]
					control = (bits & 0x003fffff) | (int(remap[(bits >> 27) & 31]) << 27) | (int(remap[(bits >> 22) & 31]) << 22)
				var color_coverage := layer.data.sample_coverage(source, 2)
				if color_coverage > 0:
					color = color.lerp(layer.data.sample(source, 2), color_coverage)
			height_bytes.encode_float(offset, h)
			control_bytes.encode_u32(offset, control)
			maps[2].set_pixelv(pixel, color)
	maps[0].set_data(region_size, region_size, false, Image.FORMAT_RF, height_bytes)
	maps[1].set_data(region_size, region_size, false, Image.FORMAT_RF, control_bytes)

func save_base_directory(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path)
	for location: Vector2i in _base:
		save_base_region(location, path, host.save_16_bit, host.color_compress_mode)

func save_base_region(location: Vector2i, path: String, half_precision: bool, compression: int) -> void:
	var region: Terrain3DRegion = _base.get(location)
	if not region:
		return
	if region.is_deleted():
		var deleted_path := path.path_join(Terrain3DUtil.location_to_filename(location))
		if FileAccess.file_exists(deleted_path):
			DirAccess.remove_absolute(deleted_path)
		return
	region.set_modified(true)
	var error := region.save(path.path_join(Terrain3DUtil.location_to_filename(location)), half_precision, compression)
	if error != OK and error != ERR_SKIP:
		push_error("Terrain3D: Could not save the original base region: " + str(error))

func height_before(target: Terrain3DLayer, world: Vector2) -> float:
	var grid := Vector2i((world / host.vertex_spacing).floor())
	var location := Vector2i(floori(float(grid.x) / host.region_size), floori(float(grid.y) / host.region_size))
	var base: Terrain3DRegion = _base.get(location)
	var pixel := Vector2i(posmod(grid.x, host.region_size), posmod(grid.y, host.region_size))
	var height := base.height_map.get_pixelv(pixel).r if base and not base.is_deleted() else 0.0
	for layer in layers:
		if layer == target:
			break
		if layer.participates() and layer.data:
			var source := layer.source_position(world)
			if source.is_finite():
				var w := layer.data.sample_coverage(source, 0) * layer.height_opacity
				var value := layer.height_value(layer.data.sample(source, 0).r)
				height = height + value * w if layer.height_mode == Terrain3DLayer.HeightMode.ADD else lerpf(height, value, w)
	return height

func height_through(target: Terrain3DLayer, world: Vector2, source_data: Terrain3DLayerData) -> float:
	var height := height_before(target, world)
	var source := target.source_position(world)
	var w := source_data.sample_coverage(source, 0) * target.height_opacity
	var value := target.height_value(source_data.sample(source, 0).r)
	return height + value * w if target.height_mode == Terrain3DLayer.HeightMode.ADD else lerpf(height, value, w)
