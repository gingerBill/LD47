#version 450 core
#extension GL_ARB_bindless_texture : require
#extension GL_ARB_gpu_shader5 : require

#define Prim_Kind_Invalid       0
#define Prim_Kind_Rect          1
#define Prim_Kind_Rect_Textured 2
#define Prim_Kind_Poincare 16
#define Prim_Kind_Entity 17
#define Prim_Kind_Menu_Poincare 18

layout(location=0) uniform vec4 u_screen_rect; // x y w h

layout(std430, binding=0) buffer Buffer_Float {
	readonly restrict float buffer_float[];
};

layout(binding=0) uniform Samplers {
	uvec4 u_samplers[128];
};

out flat uint v_prim_kind;

out vec2 v_position_origin;
out vec2 v_position;
out vec2 v_position_ss;
out vec2 v_size;
out vec4 v_colour;
out vec2 v_uv;
out flat uvec2 v_sampler;
out flat uint v_texture_id;

out vec2 v_epos;
out float v_erot;
out flat uint v_ekind;
out flat uint v_vcount;


vec2 corner_to_vec2(in uint corner) {
	/*
		0 = vec2(0, 0)
		1 = vec2(1, 0)
		2 = vec2(1, 1)
		3 = vec2(0, 1)
	 */
	return round(fract(float(corner) * 0.25 + vec2(0.125, 0.375)));
}




void main() {
	uint vertex = gl_VertexID;
	uint prim_kind = bitfieldExtract(vertex, 0, 6);
	uint extra     = bitfieldExtract(vertex, 6, 2);
	uint data_pos  = bitfieldExtract(vertex, 8, 24);

	vec2 position = vec2(0, 0);
	vec4 colour = vec4(1, 1, 1, 1);
	vec2 uv = vec2(0, 0);
	uint texture_id = 0;

	v_prim_kind = prim_kind;

	if (prim_kind == Prim_Kind_Invalid) {
		// DO NOWT
	} else if (prim_kind == Prim_Kind_Rect) {
		uint corner = extra;
		vec2 pos  = vec2(buffer_float[data_pos+0], buffer_float[data_pos+1]);
		vec2 size = vec2(buffer_float[data_pos+2], buffer_float[data_pos+3]);
		uint col  = floatBitsToUint(buffer_float[data_pos+4]);
		colour = unpackUnorm4x8(col);

		vec2 cc = corner_to_vec2(corner);
		position = pos + cc*size;

		v_position_origin = pos;
		v_size = size;
	} else if (prim_kind == Prim_Kind_Rect_Textured) {
		uint corner = extra;
		vec2 pos  = vec2(buffer_float[data_pos+0], buffer_float[data_pos+1]);
		vec2 size = vec2(buffer_float[data_pos+2], buffer_float[data_pos+3]);
		vec2 uv0  = vec2(buffer_float[data_pos+4], buffer_float[data_pos+5]);
		vec2 uv1  = vec2(buffer_float[data_pos+6], buffer_float[data_pos+7]);
		uint col  = floatBitsToUint(buffer_float[data_pos+8]);
		colour = unpackUnorm4x8(col);
		texture_id = floatBitsToUint(buffer_float[data_pos+9]);
		vec2 cc = corner_to_vec2(corner);
		position = pos + cc*size;
		v_position_origin = pos;
		v_size = size;
		v_uv = mix(uv0, uv1, cc);
	} else if (prim_kind == Prim_Kind_Poincare || prim_kind == Prim_Kind_Menu_Poincare) {
		uint corner = extra;
		vec2 pos  = vec2(buffer_float[data_pos+0], buffer_float[data_pos+1]);
		vec2 size = vec2(buffer_float[data_pos+2], buffer_float[data_pos+3]);

		vec2 cc = corner_to_vec2(corner);
		position = pos + cc*size;

		v_position_origin = pos;
		v_size = size;
		v_uv = cc*2 - 1;
		if (size.x < size.y) {
			v_uv.y *= size.y/size.x;
		} else {
			v_uv.x *= size.x/size.y;
		}
	} else if (prim_kind == Prim_Kind_Entity) {
		uint corner = extra;
		vec2 pos  = vec2(buffer_float[data_pos+0], buffer_float[data_pos+1]);
		vec2 size = vec2(buffer_float[data_pos+2], buffer_float[data_pos+3]);
		vec2 epos = vec2(buffer_float[data_pos+4], buffer_float[data_pos+5]);
		float erot = buffer_float[data_pos+6];
		uint col  = floatBitsToUint(buffer_float[data_pos+7]);
		colour = unpackUnorm4x8(col);
		uint ekind_and_vcount = floatBitsToUint(buffer_float[data_pos+8]);
		uint ekind  = bitfieldExtract(ekind_and_vcount, 0, 16);
		uint vcount = bitfieldExtract(ekind_and_vcount, 16, 16);

		vec2 cc = corner_to_vec2(corner);
		position = pos + cc*size;

		v_position_origin = pos;
		v_size = size;
		v_uv = cc*2 - 1;
		if (size.x < size.y) {
			v_uv.y *= size.y/size.x;
		} else {
			v_uv.x *= size.x/size.y;
		}

		v_epos = epos;
		v_erot = erot;
		v_ekind = ekind;
		v_vcount = vcount;
	}


	float L = u_screen_rect.x;
	float T = u_screen_rect.y;
	float R = u_screen_rect.x + u_screen_rect.z;
	float B = u_screen_rect.y + u_screen_rect.w;

	mat4 ortho_projection = mat4(
		2.0/(R-L), 0.0, 0.0, 0.0,
		0.0, 2.0/(T-B), 0.0, 0.0,
		0.0, 0.0,       1.0, 0.0,
		(R+L)/(L-R), (T+B)/(B-T), 0.0, 1.0
	);

	v_position = position;
	v_colour   = colour;
	v_sampler = u_samplers[texture_id].xy;
	v_texture_id = texture_id;

	vec4 position_ss = ortho_projection * vec4(position, 0, 1);
	v_position_ss = position_ss.xy / position_ss.w;
	gl_Position = position_ss;
}
