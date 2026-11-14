// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/orm_material3d.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "terrain_3d_material_baker.h"

namespace {
using BM = BaseMaterial3D;
constexpr int BAKE_VERSION = 1;
const BM::TextureParam MAPS[] = { BM::TEXTURE_ALBEDO, BM::TEXTURE_NORMAL, BM::TEXTURE_ROUGHNESS,
	BM::TEXTURE_METALLIC, BM::TEXTURE_AMBIENT_OCCLUSION, BM::TEXTURE_EMISSION,
	BM::TEXTURE_HEIGHTMAP, BM::TEXTURE_ORM };

// These are precisely the properties that affect the packed pixels. UV transforms,
// normal strength, specular and AO light affect remain inexpensive shader parameters.
const char *PIXEL_PROPERTIES[] = { "roughness", "metallic", "normal_enabled", "ao_enabled",
	"emission_enabled", "heightmap_enabled", "roughness_texture_channel", "metallic_texture_channel",
	"ao_texture_channel", "emission", "emission_energy_multiplier", "emission_operator", "heightmap_flip_texture" };

float channel(const Color &p_color, BM::TextureChannel p_channel) {
	return p_channel == BM::TEXTURE_CHANNEL_GRAYSCALE ? (p_color.r + p_color.g + p_color.b) / 3.f : p_color[int(p_channel)];
}

Ref<Image> read_texture(const Ref<Texture2D> &p_texture, int p_size, bool p_normal) {
	if (p_texture.is_null()) {
		return Ref<Image>();
	}
	Ref<Image> image = p_texture->get_image();
	if (image.is_null() || image->is_empty()) {
		return Ref<Image>();
	}
	Image::Format original_format = image->get_format();
	bool hdr = original_format == Image::FORMAT_RGBF || original_format == Image::FORMAT_RGBAF || original_format == Image::FORMAT_RGBH || original_format == Image::FORMAT_RGBAH || original_format == Image::FORMAT_RGBE9995 || original_format == Image::FORMAT_BPTC_RGBF || original_format == Image::FORMAT_BPTC_RGBFU || original_format == Image::FORMAT_ASTC_4x4_HDR || original_format == Image::FORMAT_ASTC_8x8_HDR;
	image = image->duplicate();
	if (image->is_compressed() && image->decompress() != OK) {
		return Ref<Image>();
	}
	image->clear_mipmaps();
	image->convert(Image::FORMAT_RGBAF);
	// Decode normals / linearize colors BEFORE resampling. Masks remain linear.
	for (int y = 0; y < image->get_height(); y++) {
		for (int x = 0; x < image->get_width(); x++) {
			Color c = image->get_pixel(x, y);
			if (p_normal) {
				float nx = c.r * 2.f - 1.f;
				bool ra = original_format == Image::FORMAT_DXT5_RA_AS_RG || original_format == Image::FORMAT_ETC2_RA_AS_RG;
				float ny = (ra ? c.a : c.g) * 2.f - 1.f;
				Vector3 n(nx, ny, Math::sqrt(MAX(0.f, 1.f - nx * nx - ny * ny)));
				n.normalize();
				c = Color(n.x * .5f + .5f, n.y * .5f + .5f, n.z * .5f + .5f, 1.f);
			} else if (!hdr) {
				c = c.srgb_to_linear();
			}
			image->set_pixel(x, y, c);
		}
	}
	if (image->get_size() != Vector2i(p_size, p_size)) {
		image->resize(p_size, p_size, Image::INTERPOLATE_BILINEAR);
	}
	return image;
}

// Data maps must not pass through the sRGB conversion above.
Ref<Image> read_mask(const Ref<Texture2D> &p_texture, int p_size) {
	if (p_texture.is_null()) {
		return Ref<Image>();
	}
	Ref<Image> image = p_texture->get_image();
	if (image.is_null() || image->is_empty()) {
		return Ref<Image>();
	}
	image = image->duplicate();
	if (image->is_compressed() && image->decompress() != OK) {
		return Ref<Image>();
	}
	image->clear_mipmaps();
	image->convert(Image::FORMAT_RGBAF);
	if (image->get_size() != Vector2i(p_size, p_size)) {
		image->resize(p_size, p_size, Image::INTERPOLATE_BILINEAR);
	}
	return image;
}

Color pixel(const Ref<Image> &p_image, int x, int y, const Color &p_default = Color(1, 1, 1, 1)) {
	return p_image.is_valid() ? p_image->get_pixel(x, y) : p_default;
}

uint8_t byte(float p_value) {
	return uint8_t(CLAMP(p_value * 255.f + .5f, 0.f, 255.f));
}
} // namespace

uint32_t Terrain3DMaterialBaker::source_state(const Ref<BaseMaterial3D> &p_material) {
	Array values;
	for (const char *property : PIXEL_PROPERTIES) {
		values.push_back(p_material->get(property));
	}
	for (BM::TextureParam map : MAPS) {
		values.push_back(p_material->get_texture(map));
	}
	return values.hash();
}

String Terrain3DMaterialBaker::signature(const Ref<BaseMaterial3D> &p_material, int p_size, bool p_premultiply_ao) {
	Array values;
	values.push_back(BAKE_VERSION);
	values.push_back(p_size);
	values.push_back(p_premultiply_ao);
	values.push_back(p_material->is_class("ORMMaterial3D"));
	for (const char *property : PIXEL_PROPERTIES) {
		values.push_back(p_material->get(property));
	}
	for (BM::TextureParam map : MAPS) {
		Ref<Texture2D> texture = p_material->get_texture(map);
		Ref<Image> image = texture.is_valid() ? texture->get_image() : Ref<Image>();
		values.push_back(image.is_valid() ? Variant(image->get_data()).hash() : 0);
		values.push_back(image.is_valid() ? int(image->get_format()) : -1);
	}
	return String::num_uint64(values.hash());
}

String Terrain3DMaterialBaker::warnings(const Ref<BaseMaterial3D> &p_material) {
	if (p_material.is_null()) {
		return "Assign a StandardMaterial3D or ORMMaterial3D.";
	}
	PackedStringArray messages;
	if (p_material->get_transparency() != BM::TRANSPARENCY_DISABLED || p_material->get_blend_mode() != BM::BLEND_MODE_MIX) {
		messages.push_back("Terrain layers are opaque; transparency and blend modes are not transferred.");
	}
	if (p_material->get_shading_mode() != BM::SHADING_MODE_PER_PIXEL || p_material->get_diffuse_mode() != BM::DIFFUSE_BURLEY || p_material->get_specular_mode() != BM::SPECULAR_SCHLICK_GGX) {
		messages.push_back("The terrain uses its shared Burley/GGX lighting model.");
	}
	for (const char *property : { "clearcoat_enabled", "rim_enabled", "anisotropy_enabled", "subsurf_scatter_enabled", "backlight_enabled", "refraction_enabled", "detail_enabled", "uv1_triplanar", "ao_on_uv2", "emission_on_uv2", "heightmap_deep_parallax", "grow", "vertex_color_use_as_albedo", "bent_normal_enabled", "proximity_fade_enabled", "albedo_texture_msdf", "use_point_size", "disable_receive_shadows", "disable_ambient_light", "disable_fog" }) {
		if (bool(p_material->get(property))) {
			messages.push_back(String(property) + " is not supported by the terrain PBR adapter.");
		}
	}
	if (int(p_material->get("billboard_mode")) != 0 || int(p_material->get("distance_fade_mode")) != 0) {
		messages.push_back("Billboards and distance fading are not transferred.");
	}
	if (p_material->get_next_pass().is_valid()) {
		messages.push_back("Additional material passes are not transferred.");
	}
	return String("\n").join(messages);
}

Error Terrain3DMaterialBaker::bake(const Ref<BaseMaterial3D> &p_material, int p_size, bool p_premultiply_ao,
		TypedArray<Image> &r_images, float &r_emission_scale) {
	ERR_FAIL_COND_V(p_material.is_null(), ERR_INVALID_PARAMETER);
	Ref<Image> maps[8];
	for (int i = 0; i < 8; i++) {
		Ref<Texture2D> texture = p_material->get_texture(MAPS[i]);
		maps[i] = (i == 0 || i == 1 || i == 5) ? read_texture(texture, p_size, i == 1) : read_mask(texture, p_size);
		ERR_FAIL_COND_V_MSG(texture.is_valid() && maps[i].is_null(), ERR_CANT_OPEN, "Cannot read a PBR source texture.");
	}
	bool orm = p_material->is_class("ORMMaterial3D");
	bool ao_enabled = p_material->get_feature(BM::FEATURE_AMBIENT_OCCLUSION);
	bool emission_enabled = p_material->get_feature(BM::FEATURE_EMISSION);
	bool normal_enabled = p_material->get_feature(BM::FEATURE_NORMAL_MAPPING);
	bool height_enabled = p_material->get_feature(BM::FEATURE_HEIGHT_MAPPING);
	bool flip_height = bool(p_material->get("heightmap_flip_texture"));
	float roughness_factor = p_material->get_roughness();
	float metallic_factor = p_material->get_metallic();
	float emission_energy = p_material->get_emission_energy_multiplier();
	BM::TextureChannel roughness_channel = p_material->get_roughness_texture_channel();
	BM::TextureChannel metallic_channel = p_material->get_metallic_texture_channel();
	BM::TextureChannel ao_channel = p_material->get_ao_texture_channel();
	bool add_emission = p_material->get_emission_operator() == BM::EMISSION_OP_ADD;
	bool auxiliary = (!p_premultiply_ao && ao_enabled && (orm ? maps[7].is_valid() : maps[4].is_valid())) || emission_enabled;
	Ref<Image> albedo = Image::create(p_size, p_size, false, Image::FORMAT_RGBAF);
	Ref<Image> normals = Image::create(p_size, p_size, false, Image::FORMAT_RGBAF);
	Ref<Image> surface = Image::create(p_size, p_size, false, Image::FORMAT_RGBAF);
	Ref<Image> emission = Image::create(p_size, p_size, false, Image::FORMAT_RGBAF);
	Color emission_color = p_material->get_emission().srgb_to_linear();
	r_emission_scale = 1.f;
	for (int y = 0; y < p_size; y++) {
		for (int x = 0; x < p_size; x++) {
			Color c = pixel(maps[0], x, y);
			float height = height_enabled ? pixel(maps[6], x, y, Color(.5, .5, .5, 1)).r : .5f;
			if (flip_height) {
				height = 1.f - height;
			}
			float roughness = (orm ? pixel(maps[7], x, y).g : channel(pixel(maps[2], x, y), roughness_channel)) * roughness_factor;
			float metallic = (orm ? pixel(maps[7], x, y).b : channel(pixel(maps[3], x, y), metallic_channel)) * metallic_factor;
			float ao = ao_enabled ? (orm ? pixel(maps[7], x, y).r : channel(pixel(maps[4], x, y), ao_channel)) : 1.f;
			if (p_premultiply_ao) {
				c.r *= ao;
				c.g *= ao;
				c.b *= ao;
			}
			c.a = height;
			albedo->set_pixel(x, y, c);
			normals->set_pixel(x, y, normal_enabled ? pixel(maps[1], x, y, Color(.5, .5, 1, 1)) : Color(.5, .5, 1, 1));
			surface->set_pixel(x, y, Color(roughness, metallic, p_premultiply_ao ? 1.f : ao, 1));
			Color e(0, 0, 0, 1);
			if (emission_enabled) {
				e = emission_color;
				if (maps[5].is_valid()) {
					Color texture_color = pixel(maps[5], x, y);
					e = add_emission ? e + texture_color : e * texture_color;
				}
				e *= emission_energy;
				r_emission_scale = MAX(r_emission_scale, MAX(e.r, MAX(e.g, e.b)));
			}
			emission->set_pixel(x, y, e);
		}
	}
	// Generate each semantic mip chain separately. Renormalizing packed NxyRM would corrupt
	// roughness/metallic; filtering sRGB bytes would darken colors and AO premultiplication.
	albedo->generate_mipmaps();
	normals->generate_mipmaps(true);
	surface->generate_mipmaps();
	emission->generate_mipmaps();
	PackedByteArray alb_bytes = albedo->get_data();
	PackedByteArray nrm_bytes = normals->get_data();
	PackedByteArray surface_bytes = surface->get_data();
	PackedByteArray emission_bytes = emission->get_data();
	const float *a = reinterpret_cast<const float *>(alb_bytes.ptr());
	const float *n = reinterpret_cast<const float *>(nrm_bytes.ptr());
	const float *s = reinterpret_cast<const float *>(surface_bytes.ptr());
	const float *e = reinterpret_cast<const float *>(emission_bytes.ptr());
	int64_t count = alb_bytes.size() / sizeof(float);
	PackedByteArray output[3];
	for (int j = 0; j < (auxiliary ? 3 : 2); j++) {
		output[j].resize(count);
	}
	uint8_t *out_a = output[0].ptrw();
	uint8_t *out_n = output[1].ptrw();
	uint8_t *out_e = auxiliary ? output[2].ptrw() : nullptr;
	for (int64_t i = 0; i < count; i += 4) {
		Color ac = Color(a[i], a[i + 1], a[i + 2], a[i + 3]).linear_to_srgb();
		out_a[i] = byte(ac.r);
		out_a[i + 1] = byte(ac.g);
		out_a[i + 2] = byte(ac.b);
		out_a[i + 3] = byte(ac.a);
		out_n[i] = byte(n[i]);
		out_n[i + 1] = byte(n[i + 1]);
		out_n[i + 2] = byte(s[i]);
		out_n[i + 3] = byte(s[i + 1]);
		if (auxiliary) {
			Color ec = Color(e[i] / r_emission_scale, e[i + 1] / r_emission_scale, e[i + 2] / r_emission_scale, s[i + 2]).linear_to_srgb();
			out_e[i] = byte(ec.r);
			out_e[i + 1] = byte(ec.g);
			out_e[i + 2] = byte(ec.b);
			out_e[i + 3] = byte(ec.a);
		}
	}
	r_images.clear();
	for (int j = 0; j < (auxiliary ? 3 : 2); j++) {
		Ref<Image> image = Image::create_from_data(p_size, p_size, true, Image::FORMAT_RGBA8, output[j]);
		// Preserve ALL four channels. A normal-map compressor would discard metallic/roughness.
		Error error = image->compress(Image::COMPRESS_BPTC, Image::COMPRESS_SOURCE_GENERIC);
		ERR_FAIL_COND_V_MSG(error != OK, error, "BC7 compression requires an editor build with BPTC support.");
		r_images.push_back(image);
	}
	return OK;
}
