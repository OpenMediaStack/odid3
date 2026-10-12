package odid3

import "base:runtime"
import "core:os"

// The tags of a file and where they are. Free it with destroy.
Tags :: struct {
	v2:       Tag, // version .None when the file has no ID3v2 tag
	v1:       V1_Tag, // version .None when the file has no ID3v1 tag
	layout:   Layout,
	warnings: Warnings,
}

// How to read tags.
Read_Options :: struct {
	// Keeps picture frames without their data, for fast scans. Tags read this way cannot be written.
	skip_picture_data: bool,
}

// Reads the tags of a whole file held in data. The result does not refer to data; free it with
// destroy. A damaged tag gives what could be read, and warnings.
read_bytes :: proc(
	data: []u8,
	options := Read_Options{},
	allocator := context.allocator,
) -> (
	tags: Tags,
	err: Error,
) {
	src := memory_source(data)
	return read_source(&src, options, allocator)
}

// Reads the tags of the file at path. Only the tags are read, never the audio between them. Free
// the result with destroy. A damaged tag gives what could be read, and warnings. A path that is not
// a regular file (a directory, a device, a pipe) gives os.General_Error.Invalid_File.
read_file :: proc(
	path: string,
	options := Read_Options{},
	allocator := context.allocator,
) -> (
	tags: Tags,
	err: Error,
) {
	// Checked before opening: opening a named pipe waits until something writes to it.
	info := os.stat(path, allocator) or_return
	type := info.type
	os.file_info_delete(info, allocator)
	if type != .Regular {
		return {}, os.Error(os.General_Error.Invalid_File)
	}
	f := os.open(path) or_return
	defer os.close(f)
	src := file_source(f) or_return
	return read_source(&src, options, allocator)
}

@(private)
read_source :: proc(
	src: ^Source,
	options: Read_Options,
	allocator: runtime.Allocator,
) -> (
	tags: Tags,
	err: Error,
) {
	defer if err != nil {
		destroy_tags(&tags)
	}
	header: V2_Header
	tags.layout, header, tags.warnings = locate(src) or_return
	v2_range := tags.layout.v2 if tags.layout.v2.size > 0 else tags.layout.v2_appended
	if v2_range.size > 0 {
		tags.v2 = read_v2_tag(src, v2_range, header, options, &tags.warnings, allocator) or_return
	}
	if tags.layout.v1.size > 0 {
		buf: [V1_SIZE]u8
		enhanced_buf: [V1_ENHANCED_SIZE]u8
		v1 := source_bytes(src, tags.layout.v1.offset, buf[:]) or_return
		enhanced: []u8
		if tags.layout.v1_enhanced.size > 0 {
			enhanced = source_bytes(src, tags.layout.v1_enhanced.offset, enhanced_buf[:]) or_return
		}
		tags.v1 = decode_v1(v1, enhanced, allocator) or_return
	}
	return
}

// Frees what reading allocated and resets the value.
destroy :: proc {
	destroy_tags,
	destroy_tag,
	destroy_frame,
	destroy_v1,
}

// Frees what read_bytes or read_file allocated in tags and resets it.
destroy_tags :: proc(tags: ^Tags) {
	destroy_tag(&tags.v2)
	destroy_v1(&tags.v1)
	tags^ = {}
}

// Frees what an ID3v2 tag holds and resets it.
destroy_tag :: proc(tag: ^Tag) {
	for &frame in tag.frames {
		destroy_frame(&frame)
	}
	delete(tag.frames)
	tag^ = {}
}
