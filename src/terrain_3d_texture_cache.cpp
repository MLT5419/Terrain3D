// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/resource_saver.hpp>
#include <godot_cpp/classes/resource_uid.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "terrain_3d_texture_cache.h"

namespace {
void register_cache_uid(const String &p_path) {
	int64_t uid = ResourceLoader::get_singleton()->get_resource_uid(p_path);
	if (uid >= 0) {
		ResourceUID *registry = ResourceUID::get_singleton();
		if (registry->has_id(uid)) {
			registry->set_id(uid, p_path);
		} else {
			registry->add_id(uid, p_path);
		}
	}
}

Image::Format expected_format(Terrain3DTextureCache::Compression p_compression) {
	switch (p_compression) {
		case Terrain3DTextureCache::BC7:
			return Image::FORMAT_BPTC_RGBA;
		case Terrain3DTextureCache::ASTC_4X4:
			return Image::FORMAT_ASTC_4x4;
		case Terrain3DTextureCache::ETC2:
			return Image::FORMAT_ETC2_RGBA8;
		case Terrain3DTextureCache::BC3:
			return Image::FORMAT_DXT5;
		case Terrain3DTextureCache::RGBA8:
			return Image::FORMAT_RGBA8;
		default:
			return Image::FORMAT_MAX;
	}
}
} // namespace

bool Terrain3DTextureCache::is_valid(int p_size) const {
	if (_layout_version != LAYOUT_VERSION || _signature.is_empty() || _images.size() < 2 || _images.size() > 3) {
		return false;
	}
	Vector2i size;
	for (const Ref<Image> &image : _images) {
		if (image.is_null() || image->is_empty() || !image->has_mipmaps() || image->get_format() != expected_format(_compression)) {
			return false;
		}
		if (size == Vector2i()) {
			size = image->get_size();
		}
		if (image->get_size() != size || (p_size > 0 && size != Vector2i(p_size, p_size))) {
			return false;
		}
	}
	return true;
}

Ref<Terrain3DTextureCache> Terrain3DTextureCache::encode(Compression p_compression) const {
	ERR_FAIL_COND_V(!is_valid() || p_compression == AUTO, Ref<Terrain3DTextureCache>());
	if (p_compression == _compression) {
		return Ref<Terrain3DTextureCache>(const_cast<Terrain3DTextureCache *>(this));
	}
	// Runtime fallback is decoding only. Platform compression is always derived from
	// the lossless master in the editor/exporter, not from another lossy variant.
	ERR_FAIL_COND_V_MSG(p_compression != RGBA8 && _compression != RGBA8, Ref<Terrain3DTextureCache>(), "Generate platform variants from the lossless RGBA8 texture cache.");
	ERR_FAIL_COND_V_MSG(p_compression != RGBA8 && !Engine::get_singleton()->is_editor_hint(), Ref<Terrain3DTextureCache>(), "Texture encoding is editor-only.");
	TypedArray<Image> images;
	for (const Ref<Image> &source : _images) {
		Ref<Image> image = source->duplicate();
		if (image->is_compressed()) {
			ERR_FAIL_COND_V_MSG(image->decompress() != OK, Ref<Terrain3DTextureCache>(), "This build cannot decode the texture cache for the RGBA8 fallback.");
		}
		image->convert(Image::FORMAT_RGBA8);
		Error error = OK;
		switch (p_compression) {
			case BC7:
				error = image->compress(Image::COMPRESS_BPTC, Image::COMPRESS_SOURCE_GENERIC);
				break;
			case ASTC_4X4:
				error = image->compress(Image::COMPRESS_ASTC, Image::COMPRESS_SOURCE_GENERIC, Image::ASTC_FORMAT_4x4);
				break;
			case ETC2:
				error = image->compress_from_channels(Image::COMPRESS_ETC2, Image::USED_CHANNELS_RGBA);
				break;
			case BC3:
				error = image->compress_from_channels(Image::COMPRESS_S3TC, Image::USED_CHANNELS_RGBA);
				break;
			default:
				break;
		}
		ERR_FAIL_COND_V_MSG(error != OK || image->get_format() != expected_format(p_compression), Ref<Terrain3DTextureCache>(), "The requested RGBA texture encoder is unavailable in this Godot build.");
		images.push_back(image);
	}
	Ref<Terrain3DTextureCache> result;
	result.instantiate();
	result->set_signature(_signature);
	result->set_images(images);
	result->set_compression(p_compression);
	result->set_emission_scale(_emission_scale);
	return result;
}

String Terrain3DTextureCache::compression_name(Compression p_compression) {
	switch (p_compression) {
		case BC7:
			return "bc7";
		case ASTC_4X4:
			return "astc4x4";
		case ETC2:
			return "etc2_rgba8";
		case BC3:
			return "bc3";
		case RGBA8:
			return "rgba8";
		default:
			return "auto";
	}
}

bool Terrain3DTextureCache::is_supported(Compression p_compression) {
	RenderingServer *server = RenderingServer::get_singleton();
	switch (p_compression) {
		case BC7:
			return server->has_os_feature("bptc");
		case ASTC_4X4:
			return server->has_os_feature("astc");
		case ETC2:
			return server->has_os_feature("etc2");
		case BC3:
			return server->has_os_feature("s3tc");
		case RGBA8:
			return true;
		default:
			return false;
	}
}

Terrain3DTextureCache::Compression Terrain3DTextureCache::select_for_device(Compression p_compression) {
	if (p_compression != AUTO) {
		return is_supported(p_compression) ? p_compression : RGBA8;
	}
	for (Compression compression : { BC7, ASTC_4X4, ETC2, BC3 }) {
		if (is_supported(compression)) {
			return compression;
		}
	}
	return RGBA8;
}

Error Terrain3DTextureCache::save_external(const String &p_path) {
	ERR_FAIL_COND_V_MSG(!p_path.begins_with("res://") || p_path.get_extension() != "res", ERR_INVALID_PARAMETER, "Texture caches must be .res files inside the project.");
	ERR_FAIL_COND_V(!is_valid(), ERR_INVALID_DATA);
	String absolute = ProjectSettings::get_singleton()->globalize_path(p_path.simplify_path()).simplify_path();
	String root = ProjectSettings::get_singleton()->globalize_path("res://").trim_suffix("/") + "/";
	ERR_FAIL_COND_V_MSG(!absolute.begins_with(root), ERR_INVALID_PARAMETER, "Texture cache path must stay inside the project.");
	Error error = DirAccess::make_dir_recursive_absolute(absolute.get_base_dir());
	ERR_FAIL_COND_V(error != OK, error);
	// Content-addressed files are immutable. An existing valid file can be shared.
	if (FileAccess::file_exists(absolute)) {
		Ref<Terrain3DTextureCache> existing = ResourceLoader::get_singleton()->load(p_path, "Terrain3DTextureCache", ResourceLoader::CACHE_MODE_REUSE);
		Ref<Image> first = _images[0];
		if (existing.is_valid() && existing->is_valid(first->get_width()) && existing->get_images().size() == _images.size() && existing->get_signature() == _signature && existing->get_compression() == _compression) {
			register_cache_uid(p_path);
			return OK;
		}
	}
	String temporary = absolute.get_basename() + ".tmp-" + String::num_uint64(Time::get_singleton()->get_ticks_usec()) + ".res";
	error = ResourceSaver::get_singleton()->save(Ref<Terrain3DTextureCache>(this), temporary, ResourceSaver::FLAG_COMPRESS);
	if (error != OK) {
		return error;
	}
	error = DirAccess::rename_absolute(temporary, absolute);
	if (error != OK) {
		DirAccess::remove_absolute(temporary);
	} else {
		register_cache_uid(p_path);
	}
	return error;
}

void Terrain3DTextureCache::_bind_methods() {
	BIND_ENUM_CONSTANT(AUTO);
	BIND_ENUM_CONSTANT(BC7);
	BIND_ENUM_CONSTANT(ASTC_4X4);
	BIND_ENUM_CONSTANT(ETC2);
	BIND_ENUM_CONSTANT(BC3);
	BIND_ENUM_CONSTANT(RGBA8);
	BIND_CONSTANT(LAYOUT_VERSION);
	ClassDB::bind_method(D_METHOD("set_layout_version", "version"), &Terrain3DTextureCache::set_layout_version);
	ClassDB::bind_method(D_METHOD("get_layout_version"), &Terrain3DTextureCache::get_layout_version);
	ClassDB::bind_method(D_METHOD("set_compression", "compression"), &Terrain3DTextureCache::set_compression);
	ClassDB::bind_method(D_METHOD("get_compression"), &Terrain3DTextureCache::get_compression);
	ClassDB::bind_method(D_METHOD("set_signature", "signature"), &Terrain3DTextureCache::set_signature);
	ClassDB::bind_method(D_METHOD("get_signature"), &Terrain3DTextureCache::get_signature);
	ClassDB::bind_method(D_METHOD("set_images", "images"), &Terrain3DTextureCache::set_images);
	ClassDB::bind_method(D_METHOD("get_images"), &Terrain3DTextureCache::get_images);
	ClassDB::bind_method(D_METHOD("set_emission_scale", "scale"), &Terrain3DTextureCache::set_emission_scale);
	ClassDB::bind_method(D_METHOD("get_emission_scale"), &Terrain3DTextureCache::get_emission_scale);
	ClassDB::bind_method(D_METHOD("is_valid", "size"), &Terrain3DTextureCache::is_valid, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("encode", "compression"), &Terrain3DTextureCache::encode);
	ClassDB::bind_method(D_METHOD("save_external", "path"), &Terrain3DTextureCache::save_external);
	ClassDB::bind_static_method("Terrain3DTextureCache", D_METHOD("compression_name", "compression"), &Terrain3DTextureCache::compression_name);
	ClassDB::bind_static_method("Terrain3DTextureCache", D_METHOD("select_for_device", "compression"), &Terrain3DTextureCache::select_for_device, DEFVAL(AUTO));
	ClassDB::bind_static_method("Terrain3DTextureCache", D_METHOD("is_supported", "compression"), &Terrain3DTextureCache::is_supported);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "layout_version"), "set_layout_version", "get_layout_version");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "compression", PROPERTY_HINT_ENUM, "Auto,BC7,ASTC 4x4,ETC2 RGBA8,BC3,RGBA8"), "set_compression", "get_compression");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "signature"), "set_signature", "get_signature");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "images", PROPERTY_HINT_ARRAY_TYPE, "Image"), "set_images", "get_images");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "emission_scale"), "set_emission_scale", "get_emission_scale");
}
