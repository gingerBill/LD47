package stbi

import "core:os"
import "core:strings"

when os.OS == "windows" do foreign import stbiw "stb_image_write.lib"
// bind
@(default_calling_convention="c")
@(link_prefix="stbi_")
foreign stbiw {
	write_png :: proc(filename: cstring, w, h, comp: i32, data: rawptr, stride_in_bytes: i32) -> i32 ---;
	write_bmp :: proc(filename: cstring, w, h, comp: i32, data: rawptr) -> i32 ---;
	write_tga :: proc(filename: cstring, w, h, comp: i32, data: rawptr) -> i32 ---;
	write_hdr :: proc(filename: cstring, w, h, comp: i32, data: ^f32) -> i32 ---;
	write_jpg :: proc(filename: cstring, w, h, comp: i32, data: rawptr, quality: i32 /*0 to 100*/) -> i32 ---;
}
