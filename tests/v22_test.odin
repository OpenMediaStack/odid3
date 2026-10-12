package odid3_tests

import "core:bytes"
import "core:testing"

import odid3 "../"

@(test)
v22_frames :: proc(t: ^testing.T) {
	file := fixture(t, "v22.mp3")
	tags := read(t, file)
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.warnings, odid3.Warnings{})
	testing.expect_value(t, tags.v2.version, odid3.V2_Version.V2_2)
	ids := []string{"TT2", "TP1", "TAL", "TYE", "TRK", "TCO", "COM"}
	testing.expect_value(t, len(tags.v2.frames), len(ids))
	for &f, i in tags.v2.frames {
		testing.expect_value(t, f.id, ids[i])
		testing.expect_value(t, string(file[f.offset:][:3]), f.id)
		testing.expect(t, bytes.equal(file[f.offset + 6:][:f.size], f.data))
		testing.expect_value(t, f.stored_flags, [2]u8{})
		testing.expect_value(t, f.status, odid3.Frame_Status{})
		testing.expect_value(t, f.format, odid3.Frame_Format{})
	}
	testing.expect_value(t, string(tags.v2.frames[0].data), "\x00Paper Satellites")
	testing.expect_value(t, tags.v2.frames[0].size, 17)
	testing.expect_value(t, string(tags.v2.frames[5].data), "\x00(17)")
	testing.expect_value(t, tags.v2.padding, 0)
}

@(test)
v22_picture :: proc(t: ^testing.T) {
	file := fixture(t, "v22_pic.mp3")
	tags := read(t, file)
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.warnings, odid3.Warnings{})
	if len(tags.v2.frames) != 2 {
		testing.fail_now(t, "two frames expected")
	}
	picture := tags.v2.frames[1]
	testing.expect_value(t, picture.id, "PIC")
	testing.expect_value(t, picture.size, 102)
	testing.expect(t, bytes.has_prefix(picture.data, text("\x00PNG\x03\x00\x89PNG")))

	skipped, err := odid3.read_bytes(file, {skip_picture_data = true})
	defer odid3.destroy(&skipped)
	testing.expect_value(t, err, nil)
	if len(skipped.v2.frames) != 2 {
		testing.fail_now(t, "two frames expected")
	}
	testing.expect_value(t, skipped.v2.frames[1].problem, odid3.Frame_Problem.Skipped_Picture)
	testing.expect(t, skipped.v2.frames[1].data == nil)
	testing.expect_value(t, string(skipped.v2.frames[0].data), "\x00With a picture")
}

@(test)
compressed_v22_tag_cannot_be_read :: proc(t: ^testing.T) {
	tags := read(t, tag_file(2, 0x40, frame22("TT2", text("\x00Title"))))
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Compressed_V22_Tag})
	testing.expect_value(t, tags.v2.version, odid3.V2_Version.V2_2)
	testing.expect_value(t, tags.v2.flags, odid3.Tag_Flags{.Compression})
	testing.expect_value(t, len(tags.v2.frames), 0)
}

@(test)
unsynchronised_v22_tag :: proc(t: ^testing.T) {
	body := concat(frame22("TT2", text("\x01\xFF\xFEA\x00")), frame22("TP1", text("\x00Artist")))
	file := tag_file(2, 0x80, unsynchronise(body))
	tags := read(t, file)
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.warnings, odid3.Warnings{})
	testing.expect_value(t, string(tags.v2.frames[0].data), "\x01\xFF\xFEA\x00")
	testing.expect_value(t, string(tags.v2.frames[1].data), "\x00Artist")
	testing.expect_value(t, string(file[tags.v2.frames[1].offset:][:3]), "TP1")
}

@(test)
damaged_v22_frames :: proc(t: ^testing.T) {
	title := frame22("TT2", text("\x00Title"))
	tags := read(t, tag_file(2, 0, title, text("tp1\x00\x00\x02ab")))
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Damaged_Frames})
	testing.expect_value(t, len(tags.v2.frames), 1)
	odid3.destroy(&tags)

	tags = read(t, tag_file(2, 0, title, text("TP1\x01\x00\x00ab")))
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Damaged_Frames})
	testing.expect_value(t, len(tags.v2.frames), 1)
	odid3.destroy(&tags)
}

@(test)
v22_padding_odd_ids_and_empty_frames :: proc(t: ^testing.T) {
	title := frame22("TT2", text("\x00Title"))
	padded := read(t, tag_file(2, 0, title, frame22("TP1", nil), zeros(64)))
	testing.expect_value(t, padded.warnings, odid3.Warnings{})
	testing.expect_value(t, len(padded.v2.frames), 2)
	testing.expect_value(t, len(padded.v2.frames[1].data), 0)
	testing.expect_value(t, padded.v2.padding, 64)
	odid3.destroy(&padded)

	odd := concat(text("TT\x00"), {0, 0, 2}, text("\x00x"))
	tags := read(t, tag_file(2, 0, odd, title))
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Bad_Frame_Ids})
	testing.expect_value(t, len(tags.v2.frames), 2)
	testing.expect_value(t, tags.v2.frames[0].id, "TT\x00")
	odid3.destroy(&tags)

	v23_frames := read(t, tag_file(2, 0, frame(3, "TIT2", text("\x00Title"))))
	testing.expect_value(t, v23_frames.warnings, odid3.Warnings{.Damaged_Frames})
	odid3.destroy(&v23_frames)

	v22_frames := read(t, tag_file(3, 0, title))
	testing.expect_value(t, v22_frames.warnings, odid3.Warnings{.Damaged_Frames})
	odid3.destroy(&v22_frames)
}

// iTunes wrote ID3v2.2's PIC, with a NUL, in some ID3v2.3 tags.
@(test)
itunes_pictures_in_v23_are_skipped :: proc(t: ^testing.T) {
	picture := concat(text("PIC\x00"), {0, 0, 0, 6, 0, 0}, text("\x00PNG\x03\x00"))
	tags, err := odid3.read_bytes(tag_file(3, 0, picture), {skip_picture_data = true})
	defer odid3.destroy(&tags)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, tags.v2.frames[0].problem, odid3.Frame_Problem.Skipped_Picture)
}
