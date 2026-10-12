package odid3

import "core:bytes"
import "core:compress/zlib"
import "core:math/rand"
import "core:mem"
import "core:strings"
import "core:testing"

// Every stream must inflate back to its data with odid3's inflater and with core:compress/zlib.
@(private = "file")
expect_round_trip :: proc(t: ^testing.T, data: []u8, loc := #caller_location) -> (stream: []u8) {
	err: Error
	stream, err = deflate_zlib(data, context.allocator)
	testing.expect_value(t, err, nil, loc = loc)
	out, e, _ := inflate_zlib(stream, len(data), context.allocator)
	testing.expect_value(t, e, Inflate_Error.None, loc = loc)
	testing.expectf(
		t,
		bytes.equal(out, data),
		"odid3 inflates %d bytes back to %d",
		len(data),
		len(out),
		loc = loc,
	)
	delete(out)

	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	core_err := zlib.inflate(stream, &buf)
	testing.expectf(t, core_err == nil, "core:compress/zlib: %v", core_err, loc = loc)
	testing.expectf(
		t,
		bytes.equal(bytes.buffer_to_bytes(&buf), data),
		"core:compress/zlib inflates otherwise",
		loc = loc,
	)
	return stream
}

@(private = "file")
random_bytes :: proc(n: int) -> []u8 {
	out := make([]u8, n, context.temp_allocator)
	for &b in out {
		b = u8(rand.uint32())
	}
	return out
}

@(test)
deflate_round_trips :: proc(t: ^testing.T) {
	text := strings.repeat(
		"Marlowe Kite sings la la la in the key of C, then again. ",
		40,
		context.temp_allocator,
	)
	every_byte: [1024]u8
	for &b, i in every_byte {
		b = u8(i)
	}
	cases := [][]u8 {
		{},
		{'a'},
		{0xFF},
		transmute([]u8)strings.repeat("a", 1000, context.temp_allocator),
		transmute([]u8)strings.repeat("ab", 129, context.temp_allocator),
		transmute([]u8)text,
		every_byte[:],
	}
	for data in cases {
		delete(expect_round_trip(t, data))
	}
}

@(test)
deflate_compresses_repeated_text :: proc(t: ^testing.T) {
	text := strings.repeat("Compressed title, then la la la. ", 100, context.temp_allocator)
	stream := expect_round_trip(t, transmute([]u8)text)
	defer delete(stream)
	testing.expectf(t, len(stream) < len(text) / 10, "%d bytes from %d", len(stream), len(text))
	testing.expect_value(t, stream[0], 0x78)
	testing.expect_value(t, (u16(stream[0]) << 8 | u16(stream[1])) % 31, 0)
}

@(test)
deflate_stores_what_it_cannot_compress :: proc(t: ^testing.T) {
	for n in ([]int{1000, 65535, 65536, 200_000}) {
		data := random_bytes(n)
		stream := expect_round_trip(t, data)
		blocks := (n + 65534) / 65535
		testing.expect_value(t, len(stream), 2 + n + 5 * blocks + 4)
		delete(stream)
	}
}

@(test)
deflate_matches_reach_the_whole_window :: proc(t: ^testing.T) {
	window := random_bytes(32 * 1024)
	twice := make([]u8, 2 * len(window), context.temp_allocator)
	copy(twice, window)
	copy(twice[len(window):], window)
	stream := expect_round_trip(t, twice)
	testing.expectf(t, len(stream) < len(window) + len(window) / 4, "%d bytes", len(stream))
	delete(stream)

	too_far := make([]u8, 2 * len(window) + 2, context.temp_allocator)
	copy(too_far, window)
	copy(too_far[len(window) + 1:], window)
	delete(expect_round_trip(t, too_far))
}

@(test)
deflate_round_trips_random_data :: proc(t: ^testing.T) {
	for _ in 0 ..< 300 {
		n := rand.int_max(5000)
		alphabet := 1 + rand.int_max(8)
		data := make([]u8, n, context.temp_allocator)
		for &b in data {
			b = u8(rand.int_max(alphabet)) * 37
		}
		if rand.int_max(4) == 0 && n > 0 {
			copy(data[rand.int_max(n):], random_bytes(rand.int_max(300)))
		}
		delete(expect_round_trip(t, data))
	}
}

@(private = "file")
Failing :: struct {
	left: int,
	live: int,
}

@(private = "file")
failing_proc :: proc(
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
	result, err := context.allocator.procedure(
		context.allocator.data,
		mode,
		size,
		alignment,
		old_memory,
		old_size,
		loc,
	)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		f.live += 1
	case .Free:
		f.live -= 1
	}
	return result, err
}

@(test)
deflate_frees_everything_when_memory_runs_out :: proc(t: ^testing.T) {
	text := transmute([]u8)strings.repeat("la la la ", 50, context.temp_allocator)
	for budget in 0 ..< 10 {
		f := Failing {
			left = budget,
		}
		allocator := mem.Allocator{failing_proc, &f}
		stream, err := deflate_zlib(text, allocator)
		if err == nil {
			delete(stream, allocator)
			testing.expect_value(t, f.live, 0)
			return
		}
		testing.expect_value(t, f.live, 0)
		testing.expect(t, stream == nil)
	}
	testing.fail_now(t, "deflate_zlib never succeeded")
}
