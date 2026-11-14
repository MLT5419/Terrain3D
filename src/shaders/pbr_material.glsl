// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(
//INSERT: PBR_MATERIAL_UNIFORMS
uniform vec2 _texture_material_indices[32]; // x: PBR layer, y: optional emission/AO layer; -1: absent
uniform vec4 _texture_material_uvs[32]; // UV scale.xy, offset.xy
uniform vec2 _texture_material_properties[32]; // emission scale, specular
uniform highp sampler2DArray _material_array_albedo : source_color, FILTER_METHOD, repeat_enable;
uniform highp sampler2DArray _material_array_surface : FILTER_METHOD, repeat_enable;

//INSERT: PBR_MATERIAL_FRAGMENT_UNIFORMS
uniform highp sampler2DArray _material_array_emission : source_color, FILTER_METHOD, repeat_enable;

//INSERT: PBR_MATERIAL_HEIGHT_FUNCTIONS
float sample_terrain_height(int id, vec2 uv) {
	if (_texture_material_indices[id].x >= 0.) {
		uv = uv * _texture_material_uvs[id].xy + _texture_material_uvs[id].zw;
		return textureLod(_material_array_albedo, vec3(uv, _texture_material_indices[id].x), 0.).a;
	}
	return textureLod(_texture_array_albedo, vec3(uv, float(id)), 0.).a;
}

vec3 sample_terrain_displacement_normal(int id, vec2 uv) {
	if (_texture_material_indices[id].x >= 0.) {
		uv = uv * _texture_material_uvs[id].xy + _texture_material_uvs[id].zw;
		vec2 xy = textureLod(_material_array_surface, vec3(uv, _texture_material_indices[id].x), 0.).rg * 2. - 1.;
		vec3 n = normalize(vec3(xy, sqrt(max(1. - dot(xy, xy), 0.))));
		n.xy *= sign(_texture_material_uvs[id].xy);
		return n.xzy;
	}
	return textureLod(_texture_array_normal, vec3(uv, float(id)), 0.).xzy * 2. - 1.;
}
)"
R"(
//INSERT: PBR_MATERIAL_FRAGMENT_FUNCTIONS
void sample_terrain_layer(int id, vec2 uv, vec4 dd, out vec4 alb, out vec4 nrm,
		out float ao, out vec3 pbr, out vec3 emission) {
	pbr = vec3(0.);
	emission = vec3(0.);
	if (_texture_material_indices[id].x >= 0.) {
		vec4 transform = _texture_material_uvs[id];
		uv = uv * transform.xy + transform.zw;
		dd *= transform.xyxy;
		vec3 uvw = vec3(uv, _texture_material_indices[id].x);
		alb = textureGrad(_material_array_albedo, uvw, dd.xy, dd.zw);
		vec4 surface = textureGrad(_material_array_surface, uvw, dd.xy, dd.zw);
		vec2 xy = surface.rg * 2. - 1.;
		vec3 n = normalize(vec3(xy, sqrt(max(1. - dot(xy, xy), 0.))));
		n.xy *= sign(transform.xy);
		nrm = vec4(n.xzy, surface.b);
		ao = 1.;
		if (_texture_material_indices[id].y >= 0.) {
			vec4 auxiliary = textureGrad(_material_array_emission, vec3(uv, _texture_material_indices[id].y), dd.xy, dd.zw);
			ao = auxiliary.a;
			emission = auxiliary.rgb * _texture_material_properties[id].x;
		}
		pbr = vec3(surface.a, _texture_material_properties[id].y, 1.);
	} else {
		alb = textureGrad(_texture_array_albedo, vec3(uv, float(id)), dd.xy, dd.zw);
		nrm = textureGrad(_texture_array_normal, vec3(uv, float(id)), dd.xy, dd.zw);
		nrm.a = clamp(nrm.a + _texture_roughness_mod_array[id], 0., 1.);
		nrm.xyz = nrm.xzy * 2. - 1.;
		ao = length(nrm.xyz) * 2. - 1.;
		ao = mix(ao * ao * _texture_ao_strength_array[id] + 1. - _texture_ao_strength_array[id], 1., alb.a * alb.a);
		nrm.xyz = normalize(nrm.xyz);
	}
	alb.rgb *= _texture_color_array[id].rgb;
}
)"
