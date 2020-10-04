package ld47

import "core:os"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:math"
import "core:runtime"
import "core:math/linalg"
import "core:math/rand"
import glfw "shared:glfw"
import gl "shared:odin-gl"

cfmt :: proc(format: string, args: ..any) -> cstring {
	str := fmt.tprintf(format, ..args);
	return strings.unsafe_string_to_cstring(str);
}

GAME_TITLE :: "Hyperbolic Space Fighters Extreme!";
CREDITS_NAME :: "Ginger Bill";
CREDITS_COMPO :: "Ludum Dare Forty Seven";

vertex_shader   := string(#load("vert.glsl"));
fragment_shader := string(#load("frag.glsl"));

VERTEX_BUFFER_LEN :: 1<<20;
PRIMITIVE_BUFFER_SIZE_IN_BYTES :: 1<<24;

vao: u32;
ebo: u32;
prim_ssbo: u32;
texture_ubo: u32;
program: u32;

camera_pos: [2]f32;
player_pos := [2]f32{0, 0};
player_angle := f32(math.TAU*0.125);
MAX_PLAYER_HEALTH :: 100;
player_health := f32(MAX_PLAYER_HEALTH);
player_score: i32;

PLAYER_RADIUS :: 0.05;
PROJECTILE_RADIUS :: 0.02;
ENEMY_BASE_RADIUS :: 0.02;
PROJECTILE_LIFETIME :: 3.0;

PLAYER_COLOUR     :: Colour{255, 128, 0, 255};
PROJECTILE_COLOUR :: Colour{255, 0, 0, 255};
ENEMY_COLOUR      :: Colour{13, 54, 240, 255};


PROJECTILE_SPAWN_RATE :: 0.2;
last_projectime_time: f64 = -PROJECTILE_SPAWN_RATE;


Enemy :: struct {
	pos:    [2]f32,
	vel:    [2]f32,
	rot:    f32,
	health: i32, // vertices = health + 2
	marked_to_be_split: b32,
}

Projectile :: struct {
	pos: [2]f32,
	vel: [2]f32,
	rot: f32,
	spawn_time: f32,
}


Game_State :: enum {
	Menu_Main,
	Game,
	Paused,
	Death,
}


game_state: Game_State;

enemies:     [dynamic]Enemy;
projectiles: [dynamic]Projectile;


prev_time: f64;
curr_time: f64;


render_draw_list :: proc(window: glfw.Window_Handle, dl: ^Draw_List, w, h: f32) {
	aspect_ratio := f32(max(w, 1))/f32(max(h, 1));

	gl.Viewport(0, 0, i32(w), i32(h));
	gl.ClearColor(1.0, 1.0, 1.0, 1.0);
	gl.Clear(gl.COLOR_BUFFER_BIT);

	gl.Enable(gl.BLEND);
	gl.BlendEquation(gl.FUNC_ADD);
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
	gl.Disable(gl.CULL_FACE);
	gl.Disable(gl.DEPTH_TEST);

	gl.BindVertexArray(vao);

	vertex_bufer_size_in_bytes := size_of(Vertex)*min(dl.vertex_len, len(dl.vertex_buffer));
	primitive_buffer_size_in_bytes := min(dl.primitive_size, len(dl.primitive_buffer));

	gl.NamedBufferSubData(ebo,  0, vertex_bufer_size_in_bytes,     raw_data(dl.sorted_vertex_buffer));
	gl.NamedBufferSubData(prim_ssbo, 0, primitive_buffer_size_in_bytes, raw_data(dl.primitive_buffer));
	gl.NamedBufferSubData(texture_ubo,  0, size_of(g_textures),            &g_textures);

	gl.BindBuffer(gl.ARRAY_BUFFER, 0);
	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo);
	gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, prim_ssbo);
	gl.BindBuffer(gl.UNIFORM_BUFFER, texture_ubo);

	gl.UseProgram(program);
	gl.Uniform4f(gl.GetUniformLocation(program, "u_screen_rect"), camera_pos.x, camera_pos.y, w, h);
	gl.Uniform1f(gl.GetUniformLocation(program, "u_time"), f32(glfw.GetTime())); // use the real world time for animations
	// gl.Uniform4f(gl.GetUniformLocation(program, "u_screen_rect"), camera_pos.x, camera_pos.y, camera_zoom*aspect_ratio, camera_zoom);

	gl.DrawElements(gl.TRIANGLES, i32(dl.vertex_len), gl.UNSIGNED_INT, nil);
}

spawn_projectile :: proc(instant: bool) {
	if len(projectiles) == cap(projectiles) {
		return;
	}
	dt := curr_time - last_projectime_time;
	if dt < PROJECTILE_SPAWN_RATE {
		return;
	}
	last_projectime_time = curr_time;

	fire_dir := [2]f32{math.cos(player_angle), math.sin(player_angle)};
	fire_dir = linalg.normalize0(inversion(player_pos + fire_dir*PLAYER_RADIUS, player_pos));

	p: Projectile;
	p.pos = player_pos + fire_dir*PLAYER_RADIUS;
	p.vel = fire_dir * 2.0;
	p.spawn_time = f32(curr_time);

	append(&projectiles, p);
}

rand_pos :: proc(init_pos := [2]f32{0, 0}) -> (pos: [2]f32) {
	r := rand.float32_range(0.3, 0.9);
	t := rand.float32_range(0.0, math.TAU);
	pos.x = r*math.cos(t);
	pos.y = r*math.sin(t);
	pos +=  init_pos;
	return bound_position(pos);
}

spawn_enemy :: proc(pos: [2]f32, health: Maybe(i32) = nil) {
	if len(enemies) >= 256 {
		return;
	}

	e: Enemy;
	e.pos = pos;
	e.vel.x = f32(rand.norm_float64());
	e.vel.y = f32(rand.norm_float64());
	e.vel = linalg.normalize0(e.vel);
	e.vel *= rand.float32_range(0.1, 0.4);
	e.rot = rand.float32_range(0, math.TAU);
	if health != nil {
		e.health = health.?;
	} else {
		e.health = 3 + rand.int31_max(5);
	}

	append(&enemies, e);
}


inversion :: proc(uv, p: [2]f32) -> [2]f32 {
	uv, p := uv, p;
	if linalg.length(p) < 0.05 {
		p += 0.05;
	}
	if abs(p.x) > 0.98*math.SQRT_TWO || abs(p.y) > 0.98*math.SQRT_TWO {
		p *= 0.98;
	}

	k := 1.0/linalg.dot(p, p);
	ip := k*p;
	t := (k - 1.0)/linalg.dot(uv - ip, uv - ip);
	uv = t*uv + (1.0 - t)*ip;
	uv.x = -uv.x; // preserve chirality
	return uv;
}

ARENA_RADIUS :: 0.862;

bound_position :: proc(pos: [2]f32) -> [2]f32 {
	d := linalg.length(pos);
	if d > ARENA_RADIUS {
		return (math.mod(d, ARENA_RADIUS)-ARENA_RADIUS) * linalg.normalize0(pos);
	}
	return pos;
}


update_hyperbolic_position :: proc(pos, vel: [2]f32, dt: f32) -> (new_pos, new_vel: [2]f32) {
	p0 := pos;
	v0 := vel;

	step := v0 * dt;
	if linalg.length(p0) < 0.1 {
		new_pos = bound_position(p0 + step);
		new_vel = v0;
		return;
	}


	p1, v1 := p0, v0;
	vn := linalg.length(v0);

	r := linalg.length(p0);

	p1[0] += math.cosh(p0[0])*step[0] / (1 + math.sinh(r));
	p1[1] += math.cosh(p0[1])*step[1] / (1 + math.sinh(r));

	p1[0] += vn*math.sinh(step[0]);
	p1[1] += vn*math.sinh(step[1]);


	dp := linalg.normalize0(p1-p0);
	new_vel = dp*vn;
	new_pos = bound_position(p0 + new_vel*dt);
	return;
}

update_game :: proc(window: glfw.Window_Handle, dt: f32) {
	switch game_state {
	case .Menu_Main:
		if glfw.JoystickIsGamepad(0) {
			// NOTE(bill): assume XBox controller
			state: glfw.Gamepad_State;
			glfw.GetGamepadState(0, &state);
			for b in state.buttons {
				if b {
					game_state = .Game;
					break;
				}
			}
		}
	case .Paused:
		return;
	case .Game, .Death:
		// Okay
	case:
		return;
	}

	@static random_enemy_timer: f32;
	random_enemy_timer += dt;

	if random_enemy_timer > 6.0 {
		if abs(f32(rand.norm_float64())) > 2.0 {
			spawn_enemy(rand_pos(player_pos));
			random_enemy_timer = 0;
		}
	} else if len(enemies) == 0 {
		for i in 0..<3 {
			spawn_enemy(rand_pos());
		}
	}

	if game_state == .Game { // player
		move_dir: [2]f32;
		if glfw.GetKey(window, glfw.KEY_W) { move_dir.y -= 1; }
		if glfw.GetKey(window, glfw.KEY_S) { move_dir.y += 1; }
		if glfw.GetKey(window, glfw.KEY_A) { move_dir.x -= 1; }
		if glfw.GetKey(window, glfw.KEY_D) { move_dir.x += 1; }

		if glfw.GetKey(window, glfw.KEY_UP)    { move_dir.y -= 1; }
		if glfw.GetKey(window, glfw.KEY_DOWN)  { move_dir.y += 1; }
		if glfw.GetKey(window, glfw.KEY_LEFT)  { move_dir.x -= 1; }
		if glfw.GetKey(window, glfw.KEY_RIGHT) { move_dir.x += 1; }

		move_dir = linalg.normalize0(move_dir);

		if glfw.JoystickIsGamepad(0) {
			// NOTE(bill): assume XBox controller
			state: glfw.Gamepad_State;
			glfw.GetGamepadState(0, &state);
			dp := [2]f32{state.axes[0], state.axes[1]};
			if linalg.length(dp) > 0.1 {
				move_dir += dp;
			}
			if state.buttons[11] { move_dir.y -= 1.0; }
			if state.buttons[12] { move_dir.x += 1.0; }
			if state.buttons[13] { move_dir.y += 1.0; }
			if state.buttons[14] { move_dir.x -= 1.0; }

			if state.buttons[0] {
				spawn_projectile(false);
			}

			// for b, i in state.buttons {
			// 	if b {
			// 		fmt.println("button", i);
			// 	}
			// }
		}
		md := linalg.length(move_dir);
		if md > 1.0 {
			move_dir *= 1.0/md;
		}


		player_pos += move_dir * dt * 2.0;
		player_pos = bound_position(player_pos);
	}

	for p in &projectiles {
		p.pos, p.vel = update_hyperbolic_position(p.pos, p.vel, dt);
	}

	for p in &enemies {
		p.pos, p.vel = update_hyperbolic_position(p.pos, p.vel, dt);
	}

	for p in &projectiles {
		if p.spawn_time < 0 {
			continue;
		}
		for e in &enemies {
			d := linalg.length(p.pos - e.pos);
			enemy_radius := ENEMY_BASE_RADIUS * math.pow(f32(e.health)+1, 0.5);
			if d < PROJECTILE_RADIUS + enemy_radius {
				p.spawn_time = -1e6;
				if !e.marked_to_be_split {
					player_score += e.health;
					fmt.println("Score:", player_score);
				}
				e.marked_to_be_split = true;
				break;
			}
		}
	}


	for e in &enemies {
		d := linalg.length(player_pos - e.pos);
		enemy_radius := ENEMY_BASE_RADIUS * math.pow(f32(e.health)+1, 0.5);
		if d < PLAYER_RADIUS + enemy_radius {
			player_health -= 60.0 * dt;
		}
	}


	for i := len(projectiles)-1; i >= 0; i -= 1 {
		p := &projectiles[i];
		if f32(curr_time) - p.spawn_time >= PROJECTILE_LIFETIME {
			ordered_remove(&projectiles, i);
		}
	}

	en := len(enemies);
	for i := 0; i < en; i += 1 {
		e := &enemies[i];
		if e.marked_to_be_split {
			p0 := e.pos + linalg.normalize0(e.vel)*ENEMY_BASE_RADIUS*2;
			p1 := e.pos - linalg.normalize0(e.vel)*ENEMY_BASE_RADIUS*2;
			spawn_enemy(p0, e.health-1);
			if e.health > 3 {
				spawn_enemy(p1, e.health-1);
			}
			e.health = 0;
		}
	}


	for i := len(enemies)-1; i >= 0; i -= 1 {
		e := &enemies[i];
		if e.health <= 0 {
			ordered_remove(&enemies, i);
		}
	}

	if player_health <= 0 {
		game_state = .Death;
	}
}

start_new_game :: proc() {
	player_pos = {0, 0};
	player_angle = f32(math.TAU*0.125);
	player_health = f32(MAX_PLAYER_HEALTH);
	player_score = 0;
	clear(&projectiles);
	clear(&enemies);
	for i in 0..<3 {
		spawn_enemy(rand_pos());
	}

}



key_callback :: proc "c" (window: glfw.Window_Handle, key, scancode, action, mods: i32) {
	context = runtime.default_context();

	switch game_state {
	case .Menu_Main:
		if action == glfw.PRESS {
			game_state = .Game;
		}

	case .Game:
		switch key {
		case glfw.KEY_SPACE:
			switch action {
			case glfw.PRESS:
				spawn_projectile(true);
			case glfw.REPEAT:
				spawn_projectile(false);
			}

		case glfw.KEY_ESCAPE, glfw.KEY_P:
			if action == glfw.PRESS {
				game_state = .Paused;
			}
		}

	case .Paused:
		switch key {
		case glfw.KEY_ESCAPE, glfw.KEY_P:
			if action == glfw.PRESS {
				game_state = .Game;
			}
		}

	case .Death:
		switch key {
		case glfw.KEY_ESCAPE:
			if action == glfw.PRESS {
				game_state = .Menu_Main;
			}
		case:
			if action == glfw.PRESS {
				game_state = .Game;
			}
		}
	}
}


framebuffer_size_callback :: proc "c" (window: glfw.Window_Handle, width, height: i32) {
	context = runtime.default_context();

	// Freeze game logic
	curr_time = glfw.GetTime();
	prev_time = curr_time;

	dl := (^Draw_List)(glfw.GetWindowUserPointer(window));
	w, h := f32(width), f32(height);
	draw_scene(window, dl, w, h);
	glfw.SwapBuffers(window);
}

glyph_uv :: proc(c: byte) -> (uv0, uv1: [2]f32) {
	index := u8(0);
	switch c {
	case 'a'..'z':  index = c-'a';
	case 'A'..'Z':  index = c-'A';
	case '.':       index = 24+2;
	case ',':       index = 24+3;
	case '\'', '"': index = 24+4;
	case '!':       index = 24+5;
	case '?':       index = 24+6;
	case '0'..'9':  index = c-'0'; // yes, it's that trippy
	case:
		return;
	}

	x := f32(index & 7);
	y := f32(index >> 3);
	uv0.x = x * 0.125;
	uv0.y = y * 0.250;
	uv1.x = uv0.x + 0.125;
	uv1.y = uv0.y + 0.250;
	return;
}

draw_text :: proc(dl: ^Draw_List, size: f32, pos: [2]f32, text: string) {
	p := pos;
	for t in text {
		if t == 'i' || t == 'I' {
			p.x -= size*0.15;
		}
		add_rect_textured(dl, .Font_Atlas, p + size*0.05, {size*0.5, size*1.0}, glyph_uv(byte(t)), {18, 18, 18, 255});
		add_rect_textured(dl, .Font_Atlas, p, {size*0.5, size}, glyph_uv(byte(t)), Colour_White);


		if t == 'i' || t == 'I' {
			p.x -= size*0.1;
		}
		p.x += size * 0.55;
	}
}

text_dim :: proc(size: f32, text: string) -> (dim: [2]f32) {
	dim.y = size;
	for t in text {
		if t == 'i' || t == 'I' {
			dim.x -= size*0.25;
		}
		dim.x += size*0.55;
	}
	return;
}

centre_text :: proc(rect: Rect, size: f32, text: string) -> (pos: [2]f32) {
	dim := text_dim(size, text);
	pos = rect.pos + rect.size*0.5 - dim*0.5;
	return;
}

do_button :: proc(dl: ^Draw_List, text: string) -> bool {
	return false;
}

draw_scene :: proc(window: glfw.Window_Handle, dl: ^Draw_List, w, h: f32) {
	begin_draw_list(dl);
	rr := rand.create(1337);
	fb_size := [2]f32{w, h};
	ar := fb_size.x/fb_size.y;
	vpr := Rect{{0, 0}, fb_size};


	TITLE_SIZE := math.round(min(fb_size.x, fb_size.y) * 0.125);
	FONT_SIZE := math.round(min(fb_size.x, fb_size.y) * 0.25);
	SCORE_SIZE := math.round(min(fb_size.x, fb_size.y) * 0.08);

	switch game_state {
	case .Menu_Main:
		add_menu_poincare(dl, vpr);

		dim := centre_text(vpr, FONT_SIZE * 0.35, GAME_TITLE);
		dim.y = 0.35*fb_size.y;
		draw_text(dl, FONT_SIZE * 0.35, dim, GAME_TITLE);

		dim = centre_text(vpr, FONT_SIZE * 0.2, CREDITS_NAME);
		dim.y = 0.5*fb_size.y;
		draw_text(dl, FONT_SIZE * 0.2, dim, CREDITS_NAME);

		dim = centre_text(vpr, FONT_SIZE * 0.2, CREDITS_COMPO);
		dim.y = 0.6*fb_size.y;
		draw_text(dl, FONT_SIZE * 0.2, dim, CREDITS_COMPO);

		CONTINUE :: "Press Any Key!";
		dim = centre_text(vpr, FONT_SIZE * 0.2, CONTINUE);
		dim.y = 0.7*fb_size.y;
		draw_text(dl, FONT_SIZE * 0.2, dim, CONTINUE);

	case .Game, .Paused, .Death:

		add_poincare(dl, vpr);

		{
			p := clamp(f32(curr_time - last_projectime_time)/PROJECTILE_SPAWN_RATE, 0, 1);
			pos  := [2]f32{0.01, 0.01};
			size := [2]f32{0.2, 0.1};
			border := [2]f32{0.01 / ar, 0.01};

			add_rect(dl, pos * fb_size, size * fb_size, {20, 30, 40, 255});
			pos += border;
			size -= border*2;
			add_rect(dl, pos * fb_size, size * fb_size, {255, 255, 255, 255});
			add_rect(dl, pos * fb_size, {size.x * p, size.y} * fb_size, {32, 255, 64, 255});
		}

		{
			p := clamp(f32(player_health)/MAX_PLAYER_HEALTH, 0, 1);
			pos  := [2]f32{0.01, 0.12};
			size := [2]f32{0.2, 0.1};
			border := [2]f32{0.01 / ar, 0.01};

			add_rect(dl, pos * fb_size, size * fb_size, {20, 30, 40, 255});
			pos += border;
			size -= border*2;
			add_rect(dl, pos * fb_size, size * fb_size, {255, 255, 255, 255});
			add_rect(dl, pos * fb_size, {size.x * p, size.y} * fb_size, {255, 64, 32, 255});
		}


		for p in projectiles {
			col := PROJECTILE_COLOUR;
			lt := PROJECTILE_LIFETIME - (f32(curr_time) - p.spawn_time);
			FADE_TIME :: 0.3;
			if lt < FADE_TIME {
				a := f32(col.a)/255.0;
				a = math.lerp(f32(0), a, lt/FADE_TIME);
				col.a = u8(255.0*clamp(a, 0, 1));
			}
			add_entity(dl, vpr, .Projectile, p.pos, p.rot, col, 6);
		}

		if player_health > 0 {
			add_entity(dl, vpr, .Player, player_pos, player_angle, PLAYER_COLOUR, 3);
		}


		for e in enemies {
			add_entity(dl, vpr, .Enemy, e.pos, e.rot, ENEMY_COLOUR, u16(max(e.health, 0)+2));
		}

		if game_state == .Paused {
			add_rect(dl, {0, 0}, fb_size, {2, 2, 4, 160});
			title_dim := centre_text(vpr, FONT_SIZE * 0.35, GAME_TITLE);
			title_dim.y = 0.1*fb_size.y;
			draw_text(dl, FONT_SIZE * 0.35, title_dim, GAME_TITLE);
			draw_text(dl, FONT_SIZE, centre_text(vpr, FONT_SIZE, "PAUSED"), "PAUSED");
		} else if game_state == .Death {
			add_rect(dl, {0, 0}, fb_size, {2, 2, 4, 160});
			YOU_DIED :: "YOU_DIED!";
			ANY_KEY :: "Any Key to Continue";
			draw_text(dl, FONT_SIZE, centre_text(vpr, FONT_SIZE, YOU_DIED), YOU_DIED);
			dim := centre_text(vpr, SCORE_SIZE, ANY_KEY);
			dim.y  = 0.7*fb_size.y;
			draw_text(dl, SCORE_SIZE, dim, ANY_KEY);

		}


		score := fmt.tprintf("Score '%d'", player_score);
		score_dim := text_dim(SCORE_SIZE, score);
		draw_text(dl, SCORE_SIZE, fb_size*0.95 - score_dim, score);

	}

 	end_draw_list(dl);

 	render_draw_list(window, dl, w, h);
}

main :: proc() {
	glfw.Init();
	defer glfw.Terminate();

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4);
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5);
	glfw.WindowHint(glfw.OPENGL_CORE_PROFILE, 1);
	window := glfw.CreateWindow(854, 480, GAME_TITLE + "", nil, nil);
	assert(window != nil);
	defer glfw.DestroyWindow(window);

	glfw.MakeContextCurrent(window);

	glfw.SwapInterval(0);

	glfw.SetKeyCallback(window, key_callback);
	glfw.SetFramebufferSizeCallback(window, framebuffer_size_callback);

	gl.load_up_to(4, 5, proc(p: rawptr, name: cstring) {
		(^rawptr)(p)^ = glfw.GetProcAddress(name);
	});

	gl_GetTextureHandle = auto_cast glfw.GetProcAddress("glGetTextureHandleARB");
	if gl_GetTextureHandle == nil {
		gl_GetTextureHandle = auto_cast glfw.GetProcAddress("glGetTextureHandleNV");
	}
	gl_MakeTextureHandleResident = auto_cast glfw.GetProcAddress("glMakeTextureHandleResidentARB");
	if gl_MakeTextureHandleResident == nil {
		gl_MakeTextureHandleResident = auto_cast glfw.GetProcAddress("glMakeTextureHandleResidentNV");
	}

	if gl_GetTextureHandle == nil || gl_MakeTextureHandleResident == nil {
		fmt.eprintln("Required OpenGL extensions:");
		fmt.eprintln("\tglGetTextureHandleARB");
		fmt.eprintln("\tglMakeTextureHandleResidentARB");
		os.exit(1);
	}

	gl.GenVertexArrays(1, &vao);
	gl.BindVertexArray(vao);

	gl.CreateBuffers(1, &ebo);
	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo);

	gl.CreateBuffers(1, &prim_ssbo);
	gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, prim_ssbo);
	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, prim_ssbo);

	gl.NamedBufferData(ebo,  VERTEX_BUFFER_LEN*size_of(Vertex), nil, gl.STREAM_DRAW);
	gl.NamedBufferData(prim_ssbo, PRIMITIVE_BUFFER_SIZE_IN_BYTES,    nil, gl.STREAM_DRAW);

	gl.GenBuffers(1, &texture_ubo);
	gl.BindBufferBase(gl.UNIFORM_BUFFER, 0, texture_ubo);
	gl.NamedBufferData(texture_ubo, size_of(g_textures), nil, gl.STATIC_DRAW);
	gl.BindBufferRange(gl.UNIFORM_BUFFER, 0, texture_ubo, 0, size_of(g_textures));

	init_textures();

	program_ok: bool;
	program, program_ok = gl.load_shaders_source(vertex_shader, fragment_shader);
	if !program_ok {
		panic("failed to load and compiler shaders");
	}

	dl := create_draw_list(VERTEX_BUFFER_LEN, PRIMITIVE_BUFFER_SIZE_IN_BYTES);
	defer destroy_draw_list(dl);

	glfw.SetWindowUserPointer(window, dl);


	enemies     = make([dynamic]Enemy, 0, 512);
	projectiles = make([dynamic]Projectile, 0, 1024);

	start_new_game();

	TIME_STEP :: 1.0/360.0;

	window_title_accum := f32(0);
	time_accum := f32(0);
	time_count := f64(0);
	prev_time = glfw.GetTime();

	for !glfw.WindowShouldClose(window) {
		glfw.PollEvents();

		curr_time = glfw.GetTime();
		dt := f32(curr_time-prev_time);
		prev_time = curr_time;

		window_title_accum += dt;
		time_accum += dt;
		for window_title_accum >= 0.5 {
			glfw.SetWindowTitle(window, cfmt(GAME_TITLE + " - Ginger Bill - Ludum Dare 47 - %.3f ms/f, %.3f fps", 1000*dt, 1.0/dt));
			window_title_accum -= 0.5;
		}

		for time_accum >= TIME_STEP {
			time_accum -= TIME_STEP;
			update_game(window, TIME_STEP);
		}


		iw, ih: i32;
		glfw.GetFramebufferSize(window, &iw, &ih);
		draw_scene(window, dl, f32(iw), f32(ih));

		glfw.SwapBuffers(window);
	}

	fmt.println("Thank you playing my game!");
	fmt.println("Author: Ginger Bill (2020)");
	fmt.println("Ludum Dare 47");
}
