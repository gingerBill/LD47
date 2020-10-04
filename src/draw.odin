package ld47

import "core:mem"
import "core:sort"

/*
        0
        |
        |(6:2)custom data
        |     |
        00000000 00000000 00000000 00000000
        |        |
   (0:6)prim_kind|
                 |
           (8:24)offset into buffer

    Each primitive is aligned to 4 bytes for the GPU
*/
Vertex :: distinct u32;
Rect :: struct {
	pos:  [2]f32,
	size: [2]f32,
}
Colour :: struct{r, g, b, a: u8};
Colour_White :: Colour{255, 255, 255, 255};
Colour_Black :: Colour{0, 0, 0, 255};

Draw_List :: struct {
	allocator:            mem.Allocator,

	vertex_buffer:        []Vertex,
	sorted_vertex_buffer: []Vertex,
	vertex_len:           int,

	primitive_buffer:     []byte,
	primitive_size:       int,

	commands:             [dynamic]Draw_Command,

	temp_path:            [dynamic][2]f32,
}


Draw_Command :: struct {
	z_index:       i32,
	vertex_offset: u32,
	vertex_count:  u32,
	texture:       Texture_Id,
}


create_draw_list :: proc(vertex_buffer_len, primitive_size_in_bytes: int) -> ^Draw_List {
	dl := new(Draw_List);
	dl.allocator = context.allocator;

	dl.vertex_buffer        = mem.make_aligned([]Vertex, vertex_buffer_len, 16);
	dl.sorted_vertex_buffer = mem.make_aligned([]Vertex, vertex_buffer_len, 16);
	dl.vertex_len = 0;
	dl.primitive_buffer = mem.make_aligned([]byte, primitive_size_in_bytes, 16);
	dl.primitive_size = 0;

	reserve(&dl.commands, 64);
	reserve(&dl.temp_path, 64);

	return dl;
}

destroy_draw_list :: proc(dl: ^Draw_List){
	context.allocator = dl.allocator;
	delete(dl.commands);
	delete(dl.temp_path);
	delete(dl.vertex_buffer);
	delete(dl.sorted_vertex_buffer);
	delete(dl.primitive_buffer);
	free(dl);
}


begin_draw_list :: proc(dl: ^Draw_List) {
	dl.vertex_len = 0;
	dl.primitive_size = 16; // Reserve the first 16 bytes for nothing

	clear(&dl.commands);

	add_draw_command_on_texture_change(dl, .White);
}

end_draw_list :: proc(dl: ^Draw_List) {
	// pop unused draw commands
	if len(dl.commands) != 0 {
		cmd := &dl.commands[len(dl.commands)-1];
		if cmd.vertex_count == 0 {
			pop(&dl.commands);
		}
	}

	// sort commands

	sort.quick_sort_proc(dl.commands[:], proc(x, y: Draw_Command) -> int {
		switch {
		case x.z_index < y.z_index: return -1;
		case x.z_index > y.z_index: return +1;

		case x.vertex_offset < y.vertex_offset: return -1;
		case x.vertex_offset > y.vertex_offset: return +1;
		}

		return 0;
	});

	new_commands := make([]Draw_Command, len(dl.commands), context.temp_allocator);

	command_index := 0;
	offset := u32(0);

	for cmd in dl.commands {
		if cmd.vertex_count == 0 {
			continue;
		}

		copy(dl.sorted_vertex_buffer[offset:], dl.vertex_buffer[cmd.vertex_offset:][:cmd.vertex_count]);

		use_new_command := true;
		if command_index > 0 {
			prev := &new_commands[command_index-1];
			if prev.texture == cmd.texture {
				prev.vertex_count += cmd.vertex_count;
				use_new_command = false;
			}
		}

		if use_new_command {
			new_commands[command_index] = Draw_Command{
				vertex_offset = offset,
				vertex_count  = cmd.vertex_count,
				texture       = cmd.texture,
			};
			command_index += 1;
		}

		offset += cmd.vertex_count;
	}

	resize(&dl.commands, command_index);
	copy(dl.commands[:], new_commands[:]);
	assert(u32(dl.vertex_len) == offset); // sanity check
}

add_draw_command_on_texture_change :: proc(dl: ^Draw_List, texture: Texture_Id) {
	prev_z_index := i32(0);
	if len(dl.commands) != 0 {
		prev := &dl.commands[len(dl.commands)-1];
		if prev.texture == texture {
			return;
		}
		prev_z_index = prev.z_index;
	}
	append(&dl.commands, Draw_Command{
		z_index = prev_z_index,
		vertex_offset = u32(dl.vertex_len),
		vertex_count = 0,
		texture = texture,
	});
}
add_draw_command_on_z_index :: proc(dl: ^Draw_List, z_index: i32) {
	prev_texture := Texture_Id(0);
	if len(dl.commands) != 0 {
		prev := &dl.commands[len(dl.commands)-1];
		if prev.z_index == z_index {
			return;
		}
		prev_texture = prev.texture;
	}
	append(&dl.commands, Draw_Command{
		z_index = z_index,
		vertex_offset = u32(dl.vertex_len),
		vertex_count = 0,
		texture = prev_texture,
	});
}


PRIM_ALIGNMENT_SHIFT :: 2; // 2 == 4 Bytes, 4 == 16 Bytes
PRIM_ALIGNMENT :: 1<<PRIM_ALIGNMENT_SHIFT;

new_prim :: proc(dl: ^Draw_List, $T: typeid, loc := #caller_location) -> (ptr: ^T, offset: u32) {
	if dl.primitive_size+size_of(T) > len(dl.primitive_buffer) {
		panic("draw list primitive buffer overflow");
	}

	base := uintptr(raw_data(dl.primitive_buffer));
	u_offset := uintptr(dl.primitive_size);
	ptr = (^T)(base + u_offset);

	dl.primitive_size += size_of(T);
	dl.primitive_size = mem.align_forward_int(dl.primitive_size, PRIM_ALIGNMENT);

	offset = u32(u_offset >> PRIM_ALIGNMENT_SHIFT) & 0x00ffffff;
	return;
}

prim_resize :: proc(dl: ^Draw_List, vertex_count: int) -> (vertex_write: []Vertex, ok: bool) {
	MAX_VERTEX_COUNT :: 1<<24;

	assert(0 <= vertex_count && vertex_count <= MAX_VERTEX_COUNT);

	n := dl.vertex_len;
	if len(dl.vertex_buffer) < n+vertex_count {
		return;
	}

	cmd := &dl.commands[len(dl.commands)-1];
	cmd.vertex_count += u32(vertex_count);
	vertex_write = dl.vertex_buffer[n:][:vertex_count];
	dl.vertex_len += vertex_count;
	ok = true;
	return;
}


Prim_Kind :: enum u8 {
	Invalid         = 0,
	Rect            = 1,
	Rect_Textured   = 2,

	Poincare      = 16,
	Entity        = 17,
	Menu_Poincare = 18,
};

#assert(int(max(Prim_Kind)) < 1<<6);

Prim_Rect :: struct {
	pos:  [2]f32,
	size: [2]f32,
	col:  Colour,
}

Prim_Rect_Textured :: struct {
	pos:     [2]f32,
	size:    [2]f32,
	uv0:     [2]f32,
	uv1:     [2]f32,
	col:     Colour,
	texture: Texture_Id,
}

Prim_Poincare :: struct {
	rect: Rect,
}

Prim_Entity_Kind :: enum u16 {
	Invalid    = 0,
	Player     = 1,
	Projectile = 2,
	Enemy      = 3,
}

Prim_Entity :: struct {
	rect:     Rect,
	pos:      [2]f32,
	rot:      f32,
	col:      Colour,
	kind:     Prim_Entity_Kind,
	vertices: u16,
}




add_rect :: proc(dl: ^Draw_List, pos, size: [2]f32, col: Colour) #no_bounds_check {
	add_draw_command_on_texture_change(dl, .White);

	vertex_write, ok := prim_resize(dl, 6);
	if !ok {
		return;
	}

	r, offset := new_prim(dl, Prim_Rect);
	r.pos = pos;
	r.size = size;
	r.col = col;

	v := Vertex(Prim_Kind.Rect);
	v |= Vertex(offset<<8);

	vertex_write[0] = v | (0 << 6);
	vertex_write[1] = v | (1 << 6);
	vertex_write[2] = v | (2 << 6);
	vertex_write[3] = v | (2 << 6);
	vertex_write[4] = v | (3 << 6);
	vertex_write[5] = v | (0 << 6);
}

add_rect_textured :: proc(dl: ^Draw_List, texture: Texture_Id, pos, size: [2]f32, uv0 := [2]f32{0, 0}, uv1 := [2]f32{1, 1}, col := Colour_White) #no_bounds_check {
	add_draw_command_on_texture_change(dl, texture);

	vertex_write, ok := prim_resize(dl, 6);
	if !ok {
		return;
	}

	r, offset := new_prim(dl, Prim_Rect_Textured);
	r.pos     = pos;
	r.size    = size;
	r.uv0     = uv0;
	r.uv1     = uv1;
	r.col     = col;
	r.texture = texture;

	v := Vertex(Prim_Kind.Rect_Textured);
	v |= Vertex(offset<<8);

	vertex_write[0] = v | (0 << 6);
	vertex_write[1] = v | (1 << 6);
	vertex_write[2] = v | (2 << 6);
	vertex_write[3] = v | (2 << 6);
	vertex_write[4] = v | (3 << 6);
	vertex_write[5] = v | (0 << 6);
}


add_poincare :: proc(dl: ^Draw_List, rect: Rect) #no_bounds_check {
	add_draw_command_on_texture_change(dl, .White);

	vertex_write, ok := prim_resize(dl, 6);
	if !ok {
		return;
	}

	r, offset := new_prim(dl, Prim_Poincare);
	r.rect = rect;

	v := Vertex(Prim_Kind.Poincare);
	v |= Vertex(offset<<8);

	vertex_write[0] = v | (0 << 6);
	vertex_write[1] = v | (1 << 6);
	vertex_write[2] = v | (2 << 6);
	vertex_write[3] = v | (2 << 6);
	vertex_write[4] = v | (3 << 6);
	vertex_write[5] = v | (0 << 6);
}



add_menu_poincare :: proc(dl: ^Draw_List, rect: Rect) #no_bounds_check {
	add_draw_command_on_texture_change(dl, .White);

	vertex_write, ok := prim_resize(dl, 6);
	if !ok {
		return;
	}

	r, offset := new_prim(dl, Prim_Poincare);
	r.rect = rect;

	v := Vertex(Prim_Kind.Menu_Poincare);
	v |= Vertex(offset<<8);

	vertex_write[0] = v | (0 << 6);
	vertex_write[1] = v | (1 << 6);
	vertex_write[2] = v | (2 << 6);
	vertex_write[3] = v | (2 << 6);
	vertex_write[4] = v | (3 << 6);
	vertex_write[5] = v | (0 << 6);
}

add_entity :: proc(dl: ^Draw_List, rect: Rect, kind: Prim_Entity_Kind, pos: [2]f32, rot: f32, col: Colour, vertices: u16) #no_bounds_check {
	add_draw_command_on_texture_change(dl, .White);

	vertex_write, ok := prim_resize(dl, 6);
	if !ok {
		return;
	}

	r, offset := new_prim(dl, Prim_Entity);
	r.rect = rect;
	r.pos = pos;
	r.rot = rot;
	r.col = col;
	r.kind = kind;
	r.vertices = clamp(vertices, 3, 64);

	v := Vertex(Prim_Kind.Entity);
	v |= Vertex(offset<<8);

	vertex_write[0] = v | (0 << 6);
	vertex_write[1] = v | (1 << 6);
	vertex_write[2] = v | (2 << 6);
	vertex_write[3] = v | (2 << 6);
	vertex_write[4] = v | (3 << 6);
	vertex_write[5] = v | (0 << 6);
}


