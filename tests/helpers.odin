package odid3_tests

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

import odid3 "../"

TESTDATA :: #directory + "/../testdata/"

// The bytes of a fixture, allocated with the temp allocator.
fixture :: proc(t: ^testing.T, name: string, loc := #caller_location) -> []u8 {
	data, err := os.read_entire_file(fixture_path(name), context.temp_allocator)
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

fixture_path :: proc(name: string) -> string {
	return strings.concatenate({TESTDATA, name}, context.temp_allocator)
}

// The names of every MP3 fixture.
fixture_names :: proc(t: ^testing.T) -> []string {
	infos, err := os.read_all_directory_by_path(TESTDATA, context.temp_allocator)
	testing.expectf(t, err == nil, "cannot list the fixtures: %v", err)
	names := make([dynamic]string, context.temp_allocator)
	for info in infos {
		if strings.has_suffix(info.name, ".mp3") {
			append(&names, info.name)
		}
	}
	return names[:]
}

// A new temporary directory, removed when the test ends.
make_temp_dir :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "odid3-*", context.allocator)
	if err != nil {
		testing.fail_now(t, "cannot create a temporary directory")
	}
	testing.cleanup(t, proc(data: rawptr) {
			dir := (^string)(data)
			os.remove_all(dir^)
			delete(dir^)
			free(dir)
		}, new_clone(dir))
	return dir
}

join :: proc(dir, name: string) -> string {
	path, _ := os.join_path({dir, name}, context.temp_allocator)
	return path
}

// An allocator that fails once `left` allocations have been made, to test the error paths.
Failing :: struct {
	backing: mem.Allocator,
	left:    int,
}

failing_allocator :: proc(f: ^Failing) -> mem.Allocator {
	return {procedure = failing_allocator_proc, data = f}
}

failing_allocator_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	f := (^Failing)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if f.left == 0 {
			return nil, .Out_Of_Memory
		}
		f.left -= 1
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

text :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

// A frame of an ID3v2.3 tag (plain size) or ID3v2.4 tag (syncsafe size).
frame :: proc(major: u8, id: string, data: []u8, status: u8 = 0, format: u8 = 0) -> []u8 {
	n := len(data)
	size: []u8
	if major == 4 {
		size = {u8(n >> 21) & 0x7F, u8(n >> 14) & 0x7F, u8(n >> 7) & 0x7F, u8(n) & 0x7F}
	} else {
		size = {u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)}
	}
	return concat(transmute([]u8)id, size, {status, format}, data)
}

// An ID3v2 tag holding body (frames and padding), followed by a little audio.
tag_file :: proc(major, flags: u8, body: ..[]u8) -> []u8 {
	content := concat(..body)
	return concat(v2_header(major, flags, len(content)), content, {0xFF, 0xFB, 0x90, 0x00})
}

// n lowercase letters, which can be neither a frame ID nor padding.
letters :: proc(n: int) -> []u8 {
	out := make([]u8, n, context.temp_allocator)
	for &c, i in out {
		c = 'a' + u8(i % 26)
	}
	return out
}
