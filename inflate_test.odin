package odid3

import "core:math/rand"
import "core:mem"
import "core:os"
import "core:testing"

@(private = "file")
STORED := []u8 {
	0x78,
	0x01,
	0x01,
	0x05,
	0x00,
	0xFA,
	0xFF,
	'T',
	'i',
	't',
	'l',
	'e',
	0x05,
	0xE6,
	0x02,
	0x03,
}
@(private = "file")
FIXED := []u8 {
	0x78,
	0x01,
	0x0B,
	0x48,
	0x2C,
	0x48,
	0x2D,
	0x52,
	0x08,
	0x4E,
	0x2C,
	0x49,
	0xCD,
	0xC9,
	0xC9,
	0x2C,
	0x49,
	0x2D,
	0xD6,
	0x51,
	0x08,
	0x40,
	0x13,
	0x01,
	0x00,
	0xDA,
	0x04,
	0x0C,
	0xB1,
}
@(private = "file")
EMPTY := []u8{0x78, 0xDA, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01}

@(private = "file")
expect_inflates_to :: proc(t: ^testing.T, stream: []u8, want: string, loc := #caller_location) {
	out, e, _ := inflate_zlib(stream, 1 << 20, context.allocator)
	defer delete(out)
	testing.expect_value(t, e, Inflate_Error.None, loc = loc)
	testing.expect_value(t, string(out), want, loc = loc)
}

@(private = "file")
dynamic_stream :: proc(t: ^testing.T) -> (stream, text: []u8) {
	err: os.Error
	stream, err = os.read_entire_file(
		#directory + "/testdata/zlib/dynamic.z",
		context.temp_allocator,
	)
	testing.expect_value(t, err, nil)
	text, err = os.read_entire_file(
		#directory + "/testdata/zlib/dynamic.txt",
		context.temp_allocator,
	)
	testing.expect_value(t, err, nil)
	return
}

@(test)
inflate_every_kind_of_block :: proc(t: ^testing.T) {
	expect_inflates_to(t, STORED, "Title")
	expect_inflates_to(t, FIXED, "Paper Satellites, Paper Satellites")
	expect_inflates_to(t, EMPTY, "")
	stream, text := dynamic_stream(t)
	expect_inflates_to(t, stream, string(text))
}

@(test)
inflate_refuses_damaged_streams :: proc(t: ^testing.T) {
	cases := []struct {
		stream: []u8,
		want:   Inflate_Error,
	} {
		{{0x78, 0x02, 0x01, 0x05, 0x00, 0xFA, 0xFF, 'T'}, .Bad_Header},
		{{0x79, 0x01, 0x01, 0x05, 0x00, 0xFA, 0xFF, 'T'}, .Bad_Header},
		{{0x78, 0x01, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00}, .Bad_Block},
		{
			{0x78, 0x01, 0x01, 0x05, 0x00, 0xFA, 0xFE, 'T', 'i', 't', 'l', 'e', 0, 0, 0, 0},
			.Bad_Block,
		},
		{
			{
				0x78,
				0x01,
				0x01,
				0x05,
				0x00,
				0xFA,
				0xFF,
				'T',
				'i',
				't',
				'l',
				'e',
				0x05,
				0xE6,
				0x02,
				0x04,
			},
			.Bad_Checksum,
		},
		{{0x78, 0x01, 0x01, 0x05, 0x00, 0xFA, 0xFF, 'T', 'i', 't'}, .Truncated},
		// A fixed block whose first code is a match: there is nothing to copy from yet.
		{{0x78, 0x01, 0x03, 0x02, 0x00, 0x00, 0x00, 0x00}, .Too_Far},
	}
	for c in cases {
		out, e, _ := inflate_zlib(c.stream, 1 << 20, context.allocator)
		testing.expectf(t, e == c.want, "%v gave %v, want %v", c.stream, e, c.want)
		testing.expect(t, out == nil)
	}
}

@(test)
inflate_stops_at_its_limit :: proc(t: ^testing.T) {
	stream, text := dynamic_stream(t)
	out, e, _ := inflate_zlib(stream, len(text) - 1, context.allocator)
	testing.expect_value(t, e, Inflate_Error.Too_Big)
	testing.expect(t, out == nil)
	out, e, _ = inflate_zlib(stream, len(text), context.allocator)
	defer delete(out)
	testing.expect_value(t, e, Inflate_Error.None)
}

@(test)
inflate_never_panics_on_cut_or_mutated_streams :: proc(t: ^testing.T) {
	with_dynamic_codes, _ := dynamic_stream(t)
	for stream in ([][]u8{STORED, FIXED, EMPTY, with_dynamic_codes}) {
		for n in 0 ..< len(stream) {
			out, e, _ := inflate_zlib(stream[:n], 1 << 20, context.allocator)
			testing.expect(t, e != .None)
			delete(out)
		}
		mutated := make([]u8, len(stream))
		defer delete(mutated)
		for _ in 0 ..< 2000 {
			copy(mutated, stream)
			for _ in 0 ..< 1 + rand.int_max(4) {
				mutated[rand.int_max(len(mutated))] = u8(rand.uint32())
			}
			out, e, _ := inflate_zlib(mutated, 1 << 20, context.allocator)
			if e == .None {
				delete(out)
			}
		}
	}
}

// Streams built by hand where a code is incomplete: zlib only accepts a single code of 1 bit.
@(test)
inflate_single_codes_as_zlib_does :: proc(t: ^testing.T) {
	header := []u8{0x78, 0x9C, 0x05, 0xE0, 0x01, 0x09, 0x00, 0x00, 0x00, 0xC3, 0x20}
	distance_of_1_bit := []u8{0x64, 0xB5, 0x7F, 0x09, 0x15, 0x00, 0x62, 0x00, 0x62}
	accepted := concat_bytes(header, distance_of_1_bit)
	defer delete(accepted)
	expect_inflates_to(t, accepted, "a")
	rejected := [][]u8 {
		{0x64, 0xB5, 0x7F, 0x09, 0x27, 0x00, 0x62, 0x00, 0x62},
		{0x64, 0xB5, 0x7F, 0x09, 0x2F, 0x00, 0x62, 0x00, 0x62},
		{0xF4, 0x6F, 0x3D, 0x01, 0x00, 0x00, 0x00, 0x01},
		{0xF4, 0x6F, 0x7D, 0x01, 0x00, 0x00, 0x00, 0x01},
	}
	for tail in rejected {
		stream := concat_bytes(header, tail)
		defer delete(stream)
		out, e, _ := inflate_zlib(stream, 100, context.allocator)
		testing.expectf(t, e == .Bad_Block, "%v gave %v", tail, e)
		testing.expect(t, out == nil)
	}
}

@(private = "file")
concat_bytes :: proc(a, b: []u8) -> []u8 {
	out := make([]u8, len(a) + len(b))
	copy(out, a)
	copy(out[len(a):], b)
	return out
}

@(test)
inflate_slack_is_added_to_the_declared_size :: proc(t: ^testing.T) {
	stream, text := dynamic_stream(t)
	out, ok, err := inflate_frame(stream, i64(len(text) - 10), context.allocator)
	defer delete(out)
	testing.expect_value(t, err, nil)
	testing.expect(t, ok && len(out) == len(text))
}

@(test)
inflate_allocates_no_more_than_its_limit :: proc(t: ^testing.T) {
	stream, text := dynamic_stream(t)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	out, e, _ := inflate_zlib(stream, len(text), mem.tracking_allocator(&track))
	testing.expect_value(t, e, Inflate_Error.None)
	testing.expectf(
		t,
		track.peak_memory_allocated <= i64(2 * len(text)),
		"peak %v for %v",
		track.peak_memory_allocated,
		len(text),
	)
	delete(out, mem.tracking_allocator(&track))
}
