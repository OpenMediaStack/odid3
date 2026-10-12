package odid3_tests

import "core:bytes"
import "core:mem"
import "core:strings"
import "core:testing"

import odid3 "../"

compressed_title :: proc() -> string {
	return strings.concatenate(
		{"\x00Compressed title, then", strings.repeat(" la", 40, context.temp_allocator)},
		context.temp_allocator,
	)
}

@(test)
compressed_frames_in_v23 :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v23_compressed.mp3"))
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.warnings, odid3.Warnings{})
	title := tags.v2.frames[0]
	testing.expect_value(t, title.format, odid3.Frame_Format{.Compression})
	testing.expect_value(t, title.problem, odid3.Frame_Problem.None)
	testing.expect_value(t, string(title.data), compressed_title())
	testing.expect_value(t, string(tags.v2.frames[1].data), "\x00Marlowe Kite")
}

@(test)
compressed_frames_in_v24 :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v24_compressed.mp3"))
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.warnings, odid3.Warnings{})
	title := tags.v2.frames[0]
	testing.expect_value(t, title.format, odid3.Frame_Format{.Compression, .Data_Length_Indicator})
	testing.expect_value(t, string(title.data), compressed_title())
	private := tags.v2.frames[1]
	testing.expect_value(
		t,
		private.format,
		odid3.Frame_Format{.Compression, .Unsynchronisation, .Data_Length_Indicator},
	)
	testing.expect_value(t, private.problem, odid3.Frame_Problem.None)
	testing.expect_value(t, len(private.data), 606)
	testing.expect(t, bytes.has_prefix(private.data, text("odid3\x00")))
}

@(test)
compression_bomb_is_not_inflated :: proc(t: ^testing.T) {
	data := fixture(t, "v24_compression_bomb.mp3")
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	tags, err := odid3.read_bytes(data, {}, allocator)
	defer odid3.destroy(&tags)
	testing.expect_value(t, err, nil)
	title := tags.v2.frames[0]
	testing.expect_value(t, title.problem, odid3.Frame_Problem.Bad_Compression)
	testing.expect_value(t, len(title.data), title.size - 4)
	testing.expectf(
		t,
		track.peak_memory_allocated < 4 * mem.Megabyte,
		"inflating allocated up to %v bytes",
		track.peak_memory_allocated,
	)
}

@(test)
damaged_compressed_frames :: proc(t: ^testing.T) {
	garbage := concat({0, 0, 0, 20}, text("not a zlib stream"))
	tags := read(t, tag_file(3, 0, frame(3, "TIT2", garbage, 0, 0x80)))
	testing.expect_value(t, tags.v2.frames[0].problem, odid3.Frame_Problem.Bad_Compression)
	testing.expect_value(t, string(tags.v2.frames[0].data), "not a zlib stream")
	odid3.destroy(&tags)

	// A stored deflate block holding "Title", with a declared size no stream of 16 bytes can reach.
	stored_title := concat(
		{0x78, 0x01, 0x01, 5, 0, 0xFA, 0xFF},
		text("Title"),
		{0x05, 0xE6, 0x02, 0x03},
	)
	impossible := concat({0x40, 0, 0, 0}, stored_title)
	tags = read(t, tag_file(3, 0, frame(3, "TIT2", impossible, 0, 0x80)))
	testing.expect_value(t, tags.v2.frames[0].problem, odid3.Frame_Problem.Bad_Compression)
	odid3.destroy(&tags)

	wrong_size := concat({0, 0, 0, 4}, stored_title)
	tags = read(t, tag_file(3, 0, frame(3, "TIT2", wrong_size, 0, 0x80)))
	testing.expect_value(t, tags.v2.frames[0].problem, odid3.Frame_Problem.Bad_Data_Length)
	testing.expect_value(t, string(tags.v2.frames[0].data), "Title")
	odid3.destroy(&tags)
}

@(test)
encrypted_frames_are_kept_as_stored :: proc(t: ^testing.T) {
	tags := read(t, tag_file(3, 0, frame(3, "PRIV", concat({0x80}, text("secret")), 0, 0x40)))
	f := tags.v2.frames[0]
	testing.expect_value(t, f.problem, odid3.Frame_Problem.Encrypted)
	testing.expect_value(t, f.method, 0x80)
	testing.expect_value(t, string(f.data), "secret")
	odid3.destroy(&tags)

	stored := concat({0x80}, unsynchronise({0xFF, 0xE0, 's'}))
	tags = read(t, tag_file(4, 0, frame(4, "PRIV", stored, 0, 0x06)))
	f = tags.v2.frames[0]
	testing.expect_value(t, f.problem, odid3.Frame_Problem.Encrypted)
	testing.expect_value(t, string(f.data), "\xFF\xE0s")
	odid3.destroy(&tags)
}

@(test)
allocation_failures_while_inflating :: proc(t: ^testing.T) {
	data := fixture(t, "v24_compressed.mp3")
	for budget in 0 ..< 64 {
		f := Failing{context.allocator, budget}
		tags, err := odid3.read_bytes(data, {}, failing_allocator(&f))
		if err == nil {
			testing.expect_value(t, tags.v2.frames[1].problem, odid3.Frame_Problem.None)
			odid3.destroy(&tags)
			return
		}
		testing.expect_value(t, err, mem.Allocator_Error.Out_Of_Memory)
	}
	testing.fail_now(t, "reading never succeeded")
}
