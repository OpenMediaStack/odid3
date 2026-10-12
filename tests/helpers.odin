package odid3_tests

import "core:os"
import "core:strings"
import "core:testing"

import odid3 "../"

TESTDATA :: #directory + "/../testdata/"

// The bytes of a fixture, allocated with the temp allocator.
fixture :: proc(t: ^testing.T, name: string, loc := #caller_location) -> []u8 {
	path := strings.concatenate({TESTDATA, name}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expectf(t, err == nil, "cannot read %s: %v", name, err, loc = loc)
	return data
}

read :: proc(t: ^testing.T, data: []u8, loc := #caller_location) -> odid3.Tags {
	tags, err := odid3.read_bytes(data)
	testing.expectf(t, err == nil, "read_bytes: %v", err, loc = loc)
	return tags
}

expect_range :: proc(
	t: ^testing.T,
	name: string,
	got: odid3.Range,
	offset, size: i64,
	loc := #caller_location,
) {
	testing.expectf(
		t,
		got == odid3.Range{offset, size},
		"%s: got %v, want {{offset = %v, size = %v}}",
		name,
		got,
		offset,
		size,
		loc = loc,
	)
}

slice_of :: proc(data: []u8, r: odid3.Range) -> []u8 {
	return data[r.offset:r.offset + r.size]
}

concat :: proc(parts: ..[]u8) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	for part in parts {
		append(&out, ..part)
	}
	return out[:]
}

// An ID3v2 header announcing size bytes after it.
v2_header :: proc(major, flags: u8, size: int) -> []u8 {
	return concat(
		transmute([]u8)string("ID3"),
		{major, 0, flags},
		{u8(size >> 21) & 0x7F, u8(size >> 14) & 0x7F, u8(size >> 7) & 0x7F, u8(size) & 0x7F},
	)
}

zeros :: proc(n: int) -> []u8 {
	return make([]u8, n, context.temp_allocator)
}
