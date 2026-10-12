package odid3_tests

import "core:bytes"
import "core:testing"

import odid3 "../"

expect_frames_at_their_offsets :: proc(t: ^testing.T, name: string, file: []u8, tag: ^odid3.Tag) {
	for &f in tag.frames {
		ok :=
			f.offset >= 0 && f.offset + 4 <= i64(len(file)) && string(file[f.offset:][:4]) == f.id
		testing.expectf(t, ok, "%s: %s is not at offset %d", name, f.id, f.offset)
	}
}

@(test)
whole_tag_unsynchronisation_in_v23 :: proc(t: ^testing.T) {
	plain := read(t, fixture(t, "v23_unicode.mp3"))
	defer odid3.destroy(&plain)
	file := fixture(t, "v23_unsync.mp3")
	tags := read(t, file)
	defer odid3.destroy(&tags)

	testing.expect_value(t, tags.warnings, odid3.Warnings{})
	testing.expect(t, .Unsynchronisation in tags.v2.flags)
	testing.expect_value(t, len(tags.v2.frames), len(plain.v2.frames))
	for &f, i in tags.v2.frames {
		want := plain.v2.frames[i]
		testing.expectf(
			t,
			f.id == want.id && bytes.equal(f.data, want.data),
			"frame %d differs",
			i,
		)
	}
	testing.expect_value(t, tags.v2.padding, plain.v2.padding)
	expect_frames_at_their_offsets(t, "v23_unsync.mp3", file, &tags.v2)
	testing.expect(t, tags.v2.frames[1].offset > plain.v2.frames[1].offset)
}

@(test)
frame_unsynchronisation_in_v24 :: proc(t: ^testing.T) {
	file := fixture(t, "v24_unsync.mp3")
	tags := read(t, file)
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.warnings, odid3.Warnings{})
	title := tags.v2.frames[0]
	testing.expect_value(
		t,
		title.format,
		odid3.Frame_Format{.Unsynchronisation, .Data_Length_Indicator},
	)
	testing.expect_value(t, title.problem, odid3.Frame_Problem.None)
	testing.expect_value(t, string(title.data), "\x01\xFF\xFEC\x00a\x00f\x00\xE9\x00")
	testing.expect_value(t, string(tags.v2.frames[1].data), "\x03Marlowe Kite")
	expect_frames_at_their_offsets(t, "v24_unsync.mp3", file, &tags.v2)
}

@(test)
v24_tag_flag_unsynchronises_every_frame :: proc(t: ^testing.T) {
	data := text("\x01\xFF\xFEA\x00")
	tags := read(t, tag_file(4, 0x80, frame(4, "TIT2", unsynchronise(data))))
	defer odid3.destroy(&tags)
	testing.expect_value(t, string(tags.v2.frames[0].data), string(data))
}

@(test)
data_length_indicator_that_does_not_match :: proc(t: ^testing.T) {
	stored := concat({0, 0, 0, 9}, text("\x03Title"))
	tags := read(t, tag_file(4, 0, frame(4, "TIT2", stored, 0, 0x01)))
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.v2.frames[0].problem, odid3.Frame_Problem.Bad_Data_Length)
	testing.expect_value(t, string(tags.v2.frames[0].data), "\x03Title")
}

@(test)
unsynchronised_extended_header_and_offsets :: proc(t: ^testing.T) {
	extended := concat({0, 0, 0, 10, 0x80, 0, 0, 0, 0, 0}, {0xFF, 0xE0, 0xFF, 0x00})
	first := frame(3, "PRIV", concat(text("a"), {0xFF, 0xFF, 0xFF, 0xF0, 0xFF, 0x00}))
	second := frame(3, "TIT2", text("\x00Title"))
	body := concat(extended, first, second)
	file := tag_file(3, 0xC0, unsynchronise(body))
	tags := read(t, file)
	defer odid3.destroy(&tags)

	testing.expect_value(t, tags.warnings, odid3.Warnings{})
	testing.expect_value(t, tags.v2.extended.crc, 0xFFE0FF00)
	testing.expect_value(t, len(tags.v2.frames), 2)
	testing.expect_value(t, string(tags.v2.frames[0].data), "a\xFF\xFF\xFF\xF0\xFF\x00")
	expect_frames_at_their_offsets(t, "synthetic", file, &tags.v2)
	testing.expect_value(
		t,
		tags.v2.frames[1].offset,
		10 + i64(len(unsynchronise(concat(extended, first)))),
	)
}

// ID3v2.4 unsynchronises the bytes the format flags add too: here a group byte of 0xFF.
@(test)
unsynchronised_group_byte :: proc(t: ^testing.T) {
	stored := unsynchronise(concat({0xFF, 0xE0}, text("p")))
	tags := read(t, tag_file(4, 0, frame(4, "PRIV", stored, 0, 0x42)))
	defer odid3.destroy(&tags)
	f := tags.v2.frames[0]
	testing.expect_value(t, f.group, 0xFF)
	testing.expect_value(t, string(f.data), "\xE0p")
}
