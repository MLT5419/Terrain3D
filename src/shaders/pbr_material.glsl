// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(
//INSERT: PBR_MATERIAL_UNIFORMS
#define TERRAIN3D_TEXTURE_LAYOUT_VERSION 2
uniform float _texture_auxiliary_indices[32];
uniform float _texture_material_weights[32];
uniform vec4 _texture_material_uvs[32]; // UV scale.xy, offset.xy
uniform vec2 _texture_material_properties[32]; // emission scale, specular

//INSERT: PBR_MATERIAL_FRAGMENT_UNIFORMS
uniform highp sampler2DArray _texture_array_emission : source_color, FILTER_METHOD, repeat_enable;

//INSERT: PBR_MATERIAL_HEIGHT_FUNCTIONS
float sample_terrain_height(int id, vec2 uv) {
	uv = uv * _texture_material_uvs[id].xy + _texture_material_uvs[id].zw;
	return textureLod(_texture_array_albedo, vec3(uv, float(id)), 0.).a;
}

vec3 sample_terrain_displacement_normal(int id, vec2 uv) {
	uv = uv * _texture_material_uvs[id].xy + _texture_material_uvs[id].zw;
	vec2 xy = textureLod(_texture_array_normal, vec3(uv, float(id)), 0.).rg * 2. - 1.;
	vec3 n = normalize(vec3(xy, sqrt(max(1. - dot(xy, xy), 0.))));
	n.xy *= sign(_texture_material_uvs[id].xy);
	// The old displacement buffer used the AO-bearing normal magnitude for blending.
	if (_texture_material_weights[id] < .5 && _texture_auxiliary_indices[id] >= 0.) {
		float occlusion = textureLod(_texture_array_emission, vec3(uv, _texture_auxiliary_indices[id]), 0.).a;
		n *= .5 + .5 * sqrt(clamp(occlusion, 0., 1.));
	}
	return n.xzy;
}
)"
R"(
//INSERT: PBR_MATERIAL_FRAGMENT_FUNCTIONS
void sample_terrain_layer(int id, vec2 uv, vec4 dd, out vec4 alb, out vec4 nrm,
		out float ao, out vec3 pbr, out vec3 emission) {
	vec4 transform = _texture_material_uvs[id];
	uv = uv * transform.xy + transform.zw;
	dd *= transform.xyxy;
	vec3 uvw = vec3(uv, float(id));
	alb = textureGrad(_texture_array_albedo, uvw, dd.xy, dd.zw);
	vec4 surface = textureGrad(_texture_array_normal, uvw, dd.xy, dd.zw);
	vec2 xy = surface.rg * 2. - 1.;
	vec3 n = normalize(vec3(xy, sqrt(max(1. - dot(xy, xy), 0.))));
	n.xy *= sign(transform.xy);
	nrm = vec4(n.xzy, clamp(surface.b + _texture_roughness_mod_array[id], 0., 1.));
	ao = 1.;
	emission = vec3(0.);
	if (_texture_auxiliary_indices[id] >= 0.) {
		vec4 auxiliary = textureGrad(_texture_array_emission, vec3(uv, _texture_auxiliary_indices[id]), dd.xy, dd.zw);
		ao = auxiliary.a;
		emission = auxiliary.rgb * _texture_material_properties[id].x;
	}
	float material_weight = _texture_material_weights[id];
	if (material_weight < .5) {
		// Legacy AO strength/height response is preserved after decoding at bake time.
		ao = mix(ao * _texture_ao_strength_array[id] + 1. - _texture_ao_strength_array[id], 1., alb.a * alb.a);
	}
	pbr = vec3(surface.a, _texture_material_properties[id].y * material_weight, material_weight);
	alb.rgb *= _texture_color_array[id].rgb;
}
)"
