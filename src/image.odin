package ld47

import "core:fmt"
import "core:mem"
import gl "shared:odin-gl"
import stbi "shared:stbi"


gl_GetTextureHandle:          proc "c" (texture: u32) -> u64;
gl_MakeTextureHandleResident: proc "c" (texture: u64);


Texture_Id :: enum u32 {
	White = 0,
	Error = 1,
	Font_Atlas = 2,
}
#assert(len(Texture_Id) <= 128);


Sampling_Mode :: enum {
	Nearest,
	Linear,
}

Wrap_Mode :: enum {
	Repeat,
	Mirrored_Repeat,
	Clamp_To_Edge,
	Clamp_To_Border,
}

Texture :: distinct u64;

Uniform_Texture_Entry :: struct {
	handle: Texture,
	_:      u64, // Padding required for the GPU
}
#assert(size_of(Uniform_Texture_Entry) == 16);

g_textures: [Texture_Id]Uniform_Texture_Entry;


Channel_Kind :: enum i32 {
	None = 0,
	R    = 1,
	RG   = 2,
	RGB  = 3,
	RGBA = 4,
}

Image :: struct {
	width:    i32,
	height:   i32,
	channels: Channel_Kind,
	data:     []byte,
}

_sampling_mode_table := [Sampling_Mode]i32{
	.Nearest = gl.NEAREST,
	.Linear = gl.LINEAR,
};
_wrap_mode_table := [Wrap_Mode]i32{
	.Repeat          = gl.REPEAT,
	.Mirrored_Repeat = gl.MIRRORED_REPEAT,
	.Clamp_To_Edge   = gl.CLAMP_TO_EDGE,
	.Clamp_To_Border = gl.CLAMP_TO_BORDER,
};

channels_to_gl_formats :: proc(channels: Channel_Kind) -> (format, internal: u32) {
	switch channels {
	case .R:    return gl.RED,  gl.RGBA8;
	case .RG:   return gl.RG,   gl.RGBA8;
	case .RGB:  return gl.RGB,  gl.RGBA8;
	case .RGBA: return gl.RGBA, gl.RGBA8;
	case .None: //
	}
	panic("unknown channel size");
}

create_image_from_file :: proc(filepath: string) -> Image {
	path := make([]byte, len(filepath)+1, context.temp_allocator);
	copy(path, filepath);
	path[len(filepath)] = 0;
	cpath := cstring(raw_data(path));

	x, y, c: i32;
	c_data := stbi.load(cpath, &x, &y, &c, 4);
	defer stbi.image_free(c_data);

	size := int(x*y*c);
	data := make([]byte, size);
	mem.copy(raw_data(data), c_data, size);
	return Image{
		width = x,
		height = y,
		channels = Channel_Kind(c),
		data = data,
	};
}

create_texture_from_image :: proc(image: Image, sampling_mode: Sampling_Mode, wrap_mode := Wrap_Mode.Clamp_To_Edge) -> Texture {
	format, internal_format := channels_to_gl_formats(image.channels);

	sm := _sampling_mode_table[sampling_mode];
	wm := _wrap_mode_table[wrap_mode];

	tex: u32;
	gl.CreateTextures(gl.TEXTURE_2D, 1, &tex);

	gl.TextureParameteri(tex, gl.TEXTURE_MIN_FILTER, sm);
	gl.TextureParameteri(tex, gl.TEXTURE_MAG_FILTER, sm);
	gl.TextureParameteri(tex, gl.TEXTURE_WRAP_S, wm);
	gl.TextureParameteri(tex, gl.TEXTURE_WRAP_T, wm);
	gl.TextureStorage2D(tex, 1, internal_format, image.width, image.height);
	gl.TextureSubImage2D(tex, 0, 0, 0, image.width, image.height, format, gl.UNSIGNED_BYTE, raw_data(image.data));

	raw_handle := gl_GetTextureHandle(tex); // Check for validity
	assert(raw_handle != 0);
	gl_MakeTextureHandleResident(raw_handle);
	return Texture(raw_handle);
}

create_texture_coloured :: proc(col: Colour, wrap_mode := Wrap_Mode.Clamp_To_Edge) -> Texture {
	W :: 8;
	cdata: [W*W]Colour = col;
	data := cast(^[4*W*W]u8)&cdata;
	image := Image{
		width = W,
		height = W,
		channels = .RGBA,
		data = data[:],
	};
	return create_texture_from_image(image, .Nearest, wrap_mode);
}

create_texture_from_file :: proc(filepath: string, sampling_mode: Sampling_Mode, wrap_mode := Wrap_Mode.Clamp_To_Edge) -> Texture {
	return create_texture_from_image(create_image_from_file(filepath), sampling_mode, wrap_mode);
}


init_textures :: proc() {
	g_textures[.White].handle = create_texture_coloured({255, 255, 255, 255});
	g_textures[.Error].handle = create_texture_coloured({255,   0, 255, 255});
	g_textures[.Font_Atlas].handle = create_texture_from_file("res/font_atlas.png", .Linear);
}
