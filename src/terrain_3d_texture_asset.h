// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_TEXTURE_CLASS_H
#define TERRAIN3D_TEXTURE_CLASS_H

#include <godot_cpp/classes/base_material3d.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/texture2d.hpp>

#include "constants.h"
#include "terrain_3d_asset_resource.h"
#include "terrain_3d_texture_cache.h"

class Terrain3DTextureAsset : public Terrain3DAssetResource {
	GDCLASS(Terrain3DTextureAsset, Terrain3DAssetResource);
	CLASS_NAME();
	friend class Terrain3DAssets;

public:
	enum SourceMode { SOURCE_TEXTURES,
		SOURCE_MATERIAL };
	enum CacheStorage { CACHE_EMBEDDED,
		CACHE_EXTERNAL };

private:
	SourceMode _source_mode = SOURCE_TEXTURES;
	Ref<BaseMaterial3D> _material;
	bool _premultiply_ao = false;
	int _material_texture_size = 1024;
	Ref<Terrain3DTextureCache> _texture_cache;
	Ref<Terrain3DTextureCache> _prepared_cache;
	CacheStorage _cache_storage = CACHE_EMBEDDED;
	String _cache_directory = "res://terrain3d_cache";
	Error _persist_cache(Ref<Terrain3DTextureCache> &p_cache);
	TypedArray<Image> _material_cache;
	String _material_cache_signature;
	float _material_emission_scale = 1.f;
	Dictionary _material_settings;
	uint32_t _material_source_state = 0;
	bool _runtime_material_cache = false;
	TypedArray<Texture2D> _material_textures;
	void _material_changed();
	void _disconnect_material();
	void _connect_material_textures();
	void _poll_material_changes();

	// Saved Data
	Color _albedo_color = Color(1.f, 1.f, 1.f, 1.f);
	Ref<Texture2D> _albedo_texture;
	Ref<Texture2D> _normal_texture;
	real_t _normal_depth = 1.0f;
	real_t _ao_strength = 0.5f;
	real_t _ao_light_affect = 0.0f;
	real_t _roughness = 0.f;
	real_t _displacement_scale = 0.0f;
	real_t _displacement_offset = 0.0f;
	real_t _uv_scale = 0.1f;
	real_t _detiling_rotation = 0.0f;
	real_t _detiling_shift = 0.0f;

	// Working Data
	Color _highlight_color = Color();

	bool _is_valid_format(const Ref<Texture2D> &p_texture) const;

public:
	Terrain3DTextureAsset() { clear(); }
	~Terrain3DTextureAsset() { _disconnect_material(); }
	void initialize() override;
	void clear() override;
	void set_source_mode(SourceMode p_mode);
	SourceMode get_source_mode() const { return _source_mode; }
	void set_material(const Ref<BaseMaterial3D> &p_material);
	Ref<BaseMaterial3D> get_material() const { return _material; }
	void set_premultiply_ao(bool p_enabled);
	bool get_premultiply_ao() const { return _premultiply_ao; }
	void set_material_texture_size(int p_size);
	int get_material_texture_size() const { return _material_texture_size; }
	String get_material_warnings() const;
	Error bake_material(int p_size = 0);
	Error prepare_texture_cache(int p_size = 0);
	Ref<Terrain3DTextureCache> get_encoded_cache(Terrain3DTextureCache::Compression p_compression);
	void set_texture_cache(const Ref<Terrain3DTextureCache> &p_cache) { _texture_cache = p_cache; }
	Ref<Terrain3DTextureCache> get_texture_cache() const { return _texture_cache; }
	void set_prepared_cache(const Ref<Terrain3DTextureCache> &p_cache) { _prepared_cache = p_cache; }
	Ref<Terrain3DTextureCache> get_prepared_cache() const { return _prepared_cache; }
	void set_cache_storage(CacheStorage p_storage);
	CacheStorage get_cache_storage() const { return _cache_storage; }
	void set_cache_directory(const String &p_directory);
	String get_cache_directory() const { return _cache_directory; }
	String get_cache_file() const { return _texture_cache.is_valid() ? _texture_cache->get_path() : String(); }
	void set_material_cache(const TypedArray<Image> &p_cache) { _material_cache = p_cache; }
	TypedArray<Image> get_material_cache() const { return _texture_cache.is_valid() ? _texture_cache->get_images() : _material_cache; }
	void set_material_cache_signature(const String &p_signature) { _material_cache_signature = p_signature; }
	String get_material_cache_signature() const { return _texture_cache.is_valid() ? _texture_cache->get_signature() : _material_cache_signature; }
	void set_material_emission_scale(float p_scale) { _material_emission_scale = p_scale; }
	float get_material_emission_scale() const { return _texture_cache.is_valid() ? _texture_cache->get_emission_scale() : _material_emission_scale; }
	void set_material_settings(const Dictionary &p_settings) { _material_settings = p_settings; }
	Dictionary get_material_settings() const;
	void set_runtime_material_cache(bool p_enabled) { _runtime_material_cache = p_enabled; }
	bool get_runtime_material_cache() const { return _runtime_material_cache; }

	void set_asset_name(const String &p_name) override;
	String get_asset_name() const override { return _name; }

	void set_id(const int p_new_id) override;
	int get_id() const override { return _id; }

	void set_highlighted(const bool p_highlighted) override;
	bool is_highlighted() const override { return _highlighted; }
	Color get_highlight_color() const override { return _highlighted ? _highlight_color : COLOR_WHITE; }

	Ref<Texture2D> get_thumbnail() const override { return _thumbnail; }

	void set_albedo_color(const Color &p_color);
	Color get_albedo_color() const { return _albedo_color; }

	void set_albedo_texture(const Ref<Texture2D> &p_texture);
	Ref<Texture2D> get_albedo_texture() const { return _albedo_texture; }

	void set_normal_texture(const Ref<Texture2D> &p_texture);
	Ref<Texture2D> get_normal_texture() const { return _normal_texture; }

	void set_normal_depth(const real_t p_normal_depth);
	real_t get_normal_depth() const { return _normal_depth; }

	void set_ao_strength(const real_t p_ao_strength);
	real_t get_ao_strength() const { return _ao_strength; }

	void set_ao_light_affect(const real_t p_ao_light_affect);
	real_t get_ao_light_affect() const { return _ao_light_affect; }

	void set_roughness(const real_t p_roughness);
	real_t get_roughness() const { return _roughness; }

	void set_displacement_scale(const real_t p_displacement_scale);
	real_t get_displacement_scale() const { return _displacement_scale; }

	void set_displacement_offset(const real_t p_displacement_offset);
	real_t get_displacement_offset() const { return _displacement_offset; }

	void set_uv_scale(const real_t p_scale);
	real_t get_uv_scale() const { return _uv_scale; }

	void set_detiling_rotation(const real_t p_detiling_rotation);
	real_t get_detiling_rotation() const { return _detiling_rotation; }

	void set_detiling_shift(const real_t p_detiling_shift);
	real_t get_detiling_shift() const { return _detiling_shift; }

protected:
	void _validate_property(PropertyInfo &p_property) const;
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Terrain3DTextureAsset::SourceMode);
VARIANT_ENUM_CAST(Terrain3DTextureAsset::CacheStorage);

#endif // TERRAIN3D_TEXTURE_CLASS_H
