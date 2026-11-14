// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_TEXTURE_CACHE_H
#define TERRAIN3D_TEXTURE_CACHE_H

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/resource.hpp>

using namespace godot;

// A lossless authoring cache or ONE cooked platform variant, never a bundle of variants.
// Only the selected cooked resource is referenced by exported texture assets.
class Terrain3DTextureCache : public Resource {
	GDCLASS(Terrain3DTextureCache, Resource);

public:
	enum Compression { AUTO,
		BC7,
		ASTC_4X4,
		ETC2,
		BC3,
		RGBA8 };
	static constexpr int LAYOUT_VERSION = 2;

private:
	int _layout_version = LAYOUT_VERSION;
	Compression _compression = RGBA8;
	String _signature;
	TypedArray<Image> _images;
	float _emission_scale = 1.f;

protected:
	static void _bind_methods();

public:
	void set_layout_version(int p_version) { _layout_version = p_version; }
	int get_layout_version() const { return _layout_version; }
	void set_compression(Compression p_compression) { _compression = p_compression; }
	Compression get_compression() const { return _compression; }
	void set_signature(const String &p_signature) { _signature = p_signature; }
	String get_signature() const { return _signature; }
	void set_images(const TypedArray<Image> &p_images) { _images = p_images; }
	TypedArray<Image> get_images() const { return _images; }
	void set_emission_scale(float p_scale) { _emission_scale = p_scale; }
	float get_emission_scale() const { return _emission_scale; }
	bool is_valid(int p_size = 0) const;
	Ref<Terrain3DTextureCache> encode(Compression p_compression) const;
	Error save_external(const String &p_path);
	static String compression_name(Compression p_compression);
	static Compression select_for_device(Compression p_compression = AUTO);
	static bool is_supported(Compression p_compression);
};

VARIANT_ENUM_CAST(Terrain3DTextureCache::Compression);

#endif
