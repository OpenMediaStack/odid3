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

// Reads the tags of a whole file held in data. The result does not refer to data; free it with
// destroy. A damaged tag gives what could be read, and warnings.
read_bytes :: proc(data: []u8, allocator := context.allocator) -> (tags: Tags, err: Error) {
	src := memory_source(data)
	return read_source(&src, allocator)
}

// Reads the tags of the file at path. Only the tags are read, never the audio between them. Free
// the result with destroy. A damaged tag gives what could be read, and warnings. A path that is not
// a regular file (a directory, a device, a pipe) gives os.General_Error.Invalid_File.
read_file :: proc(path: string, allocator := context.allocator) -> (tags: Tags, err: Error) {
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
	return read_source(&src, allocator)
}

@(private)
read_source :: proc(src: ^Source, allocator: runtime.Allocator) -> (tags: Tags, err: Error) {
	header: V2_Header
	tags.layout, header, tags.warnings = locate(src) or_return
	if tags.layout.v2.size > 0 {
		tags.v2 = {
			version   = v2_version(header.major),
			revision  = header.revision,
			flags     = tag_flags(header.major, header.flags),
			allocator = allocator,
		}
	}
	if tags.layout.v1.size > 0 {
		buf: [V1_SIZE]u8
		v1 := source_bytes(src, tags.layout.v1.offset, buf[:]) or_return
		tags.v1.version = v1_version(v1)
	}
	return
}

// Frees what reading allocated and resets the value.
destroy :: proc {
	destroy_tags,
	destroy_tag,
}

// Frees what read_bytes or read_file allocated in tags and resets it.
destroy_tags :: proc(tags: ^Tags) {
	destroy_tag(&tags.v2)
	tags^ = {}
}

// Frees what an ID3v2 tag holds and resets it.
destroy_tag :: proc(tag: ^Tag) {
	tag^ = {}
}
