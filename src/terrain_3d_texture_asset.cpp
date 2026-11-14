// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/resource_loader.hpp>

#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_material_baker.h"
#include "terrain_3d_texture_asset.h"

///////////////////////////
// Private Functions
///////////////////////////

// Note a null texture is considered a valid format
bool Terrain3DTextureAsset::_is_valid_format(const Ref<Texture2D> &p_texture) const {
	if (p_texture.is_null()) {
		LOG(DEBUG, "Provided texture is null.");
		return true;
	}
	Ref<Image> img = p_texture->get_image();
	Image::Format format = Image::FORMAT_MAX;
	if (img.is_valid()) {
		format = img->get_format();
	}
	if (format < 0 || format >= Image::FORMAT_MAX) {
		LOG(ERROR, "Invalid texture format. See documentation for format specification.");
		return false;
	}
	return true;
}

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DTextureAsset::initialize() {
	LOG(INFO, _id, ": ", _name, ": initializing asset");
	_connect_material_textures();
}

void Terrain3DTextureAsset::clear() {
	LOG(INFO, "Clearing TextureAsset");
	_disconnect_material();
	_source_mode = SOURCE_TEXTURES;
	_material.unref();
	_premultiply_ao = false;
	_material_texture_size = 1024;
	_texture_cache.unref();
	_prepared_cache.unref();
	_cache_storage = CACHE_EMBEDDED;
	_cache_directory = "res://terrain3d_cache";
	_material_cache.clear();
	_material_cache_signature = String();
	_material_emission_scale = 1.f;
	_material_settings.clear();
	_runtime_material_cache = false;
	_name = "New Texture";
	_id = 0;
	_highlighted = false;
	_highlight_color = Color();
	_albedo_color = Color(1.0f, 1.0f, 1.0f, 1.0f);
	_albedo_texture.unref();
	_normal_texture.unref();
	_thumbnail.unref();

	_normal_depth = 1.0f;
	_ao_strength = 0.5f;
	_ao_light_affect = 0.0f;
	_roughness = 0.f;
	_displacement_scale = 0.f;
	_displacement_offset = 0.f;
	_uv_scale = 0.1f;
	_detiling_rotation = 0.0f;
	_detiling_shift = 0.0f;
}

void Terrain3DTextureAsset::_disconnect_material() {
	Callable callback = callable_mp(this, &Terrain3DTextureAsset::_material_changed);
	if (_material.is_valid() && _material->is_connected("changed", callback)) {
		_material->disconnect("changed", callback);
	}
	for (const Ref<Texture2D> &texture : _material_textures) {
		if (texture.is_valid() && texture->is_connected("changed", callback)) {
			texture->disconnect("changed", callback);
		}
	}
	_material_textures.clear();
}

void Terrain3DTextureAsset::_connect_material_textures() {
	_disconnect_material();
	if (_material.is_null()) {
		return;
	}
	Callable callback = callable_mp(this, &Terrain3DTextureAsset::_material_changed);
	_material->connect("changed", callback);
	for (int i = 0; i < BaseMaterial3D::TEXTURE_MAX; i++) {
		Ref<Texture2D> texture = _material->get_texture(BaseMaterial3D::TextureParam(i));
		if (texture.is_valid() && !_material_textures.has(texture)) {
			_material_textures.push_back(texture);
			texture->connect("changed", callback);
		}
	}
}

void Terrain3DTextureAsset::_material_changed() {
	_connect_material_textures();
	if (_material.is_valid()) {
		_material_settings = get_material_settings();
		_material_source_state = Terrain3DMaterialBaker::source_state(_material);
	}
	notify_property_list_changed();
	if (_source_mode == SOURCE_MATERIAL) {
		bool pixels_changed = _texture_cache.is_null() || _material.is_null();
		if (!pixels_changed && IS_EDITOR) {
			TypedArray<Image> images = _texture_cache->get_images();
			Ref<Image> image = images.is_empty() ? Ref<Image>() : Ref<Image>(images[0]);
			pixels_changed = image.is_null() || Terrain3DMaterialBaker::signature(_material, image->get_width(), _premultiply_ao) != _texture_cache->get_signature();
		}
		if (pixels_changed) {
			emit_signal("file_changed");
		}
		emit_signal("setting_changed");
		emit_changed();
	}
}

Dictionary Terrain3DTextureAsset::get_material_settings() const {
	if (_material.is_null()) {
		return _material_settings;
	}
	Dictionary settings;
	settings["color"] = _material->get_albedo().srgb_to_linear();
	settings["normal_depth"] = _material->get_normal_scale();
	settings["ao_affect"] = _material->get_ao_light_affect();
	settings["specular"] = _material->get_specular();
	settings["uv_scale"] = _material->get_uv1_scale();
	settings["uv_offset"] = _material->get_uv1_offset();
	return settings;
}

void Terrain3DTextureAsset::_poll_material_changes() {
	if (_source_mode != SOURCE_MATERIAL || _material.is_null()) {
		return;
	}
	// BaseMaterial3D does not emit changed for every uniform/property setter.
	// Poll cheap values/texture identities, never image pixels, while authoring.
	if (Terrain3DMaterialBaker::source_state(_material) != _material_source_state) {
		_material_changed();
	} else {
		Dictionary settings = get_material_settings();
		if (settings.hash() != _material_settings.hash()) {
			_material_settings = settings;
			emit_signal("setting_changed");
			emit_changed();
		}
	}
}

void Terrain3DTextureAsset::set_source_mode(SourceMode p_mode) {
	ERR_FAIL_COND(p_mode != SOURCE_TEXTURES && p_mode != SOURCE_MATERIAL);
	SET_IF_DIFF(_source_mode, p_mode);
	_thumbnail.unref();
	if (_source_mode == SOURCE_TEXTURES && _albedo_texture.is_valid()) {
		_thumbnail = _albedo_texture;
	}
	notify_property_list_changed();
	emit_signal("file_changed");
	emit_signal("setting_changed");
	emit_changed();
}

void Terrain3DTextureAsset::set_material(const Ref<BaseMaterial3D> &p_material) {
	if (_material == p_material) {
		return;
	}
	_disconnect_material();
	_material = p_material;
	if (_material.is_valid() && _name == "New Texture") {
		String name = _material->get_name();
		if (name.is_empty()) {
			name = _material->get_path().get_file().get_basename();
		}
		if (!name.is_empty()) {
			_name = name.left(96);
		}
	}
	// Export customization may copy properties in any order. Clearing a source reference
	// must not erase a cache that was already copied into the exported resource.
	if (_material.is_valid()) {
		_runtime_material_cache = false;
		_material_cache_signature = String();
		_material_cache.clear();
		_texture_cache.unref();
		_prepared_cache.unref();
	}
	_material_changed();
}

void Terrain3DTextureAsset::set_premultiply_ao(bool p_enabled) {
	SET_IF_DIFF(_premultiply_ao, p_enabled);
	_material_changed();
}

void Terrain3DTextureAsset::set_material_texture_size(int p_size) {
	ERR_FAIL_COND(p_size < 16 || p_size > 4096 || !Math::is_power_of_2(p_size));
	SET_IF_DIFF(_material_texture_size, p_size);
	_material_cache_signature = String();
	emit_signal("file_changed");
	emit_signal("setting_changed");
	emit_changed();
}

String Terrain3DTextureAsset::get_material_warnings() const {
	return Terrain3DMaterialBaker::warnings(_material);
}

Error Terrain3DTextureAsset::bake_material(int p_size) {
	return prepare_texture_cache(p_size);
}

Error Terrain3DTextureAsset::_persist_cache(Ref<Terrain3DTextureCache> &p_cache) {
	if (!IS_EDITOR || _runtime_material_cache || p_cache.is_null()) {
		return OK;
	}
	if (_cache_storage == CACHE_EMBEDDED) {
		if (!p_cache->get_path().is_empty()) {
			p_cache = p_cache->duplicate();
		}
		return OK;
	}
	String path = _cache_directory.path_join(p_cache->get_signature() + "_" + Terrain3DTextureCache::compression_name(p_cache->get_compression()) + ".res");
	if (p_cache->get_path() != path || !FileAccess::file_exists(path)) {
		Error error = p_cache->save_external(path);
		ERR_FAIL_COND_V(error != OK, error);
		Ref<Terrain3DTextureCache> saved = ResourceLoader::get_singleton()->load(path, "Terrain3DTextureCache", ResourceLoader::CACHE_MODE_REPLACE);
		ERR_FAIL_COND_V(saved.is_null() || !saved->is_valid() || saved->get_signature() != p_cache->get_signature(), ERR_FILE_CORRUPT);
		p_cache = saved;
	}
	return OK;
}

void Terrain3DTextureAsset::set_cache_storage(CacheStorage p_storage) {
	ERR_FAIL_COND(p_storage != CACHE_EMBEDDED && p_storage != CACHE_EXTERNAL);
	SET_IF_DIFF(_cache_storage, p_storage);
	notify_property_list_changed();
	emit_signal("file_changed");
	emit_changed();
}

void Terrain3DTextureAsset::set_cache_directory(const String &p_directory) {
	String directory = p_directory.simplify_path();
	if (directory != "res://") {
		directory = directory.trim_suffix("/");
	}
	ERR_FAIL_COND_MSG(!directory.begins_with("res://") || directory.contains(".."), "Choose a cache directory inside the Godot project.");
	SET_IF_DIFF(_cache_directory, directory);
	emit_signal("file_changed");
	emit_changed();
}

Error Terrain3DTextureAsset::prepare_texture_cache(int p_size) {
	_material_settings = get_material_settings();
	int size = p_size == 0 ? _material_texture_size : p_size;
	ERR_FAIL_COND_V(size < 16 || size > 4096 || !Math::is_power_of_2(size), ERR_INVALID_PARAMETER);
	bool valid = _texture_cache.is_valid() && _texture_cache->is_valid(size);
	if (!IS_EDITOR || _runtime_material_cache) {
		ERR_FAIL_COND_V_MSG(!valid, ERR_UNCONFIGURED, "Terrain texture cache missing or outdated. Open and save the assets in the editor before exporting.");
		return OK;
	}
	ERR_FAIL_COND_V_MSG(_source_mode == SOURCE_MATERIAL && _material.is_null(), ERR_UNCONFIGURED, "Assign a PBR material before preparing this layer.");
	String signature = _source_mode == SOURCE_MATERIAL ? Terrain3DMaterialBaker::signature(_material, size, _premultiply_ao) : Terrain3DMaterialBaker::texture_signature(_albedo_texture, _normal_texture, size);
	valid = valid && _texture_cache->get_compression() == Terrain3DTextureCache::RGBA8 && _texture_cache->get_signature() == signature;
	if (!valid && _cache_storage == CACHE_EXTERNAL) {
		String path = _cache_directory.path_join(signature + "_rgba8.res");
		if (FileAccess::file_exists(path)) {
			Ref<Terrain3DTextureCache> saved = ResourceLoader::get_singleton()->load(path, "Terrain3DTextureCache");
			if (saved.is_valid() && saved->is_valid(size) && saved->get_compression() == Terrain3DTextureCache::RGBA8 && saved->get_signature() == signature) {
				_texture_cache = saved;
				_thumbnail.unref();
				valid = true;
			}
		}
	}
	if (!valid) {
		TypedArray<Image> images;
		float scale = 1.f;
		Error error = _source_mode == SOURCE_MATERIAL ? Terrain3DMaterialBaker::bake(_material, size, _premultiply_ao, images, scale) : Terrain3DMaterialBaker::bake_textures(_albedo_texture, _normal_texture, size, images);
		ERR_FAIL_COND_V(error != OK, error);
		_texture_cache.instantiate();
		_texture_cache->set_signature(signature);
		_texture_cache->set_images(images);
		_texture_cache->set_emission_scale(scale);
		_prepared_cache.unref();
		emit_changed();
		_thumbnail.unref();
	}
	Error error = _persist_cache(_texture_cache);
	ERR_FAIL_COND_V(error != OK, error);
	// Old embedded BC7 properties are accepted on load, but are never saved again.
	_material_cache.clear();
	_material_cache_signature = String();
	_material_emission_scale = 1.f;
	if (IS_EDITOR && _thumbnail.is_null()) {
		Ref<Image> image = Ref<Image>(_texture_cache->get_images()[0])->duplicate();
		image->clear_mipmaps();
		image->resize(256, 256);
		image->convert(Image::FORMAT_RGB8);
		_thumbnail = ImageTexture::create_from_image(image);
	}
	return OK;
}

Ref<Terrain3DTextureCache> Terrain3DTextureAsset::get_encoded_cache(Terrain3DTextureCache::Compression p_compression) {
	ERR_FAIL_COND_V(_texture_cache.is_null() || !_texture_cache->is_valid(), Ref<Terrain3DTextureCache>());
	if (_texture_cache->get_compression() == p_compression) {
		return _texture_cache;
	}
	bool valid = _prepared_cache.is_valid() && _prepared_cache->is_valid() && _prepared_cache->get_signature() == _texture_cache->get_signature() && _prepared_cache->get_compression() == p_compression;
	if (!valid && IS_EDITOR && _cache_storage == CACHE_EXTERNAL) {
		String path = _cache_directory.path_join(_texture_cache->get_signature() + "_" + Terrain3DTextureCache::compression_name(p_compression) + ".res");
		if (FileAccess::file_exists(path)) {
			Ref<Terrain3DTextureCache> saved = ResourceLoader::get_singleton()->load(path, "Terrain3DTextureCache");
			if (saved.is_valid() && saved->is_valid() && saved->get_signature() == _texture_cache->get_signature() && saved->get_compression() == p_compression) {
				_prepared_cache = saved;
				valid = true;
			}
		}
	}
	if (!valid) {
		_prepared_cache = _texture_cache->encode(p_compression);
		ERR_FAIL_COND_V(_prepared_cache.is_null(), Ref<Terrain3DTextureCache>());
		if (IS_EDITOR) {
			emit_changed();
		}
	}
	Error error = _persist_cache(_prepared_cache);
	ERR_FAIL_COND_V(error != OK, Ref<Terrain3DTextureCache>());
	return _prepared_cache;
}

void Terrain3DTextureAsset::_validate_property(PropertyInfo &p_property) const {
	String name = p_property.name;
	bool legacy = name == "albedo_color" || name == "albedo_texture" || name == "normal_texture" || name == "normal_depth" || name == "ao_strength" || name == "ao_light_affect" || name == "roughness";
	bool material = name == "material" || name == "premultiply_ao" || name == "material_texture_size" || name == "material_warnings";
	if ((legacy && _source_mode != SOURCE_TEXTURES) || (material && _source_mode != SOURCE_MATERIAL) || (name == "material_warnings" && get_material_warnings().is_empty())) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if ((name == "cache_directory" || name == "cache_file") && _cache_storage != CACHE_EXTERNAL) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
}

void Terrain3DTextureAsset::set_asset_name(const String &p_name) {
	if (p_name.length() > 96) {
		LOG(WARN, "Name too long, truncating to 96 characters");
	}
	SET_IF_DIFF(_name, p_name.left(96));
	LOG(INFO, "Setting name: ", _name);
	LOG(DEBUG, "Emitting setting_changed");
	emit_signal("setting_changed");
}

void Terrain3DTextureAsset::set_id(const int p_new_id) {
	int old_id = _id;
	SET_IF_DIFF(_id, CLAMP(p_new_id, 0, Terrain3DAssets::MAX_TEXTURES - 1));
	LOG(INFO, "Setting texture id: ", _id);
	LOG(DEBUG, "Emitting id_changed, TYPE_TEXTURE, ", old_id, ", ", _id);
	emit_signal("id_changed", Terrain3DAssets::TYPE_TEXTURE, old_id, _id);
}

void Terrain3DTextureAsset::set_highlighted(const bool p_highlighted) {
	SET_IF_DIFF(_highlighted, p_highlighted);
	LOG(INFO, "Set texture ID ", _id, " highlight: ", _highlighted);
	real_t random_float = real_t(rand()) / real_t(RAND_MAX);
	_highlight_color.set_hsv(random_float, 1.f, 1.f, 1.f);
	LOG(DEBUG, "Emitting setting_changed");
	emit_signal("setting_changed");
}

void Terrain3DTextureAsset::set_albedo_color(const Color &p_color) {
	SET_IF_DIFF(_albedo_color, p_color);
	LOG(INFO, "Setting color: ", p_color);
	LOG(DEBUG, "Emitting setting_changed");
	emit_signal("setting_changed");
}

void Terrain3DTextureAsset::set_albedo_texture(const Ref<Texture2D> &p_texture) {
	if (_is_valid_format(p_texture)) {
		SET_IF_DIFF(_albedo_texture, p_texture);
		LOG(INFO, "Setting albedo texture: ", p_texture);
		if (p_texture.is_valid()) {
			String filename = p_texture->get_path().get_file().get_basename();
			if (_name == "New Texture" && !p_texture->get_path().contains("::") && !filename.is_empty()) {
				_name = filename;
				LOG(INFO, "Setting name based on filename: ", _name);
			}
			Ref<Image> img = p_texture->get_image();
			if (!img->has_mipmaps()) {
				LOG(WARN, "Albedo texture '", filename, "' has no mipmaps. Change on the Import panel if desired.");
			}
			if (img->get_width() != img->get_height()) {
				LOG(WARN, "Albedo texture '", filename, "' is not square. Mipmaps might have artifacts.");
			}
			if (!Math::is_power_of_2(img->get_width()) || !Math::is_power_of_2(img->get_height())) {
				LOG(WARN, "Albedo texture '", filename, "' size is not power of 2. This is sub-optimal.");
			}
			if (IS_EDITOR) {
				img = img->duplicate();
				img->decompress();
				img->resize(512, 512, Image::INTERPOLATE_LANCZOS);
				img->convert(Image::FORMAT_RGB8);
				_thumbnail = ImageTexture::create_from_image(img);
			}
		} else {
			_thumbnail.unref();
		}
		LOG(DEBUG, "Emitting file_changed");
		emit_signal("file_changed");
	}
}

void Terrain3DTextureAsset::set_normal_texture(const Ref<Texture2D> &p_texture) {
	if (_is_valid_format(p_texture)) {
		SET_IF_DIFF(_normal_texture, p_texture);
		LOG(INFO, "Setting normal texture: ", p_texture);
		if (p_texture.is_valid()) {
			String filename = p_texture->get_path().get_file().get_basename();
			Ref<Image> img = p_texture->get_image();
			if (!img->has_mipmaps()) {
				LOG(WARN, "Normal texture '", filename, "' has no mipmaps. Change on the Import panel if desired.");
			}
			if (img->get_width() != img->get_height()) {
				LOG(WARN, "Normal texture '", filename, "' is not square. Not recommended. Mipmaps might have artifacts.");
			}
			if (!Math::is_power_of_2(img->get_width()) || !Math::is_power_of_2(img->get_height())) {
				LOG(WARN, "Normal texture '", filename, "' dimensions are not power of 2. This is sub-optimal.");
			}
		}
		LOG(DEBUG, "Emitting file_changed");
		emit_signal("file_changed");
	}
}

void Terrain3DTextureAsset::set_normal_depth(const real_t p_normal_depth) {
	SET_IF_DIFF(_normal_depth, CLAMP(p_normal_depth, 0.0f, 2.0f));
	LOG(INFO, "Setting normal_depth: ", _normal_depth);
	LOG(DEBUG, "Emitting setting_changed");
	emit_signal("setting_changed");
}

void Terrain3DTextureAsset::set_roughness(const real_t p_roughness) {
	SET_IF_DIFF(_roughness, CLAMP(p_roughness, -1.0f, 1.0f));
	LOG(INFO, "Setting roughness modifier: ", _roughness);
	LOG(DEBUG, "Emitting setting_changed");
	emit_signal("setting_changed");
}

void Terrain3DTextureAsset::set_ao_strength(const real_t p_ao_strength) {
	SET_IF_DIFF(_ao_strength, CLAMP(p_ao_strength, 0.0f, 1.0f));
	LOG(INFO, "Setting ao_strength: ", _ao_strength);
	LOG(DEBUG, "Emitting setting_changed");
	emit_signal("setting_changed");
}

void Terrain3DTextureAsset::set_ao_light_affect(const real_t p_ao_light_affect) {
	SET_IF_DIFF(_ao_light_affect, CLAMP(p_ao_light_affect, 0.0f, 1.0f));
	LOG(INFO, "Setting ao_light_affect: ", _ao_light_affect);
	LOG(DEBUG, "Emitting setting_changed");
	emit_signal("setting_changed");
}

void Terrain3DTextureAsset::set_displacement_scale(const real_t p_displacement_scale) {
	SET_IF_DIFF(_displacement_scale, CLAMP(p_displacement_scale, 0.0f, 2.0f));
	LOG(INFO, "Setting displacement_scale: ", _displacement_scale);
	LOG(DEBUG, "Emitting setting_changed");
	emit_signal("setting_changed");
}

void Terrain3DTextureAsset::set_displacement_offset(const real_t p_displacement_offset) {
	SET_IF_DIFF(_displacement_offset, CLAMP(p_displacement_offset, -1.0f, 1.0f));
	LOG(INFO, "Setting displacement_offset: ", _displacement_offset);
	LOG(DEBUG, "Emitting setting_changed");
	emit_signal("setting_changed");
}

void Terrain3DTextureAsset::set_uv_scale(const real_t p_scale) {
	SET_IF_DIFF(_uv_scale, CLAMP(p_scale, 0.001f, 100.0f));
	LOG(INFO, "Setting uv_scale: ", _uv_scale);
	LOG(DEBUG, "Emitting setting_changed");
	emit_signal("setting_changed");
}

void Terrain3DTextureAsset::set_detiling_rotation(const real_t p_detiling_rotation) {
	SET_IF_DIFF(_detiling_rotation, CLAMP(p_detiling_rotation, 0.0f, 1.0f));
	LOG(INFO, "Setting detiling_rotation: ", _detiling_rotation);
	LOG(DEBUG, "Emitting setting_changed");
	emit_signal("setting_changed");
}

void Terrain3DTextureAsset::set_detiling_shift(const real_t p_detiling_shift) {
	SET_IF_DIFF(_detiling_shift, CLAMP(p_detiling_shift, 0.0f, 1.0f));
	LOG(INFO, "Setting detiling_shift: ", _detiling_shift);
	LOG(DEBUG, "Emitting setting_changed");
	emit_signal("setting_changed");
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DTextureAsset::_bind_methods() {
	ADD_SIGNAL(MethodInfo("id_changed",
			PropertyInfo(Variant::INT, "type"),
			PropertyInfo(Variant::INT, "old_id"),
			PropertyInfo(Variant::INT, "new_id")));
	ADD_SIGNAL(MethodInfo("file_changed"));
	ADD_SIGNAL(MethodInfo("setting_changed"));

	ClassDB::bind_method(D_METHOD("clear"), &Terrain3DTextureAsset::clear);
	BIND_ENUM_CONSTANT(SOURCE_TEXTURES);
	BIND_ENUM_CONSTANT(SOURCE_MATERIAL);
	BIND_ENUM_CONSTANT(CACHE_EMBEDDED);
	BIND_ENUM_CONSTANT(CACHE_EXTERNAL);
	ClassDB::bind_method(D_METHOD("set_source_mode", "mode"), &Terrain3DTextureAsset::set_source_mode);
	ClassDB::bind_method(D_METHOD("get_source_mode"), &Terrain3DTextureAsset::get_source_mode);
	ClassDB::bind_method(D_METHOD("set_material", "material"), &Terrain3DTextureAsset::set_material);
	ClassDB::bind_method(D_METHOD("get_material"), &Terrain3DTextureAsset::get_material);
	ClassDB::bind_method(D_METHOD("set_premultiply_ao", "enabled"), &Terrain3DTextureAsset::set_premultiply_ao);
	ClassDB::bind_method(D_METHOD("get_premultiply_ao"), &Terrain3DTextureAsset::get_premultiply_ao);
	ClassDB::bind_method(D_METHOD("set_material_texture_size", "size"), &Terrain3DTextureAsset::set_material_texture_size);
	ClassDB::bind_method(D_METHOD("get_material_texture_size"), &Terrain3DTextureAsset::get_material_texture_size);
	ClassDB::bind_method(D_METHOD("get_material_warnings"), &Terrain3DTextureAsset::get_material_warnings);
	ClassDB::bind_method(D_METHOD("bake_material", "size"), &Terrain3DTextureAsset::bake_material, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("prepare_texture_cache", "size"), &Terrain3DTextureAsset::prepare_texture_cache, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_encoded_cache", "compression"), &Terrain3DTextureAsset::get_encoded_cache);
	ClassDB::bind_method(D_METHOD("set_texture_cache", "cache"), &Terrain3DTextureAsset::set_texture_cache);
	ClassDB::bind_method(D_METHOD("get_texture_cache"), &Terrain3DTextureAsset::get_texture_cache);
	ClassDB::bind_method(D_METHOD("set_prepared_cache", "cache"), &Terrain3DTextureAsset::set_prepared_cache);
	ClassDB::bind_method(D_METHOD("get_prepared_cache"), &Terrain3DTextureAsset::get_prepared_cache);
	ClassDB::bind_method(D_METHOD("set_cache_storage", "storage"), &Terrain3DTextureAsset::set_cache_storage);
	ClassDB::bind_method(D_METHOD("get_cache_storage"), &Terrain3DTextureAsset::get_cache_storage);
	ClassDB::bind_method(D_METHOD("set_cache_directory", "directory"), &Terrain3DTextureAsset::set_cache_directory);
	ClassDB::bind_method(D_METHOD("get_cache_directory"), &Terrain3DTextureAsset::get_cache_directory);
	ClassDB::bind_method(D_METHOD("get_cache_file"), &Terrain3DTextureAsset::get_cache_file);
	ClassDB::bind_method(D_METHOD("set_material_cache", "cache"), &Terrain3DTextureAsset::set_material_cache);
	ClassDB::bind_method(D_METHOD("get_material_cache"), &Terrain3DTextureAsset::get_material_cache);
	ClassDB::bind_method(D_METHOD("set_material_cache_signature", "signature"), &Terrain3DTextureAsset::set_material_cache_signature);
	ClassDB::bind_method(D_METHOD("get_material_cache_signature"), &Terrain3DTextureAsset::get_material_cache_signature);
	ClassDB::bind_method(D_METHOD("set_material_emission_scale", "scale"), &Terrain3DTextureAsset::set_material_emission_scale);
	ClassDB::bind_method(D_METHOD("get_material_emission_scale"), &Terrain3DTextureAsset::get_material_emission_scale);
	ClassDB::bind_method(D_METHOD("set_material_settings", "settings"), &Terrain3DTextureAsset::set_material_settings);
	ClassDB::bind_method(D_METHOD("get_material_settings"), &Terrain3DTextureAsset::get_material_settings);
	ClassDB::bind_method(D_METHOD("set_runtime_material_cache", "enabled"), &Terrain3DTextureAsset::set_runtime_material_cache);
	ClassDB::bind_method(D_METHOD("get_runtime_material_cache"), &Terrain3DTextureAsset::get_runtime_material_cache);
	ClassDB::bind_method(D_METHOD("set_asset_name", "name"), &Terrain3DTextureAsset::set_asset_name);
	ClassDB::bind_method(D_METHOD("get_asset_name"), &Terrain3DTextureAsset::get_asset_name);
	ClassDB::bind_method(D_METHOD("set_id", "id"), &Terrain3DTextureAsset::set_id);
	ClassDB::bind_method(D_METHOD("get_id"), &Terrain3DTextureAsset::get_id);
	ClassDB::bind_method(D_METHOD("set_highlighted", "enabled"), &Terrain3DTextureAsset::set_highlighted);
	ClassDB::bind_method(D_METHOD("is_highlighted"), &Terrain3DTextureAsset::is_highlighted);
	ClassDB::bind_method(D_METHOD("get_highlight_color"), &Terrain3DTextureAsset::get_highlight_color);
	ClassDB::bind_method(D_METHOD("get_thumbnail"), &Terrain3DTextureAsset::get_thumbnail);
	ClassDB::bind_method(D_METHOD("set_albedo_color", "color"), &Terrain3DTextureAsset::set_albedo_color);
	ClassDB::bind_method(D_METHOD("get_albedo_color"), &Terrain3DTextureAsset::get_albedo_color);
	ClassDB::bind_method(D_METHOD("set_albedo_texture", "texture"), &Terrain3DTextureAsset::set_albedo_texture);
	ClassDB::bind_method(D_METHOD("get_albedo_texture"), &Terrain3DTextureAsset::get_albedo_texture);
	ClassDB::bind_method(D_METHOD("set_normal_texture", "texture"), &Terrain3DTextureAsset::set_normal_texture);
	ClassDB::bind_method(D_METHOD("get_normal_texture"), &Terrain3DTextureAsset::get_normal_texture);
	ClassDB::bind_method(D_METHOD("set_normal_depth", "normal_depth"), &Terrain3DTextureAsset::set_normal_depth);
	ClassDB::bind_method(D_METHOD("get_normal_depth"), &Terrain3DTextureAsset::get_normal_depth);
	ClassDB::bind_method(D_METHOD("set_ao_strength", "ao_strength"), &Terrain3DTextureAsset::set_ao_strength);
	ClassDB::bind_method(D_METHOD("get_ao_strength"), &Terrain3DTextureAsset::get_ao_strength);
	ClassDB::bind_method(D_METHOD("set_ao_light_affect", "ao_light_affect"), &Terrain3DTextureAsset::set_ao_light_affect);
	ClassDB::bind_method(D_METHOD("get_ao_light_affect"), &Terrain3DTextureAsset::get_ao_light_affect);
	ClassDB::bind_method(D_METHOD("set_roughness", "roughness"), &Terrain3DTextureAsset::set_roughness);
	ClassDB::bind_method(D_METHOD("get_roughness"), &Terrain3DTextureAsset::get_roughness);
	ClassDB::bind_method(D_METHOD("set_displacement_scale", "displacement_scale"), &Terrain3DTextureAsset::set_displacement_scale);
	ClassDB::bind_method(D_METHOD("get_displacement_scale"), &Terrain3DTextureAsset::get_displacement_scale);
	ClassDB::bind_method(D_METHOD("set_displacement_offset", "displacement_offset"), &Terrain3DTextureAsset::set_displacement_offset);
	ClassDB::bind_method(D_METHOD("get_displacement_offset"), &Terrain3DTextureAsset::get_displacement_offset);
	ClassDB::bind_method(D_METHOD("set_uv_scale", "scale"), &Terrain3DTextureAsset::set_uv_scale);
	ClassDB::bind_method(D_METHOD("get_uv_scale"), &Terrain3DTextureAsset::get_uv_scale);
	ClassDB::bind_method(D_METHOD("set_detiling_rotation", "detiling_rotation"), &Terrain3DTextureAsset::set_detiling_rotation);
	ClassDB::bind_method(D_METHOD("get_detiling_rotation"), &Terrain3DTextureAsset::get_detiling_rotation);
	ClassDB::bind_method(D_METHOD("set_detiling_shift", "detiling_shift"), &Terrain3DTextureAsset::set_detiling_shift);
	ClassDB::bind_method(D_METHOD("get_detiling_shift"), &Terrain3DTextureAsset::get_detiling_shift);

	ADD_PROPERTY(PropertyInfo(Variant::STRING, "name", PROPERTY_HINT_NONE), "set_asset_name", "get_asset_name");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "id", PROPERTY_HINT_NONE), "set_id", "get_id");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "source_mode", PROPERTY_HINT_ENUM, "Textures,PBR Material"), "set_source_mode", "get_source_mode");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "material", PROPERTY_HINT_RESOURCE_TYPE, "StandardMaterial3D,ORMMaterial3D"), "set_material", "get_material");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "premultiply_ao"), "set_premultiply_ao", "get_premultiply_ao");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "material_texture_size", PROPERTY_HINT_ENUM, "256:256,512:512,1024:1024,2048:2048,4096:4096"), "set_material_texture_size", "get_material_texture_size");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "material_warnings", PROPERTY_HINT_MULTILINE_TEXT, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_material_warnings");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "cache_storage", PROPERTY_HINT_ENUM, "Embedded,External .res"), "set_cache_storage", "get_cache_storage");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "cache_directory", PROPERTY_HINT_DIR), "set_cache_directory", "get_cache_directory");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "cache_file", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY), "", "get_cache_file");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "_texture_cache", PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DTextureCache", PROPERTY_USAGE_STORAGE), "set_texture_cache", "get_texture_cache");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "_prepared_cache", PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DTextureCache", PROPERTY_USAGE_STORAGE), "set_prepared_cache", "get_prepared_cache");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "_material_cache", PROPERTY_HINT_ARRAY_TYPE, "Image", PROPERTY_USAGE_NONE), "set_material_cache", "get_material_cache");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "_material_cache_signature", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_material_cache_signature", "get_material_cache_signature");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "_material_emission_scale", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_material_emission_scale", "get_material_emission_scale");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "_material_settings", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_material_settings", "get_material_settings");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "_runtime_material_cache", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_runtime_material_cache", "get_runtime_material_cache");
	ADD_PROPERTY(PropertyInfo(Variant::COLOR, "albedo_color", PROPERTY_HINT_COLOR_NO_ALPHA), "set_albedo_color", "get_albedo_color");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "albedo_texture", PROPERTY_HINT_RESOURCE_TYPE, "ImageTexture,CompressedTexture2D"), "set_albedo_texture", "get_albedo_texture");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "normal_texture", PROPERTY_HINT_RESOURCE_TYPE, "ImageTexture,CompressedTexture2D"), "set_normal_texture", "get_normal_texture");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "normal_depth", PROPERTY_HINT_RANGE, "0.0, 2.0"), "set_normal_depth", "get_normal_depth");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "ao_strength", PROPERTY_HINT_RANGE, "0.0, 1.0"), "set_ao_strength", "get_ao_strength");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "ao_light_affect", PROPERTY_HINT_RANGE, "0.0, 1.0"), "set_ao_light_affect", "get_ao_light_affect");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "roughness", PROPERTY_HINT_RANGE, "-1.0, 1.0"), "set_roughness", "get_roughness");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "displacement_scale", PROPERTY_HINT_RANGE, "0.0, 2.0"), "set_displacement_scale", "get_displacement_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "displacement_offset", PROPERTY_HINT_RANGE, "-1.0, 1.0"), "set_displacement_offset", "get_displacement_offset");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "uv_scale", PROPERTY_HINT_RANGE, "0.001, 2.0, or_greater"), "set_uv_scale", "get_uv_scale");
	ADD_GROUP("Detiling", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "detiling_rotation", PROPERTY_HINT_RANGE, "0.0, 1.0"), "set_detiling_rotation", "get_detiling_rotation");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "detiling_shift", PROPERTY_HINT_RANGE, "0.0, 1.0"), "set_detiling_shift", "get_detiling_shift");
}
