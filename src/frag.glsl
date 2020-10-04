#version 450 core
#extension GL_ARB_bindless_texture : require
#extension GL_ARB_gpu_shader5 : require

#define Prim_Kind_Invalid       0
#define Prim_Kind_Rect          1
#define Prim_Kind_Rect_Textured 2
#define Prim_Kind_Poincare 16
#define Prim_Kind_Entity 17
#define Prim_Kind_Menu_Poincare 18


#define PI  3.14159265
#define TAU 6.28318531

#define ARENA_RADIUS 0.862

layout(location=1) uniform float u_time;

#if 1
#define N 5
#define Q 4
#elif 0
#define N 3
#define Q 8
#else
#define N 4
#define Q 5
#endif

in flat uint v_prim_kind;

in vec2 v_position;
in vec2 v_position_ss;
in vec2 v_size;
in vec4 v_colour;
in vec2 v_uv;

in vec2 v_epos;
in float v_erot;
in flat uint v_ekind;
in flat uint v_vcount;
in flat uvec2 v_sampler;
in flat uint v_texture_id;

out vec4 o_colour;


mat2 rot2(in float a) {
	float c = cos(a);
	float s = sin(a);
	return mat2(c, -s, s, c);
}

float hasher(in vec2 p) {
	return fract(111231 * sin(dot(p, vec2(127, 63))));
}

void swap(inout int a, inout int b) {
	int tmp = a; a = b; b = tmp;
}

float smooth_floor(float x, float c) {

    float ix = floor(x);
    x -= ix;
    return (pow(x, c) - pow(1.0- x, c))*0.5 + ix;
}


vec3 init_domain() {
	float pi_div_n = PI/float(N);
	float pi_div_q = pi_div_n + PI/float(Q) - PI*0.5;

	vec2 t1 = vec2(cos(pi_div_n), sin(pi_div_n));
	vec2 t2 = vec2(cos(pi_div_q), sin(pi_div_q));

	float dist = t1.x - t2.x*t1.y/t2.y;
	float r = length(vec2(dist, 0) - t1);

	float d = max(dist*dist - r*r, 0.0);

	return vec3(dist, r, 1)/sqrt(d);
}

vec2 transform(vec2 p, vec2 circ, inout float count) {
	float ia = (floor(atan(p.x, p.y)/TAU*float(N)) + 0.5)/float(N);
	vec2 vert = rot2(ia*TAU)*vec2(0, circ.x);
	float r2 = circ.y*circ.y;
	vec2 pc = p - vert;
	float l2 = dot(pc, pc);
	if (l2 < r2) {
		p = pc*r2/l2 + vert;
		p = rot2(TAU/float(N)*(count + float(Q)))*p;
		count++;
	}
	return p;
}

float sdf_bezier(vec2 pos, vec2 A, vec2 B, vec2 C) {
	vec2 a = B - A;
	vec2 b = A - 2.0*B + C;
	vec2 c = a * 2.0;
	vec2 d = A - pos;

	float kk = 1.0/max(dot(b,b), 1e-6);
	float kx = kk * dot(a,b);
	float ky = kk * (2.0*dot(a,a)+dot(d,b)) / 3.0;
	float kz = kk * dot(d,a);

	float res = 0.0;

	float p = ky - kx*kx;
	float p3 = p*p*p;
	float q = kx*(2.0*kx*kx - 3.0*ky) + kz;
	float h = q*q + 4.0*p3;

	if (h >= 0.0) {
		h = sqrt(h);
		vec2 x = (vec2(h, -h) - q) * 0.5;
		vec2 uv = sign(x)*pow(abs(x), vec2(1.0/3.0));
		float t = uv.x + uv.y - kx;
		t = clamp(t, 0.0, 1.0);

		// 1 root
		vec2 qos = d + (c + b*t)*t;
		res = length(qos);
	} else {
		float z = sqrt(-p);
		float v = acos( q/(p*z*2.0) ) / 3.0;
		float m = cos(v);
		float n = sin(v)*1.732050808;
		vec3 t = vec3(m + m, -n - m, n - m) * z - kx;
		t = clamp(t, 0.0, 1.0);

		// 3 roots
		vec2 qos = d + (c + b*t.x)*t.x;
		float dis = dot(qos,qos);

		res = dis;

		qos = d + (c + b*t.y)*t.y;
		dis = dot(qos,qos);
		res = min(res,dis);

		qos = d + (c + b*t.z)*t.z;
		dis = dot(qos,qos);
		res = min(res,dis);

		res = sqrt(res);
	}

	return res;
}

float do_line_segment(vec2 p, vec4 a, vec4 b, float r) {
    vec2 mid = mix(a.xy, b.xy, 0.5);

    p = rot2(cos(u_time*0.05)) * p;

    float l = length(b.xy - a.xy)*1.732/6.0;
    if (abs(length(b.zw - a.zw)) < 0.01) {
    	l = r;
    }
    mid += mix(a.zw, b.zw, 0.5)*l;
    float b1 = sdf_bezier(p, a.xy, a.xy + a.zw*l, mid);
    float b2 = sdf_bezier(p, mid, b.xy + b.zw*l, b.xy);
    return min(b1, b2);
}


vec2 inversion(in vec2 uv, vec2 p) {
	// STUPID SINGULARITIES
	if (length(p) < 0.05) {
		p += 0.05;
	}
	if (abs(p.x) > 0.95*sqrt(2.0) || abs(p.y) > 0.95*sqrt(2.0)) {
		p *= 0.95;
	}

	float k = 1.0/dot(p, p);
	vec2 ip = k*p;
	float t = (k - 1.0)/dot(uv - ip, uv - ip);
	uv = t*uv + (1.0 - t)*ip;
	uv.x = -uv.x; // preserve chirality

	return uv;
}

float polygon(vec2 p, float vertices, float radius, float rot_angle) {
    float segment_angle = TAU/vertices;
    float angle = atan(p.x, p.y) + rot_angle;
    float repeat = mod(angle, segment_angle) - segment_angle*0.5;
    float inner_radius = radius * cos(segment_angle*0.5);
    float circle = length(p);
    return cos(repeat) * circle - inner_radius;

}

vec3 poincare_truchet(vec2 uv) {
	uv *= 1.1;

	vec2 p = uv;

	vec2 op = p;

	{
		vec2 m = vec2(0, 0);
		float t = u_time;
		m.x = 0.8*cos(t*0.003);
		m.y = 0.8*sin(t*0.003);
		if (length(uv) < 1) {
			// m = vec2(0, 0);
		}
		p = inversion(p, m);
	}

	float count = 0.0;

	vec3 domain_info = init_domain();

	for (int i = 0; i < 12; i++) {
		p = transform(p, domain_info.xy, count);
	}
	if (length(p) > 1.0) {
		p /= dot(p, p);
	}

	p /= domain_info.z;


	float shape = polygon(p, float(N), 0.9, 0);

	vec2 vertex_points[N];
	float line_points[N];

	const int N2 = N*2;
	vec4 mp[N2];
	int shuff[N2];

	float vert = 1e6;
	vec2 v0 = vec2(0, 1);

	for (int i = 0; i < N; i++) {
		vert = min(vert, length(p - v0) - 0.09);
		vertex_points[i] = v0;
		v0 = rot2(TAU/float(N)) * v0;
	}

	vec2 rp = rot2(float(count + 2.0) *  TAU/float(N)) * p;
	float angle = mod(atan(rp.x, rp.y), TAU) * float(N2) / TAU;
	float polygon_seg = (smooth_floor(angle, 0.01) + 0.5) / float(N2);

	vec3 col_scheme = vec3(1);
	col_scheme = 0.4 + 0.6*cos(polygon_seg*TAU + vec3(1, 2, 3));


	float smoothing_factor = 0.01;

	vec3 col = vec3(1.00, 1.00, 1.00);
	col = mix(col, vec3(0), 1.0 - smoothstep(0.0, smoothing_factor, shape));
	col = mix(col, col_scheme, 1.0 - smoothstep(0.0, smoothing_factor, shape + 0.05));
	col = pow(col, vec3(1.0/2.2));


	float side_length = length(vertex_points[0] - vertex_points[1]);

	for (int i = 0; i < N; i++) {
		shuff[i*2] = i*2;
		shuff[i*2 + 1] = i*2 + 1;

		vec2 mpi = mix(vertex_points[i], vertex_points[(i + 1)%N], 0.5);
		vec2 tangent_i = normalize(mpi - vertex_points[i]);

		mp[i*2].xy     = mpi - tangent_i*side_length/6.0;
		mp[i*2 + 1].xy = mpi + tangent_i*side_length/6.0;

		mp[i*2].zw     = tangent_i.yx * vec2(1, -1);
		mp[i*2 + 1].zw = tangent_i.yx * vec2(1, -1);
	}

	for (int i = N2 - 1; i > 0; i--) {
		float fi = float(i);
		float rs = hasher(vec2(count) + domain_info.xy + domain_info.z + fi/float(N2));
		int j = int(floor(rs*(fi + 0.9999)));
		swap(shuff[i], shuff[j]);
	}

	for (int i = 0; i < N; i++) {
		int j = shuff[i*2];
		int jp = shuff[i*2 + 1];

		float line_off = side_length*1.0;
		line_points[i] = do_line_segment(p, mp[j], mp[jp], line_off) - 0.03;
	}


	float ring_blend = smoothstep(0.0, 0.2, abs(length(uv) - 1.0) - 0.1);
	float pat = abs(fract(shape*12.0) - 0.5)*2.0 - 0.05;
	col = mix(col, vec3(0), ring_blend*(1.0 - smoothstep(0.0, 0.5, pat))*0.7);

	float lu = length(uv);

	for (int i = 0; i < N; i++) {
		pat = abs(fract(line_points[i]*12.0 + 0.5) - 0.5)*2 - 0.05;
		pat = mix(1.0, 0.0, ring_blend*(1.0 - smoothstep(0.0, 0.5, pat))*0.7);

		vec3 bg_col = col;
		vec3 c0 = col;
		c0 = mix(c0, vec3(0.0), 1.0 - smoothstep(0.0, smoothing_factor, line_points[i]));
		col = mix(col, c0, 1.0-step(length(uv), 1.0));
	}


	float ring = abs(lu - 1.0) - 0.05;


	col = mix(col, vec3(0), 1.0 - smoothstep(0.0, smoothing_factor*0.5, ring));

	col = abs(col);
	float coln = (col.r+col.g+col.b)/3.0;
	if (coln > 1) {
		col *= 1.0/coln;
	}

	// NOTE: Black and white on the inside
	if (dot(uv, uv) <= 1.0) {
		float x = max(max(col.r, col.g), col.b);
		col = vec3(x);
	}

	return col;
}

#define Prim_Entity_Invalid    0
#define Prim_Entity_Player     1
#define Prim_Entity_Projectile 2
#define Prim_Entity_Enemy      3

#define PLAYER_RADIUS 0.05
#define PROJECTILE_RADIUS 0.02
#define ENEMY_RADIUS_BASE 0.02


float sdf_segment(in vec2 p, in vec2 a, in vec2 b, in float r) {
	vec2 pa = p-a;
	vec2 ba = b-a;
	float h = clamp(dot(pa, ba)/dot(ba, ba), 0.0, 1.0);
	return step(length(pa - ba*h), r);
}

void render_entity(inout vec4 colour, in vec2 uv, in vec2 pos, in float rot, in uint kind) {
	float r = 0.0;
	float vertices = float(v_vcount);
	vec2 p = inversion(uv, pos);
	float d = 0;
	switch (kind) {
	case Prim_Entity_Player:
		r = PLAYER_RADIUS;
		d = polygon(p, vertices, r, rot);
		break;
	case Prim_Entity_Projectile:
		r = PROJECTILE_RADIUS;
		d = polygon(p, vertices, r, rot);
		break;
	case Prim_Entity_Enemy:
		r = ENEMY_RADIUS_BASE * pow(vertices-3+1, 0.2);
		d = polygon(p, vertices, r, rot);
		break;
	default:
		return;
	}


	vec3 c = v_colour.rgb;
	colour.rgb = mix(colour.rgb, vec3(0), step(d, r));
	colour.rgb = mix(colour.rgb, c, step(d, 0.86*r));
	colour.a = mix(colour.a, v_colour.a, step(d, r));

	if (kind == Prim_Entity_Player) {
		vec2 fire_dir = vec2(cos(rot), sin(rot));
		fire_dir = normalize(inversion(pos + fire_dir*PLAYER_RADIUS, pos));
		vec2 a = pos;
		vec2 b = pos + fire_dir*PLAYER_RADIUS*2;
		float d = sdf_segment(uv, a, b, 0.005);
		colour.rgb = mix(colour.rgb, vec3(0.1, 1, 0.2), d);
		colour.a = mix(colour.a, 1, d);
	}
}


vec3 psychedelic_text(vec2 uv) {
	uv = sin(uv*19.0) + cos(uv*13.0);

	vec3 col = 0.5 + 0.5*sin(PI * (1.2*uv.x+1.7*uv.y + u_time) + vec3(0.0, +2.0, -2.0));
	col /= max(max(col.r, col.g), col.b);
	col = pow(col, vec3(0.05));
	return col;
}

vec3 menu_truchet(vec2 uv) {
	uv *= 1.1;

	vec2 p = uv;

	vec2 op = p;

	{
		vec2 m = vec2(0, 0);
		float t = u_time;
		m.x = 0.8*cos(t*0.003);
		m.y = 0.8*sin(t*0.003);
		if (length(uv) < 1) {
			// m = vec2(0, 0);
		}
		p = inversion(p, m);
	}

	float count = 0.0;

	vec3 domain_info = init_domain();

	for (int i = 0; i < 12; i++) {
		p = transform(p, domain_info.xy, count);
	}
	if (length(p) > 1.0) {
		p /= dot(p, p);
	}

	p /= domain_info.z;


	float shape_r = 0;
	shape_r = 0.9;;
	float shape = polygon(p, float(N), shape_r, 0);

	vec2 vertex_points[N];
	float line_points[N];

	const int N2 = N*2;
	vec4 mp[N2];
	int shuff[N2];

	float vert = 1e6;
	vec2 v0 = vec2(0, 1);

	for (int i = 0; i < N; i++) {
		vert = min(vert, length(p - v0) - 0.09);
		vertex_points[i] = v0;
		v0 = rot2(TAU/float(N)) * v0;
	}

	vec2 rp = rot2(float(count + 2.0) *  TAU/float(N)) * p;
	float angle = mod(atan(rp.x, rp.y), TAU) * float(N2) / TAU;
	float polygon_seg = (smooth_floor(angle, 0.01) + 0.5) / float(N2);

	vec3 col_scheme = vec3(1);
	col_scheme = 0.4 + 0.6*cos(polygon_seg*TAU + vec3(1, 2, 3));

	float smoothing_factor = 0.01;

	vec3 col = vec3(1.00, 1.00, 1.00);
	col = mix(col, vec3(0), 1.0 - smoothstep(0.0, smoothing_factor, shape));
	col = mix(col, col_scheme, 1.0 - smoothstep(0.0, smoothing_factor, shape + 0.05));
	col = pow(col, vec3(1.0/2.2));


	float side_length = length(vertex_points[0] - vertex_points[1]);

	for (int i = 0; i < N; i++) {
		shuff[i*2] = i*2;
		shuff[i*2 + 1] = i*2 + 1;

		vec2 mpi = mix(vertex_points[i], vertex_points[(i + 1)%N], 0.5);
		vec2 tangent_i = normalize(mpi - vertex_points[i]);

		mp[i*2].xy     = mpi - tangent_i*side_length/6.0;
		mp[i*2 + 1].xy = mpi + tangent_i*side_length/6.0;

		mp[i*2].zw     = tangent_i.yx * vec2(1, -1);
		mp[i*2 + 1].zw = tangent_i.yx * vec2(1, -1);
	}

	for (int i = N2 - 1; i > 0; i--) {
		float fi = float(i);
		float rs = hasher(vec2(count) + domain_info.xy + domain_info.z + fi/float(N2));
		int j = int(floor(rs*(fi + 0.9999)));
		swap(shuff[i], shuff[j]);
	}

	for (int i = 0; i < N; i++) {
		int j = shuff[i*2];
		int jp = shuff[i*2 + 1];

		float line_off = side_length*1.0;
		line_points[i] = do_line_segment(p, mp[j], mp[jp], line_off) - 0.03;
	}


	float ring_blend = smoothstep(0.0, 0.2, abs(length(uv) - 1.0) - 0.1);
	float pat = abs(fract(shape*12.0) - 0.5)*2.0 - 0.05;
	col = mix(col, vec3(0), ring_blend*(1.0 - smoothstep(0.0, 0.5, pat))*0.7);

	float lu = length(uv);

	for (int i = 0; i < N; i++) {
		pat = abs(fract(line_points[i]*12.0 + 0.5) - 0.5)*2 - 0.05;
		pat = mix(1.0, 0.0, ring_blend*(1.0 - smoothstep(0.0, 0.5, pat))*0.7);

		vec3 bg_col = col;
		vec3 c0 = col;
		c0 = mix(c0, vec3(0.0), 1.0 - smoothstep(0.0, smoothing_factor, line_points[i]));
		col = mix(col, c0, 1.0-step(length(uv), 1.0));
	}


	float ring = abs(lu - 1.0) - 0.05;

	col = mix(col, vec3(0), 1.0 - smoothstep(0.0, smoothing_factor*0.5, ring));

	col = abs(col);
	float coln = (col.r+col.g+col.b)/3.0;
	if (coln > 1) {
		col *= 1.0/coln;
	}

	col = pow(col, vec3(2));

	return col;
}

void main() {
	vec4 colour = v_colour;
	vec2 uv = v_uv;

	colour *= texture(sampler2D(v_sampler), uv).rgba;

	if (v_prim_kind == Prim_Kind_Menu_Poincare) {
		colour.rgb *= menu_truchet(uv);
	} else if (v_prim_kind == Prim_Kind_Poincare) {
		colour.rgb *= poincare_truchet(uv);
	} else if (v_prim_kind == Prim_Kind_Entity) {
		colour = vec4(0);
		if (length(uv) <= ARENA_RADIUS) {
			render_entity(colour, uv, v_epos, v_erot, v_ekind);
			render_entity(colour, uv, v_epos - normalize(v_epos)*2*ARENA_RADIUS, v_erot, v_ekind);
		}
	} else if (v_texture_id == 2) {
		colour.rgb *= psychedelic_text(v_position_ss);
	}



	o_colour = colour;
}
