// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_MATERIAL_BAKER_H
#define TERRAIN3D_MATERIAL_BAKER_H

#include <godot_cpp/classes/base_material3d.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/texture2d.hpp>

using namespace godot;

// Editor-side conversion. Cached Images are serialized with the texture asset, so exported
// games never need a texture compressor or access to the original source files.
class Terrain3DMaterialBaker {
public:
	static uint32_t source_state(const Ref<BaseMaterial3D> &p_material);
	static String signature(const Ref<BaseMaterial3D> &p_material, int p_size, bool p_premultiply_ao);
	static String warnings(const Ref<BaseMaterial3D> &p_material);
	static Error bake(const Ref<BaseMaterial3D> &p_material, int p_size, bool p_premultiply_ao,
			TypedArray<Image> &r_images, float &r_emission_scale);
};

#endif
