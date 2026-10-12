package odid3

import "base:runtime"

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
}

// Frees what read_bytes allocated in tags and resets it.
destroy_tags :: proc(tags: ^Tags) {
	tags^ = {}
}
