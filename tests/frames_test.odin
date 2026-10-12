package odid3_tests

import "core:bytes"
import "core:testing"

import odid3 "../"

@(test)
frames_written_by_ffmpeg :: proc(t: ^testing.T) {
	cases := []struct {
		name: string,
		ids:  []string,
	} {
		{"v23_full.mp3", {"TIT2", "TPE1", "TPE2", "TALB", "TYER", "TRCK", "TPOS", "TCON", "TXXX"}},
		{
			"v24_full.mp3",
			{
				"TIT2",
				"TPE1",
				"TPE2",
				"TALB",
				"TDRC",
				"TRCK",
				"TPOS",
				"TCON",
				"TXXX",
				"TPUB",
				"TXXX",
			},
		},
		{"v23_cover.mp3", {"TIT2", "TPUB", "APIC"}},
		{"v23_unicode.mp3", {"TIT2", "TPE1", "TALB"}},
		{"v24_unicode.mp3", {"TIT2", "TPE1", "TALB"}},
		{"v23_comm.mp3", {"TIT2", "COMM"}},
	}
	for c in cases {
		data := fixture(t, c.name)
		tags := read(t, data)
		defer odid3.destroy(&tags)
		testing.expectf(t, tags.warnings == {}, "%s: warnings %v", c.name, tags.warnings)
		frames := tags.v2.frames[:]
		testing.expectf(t, len(frames) == len(c.ids), "%s: %d frames", c.name, len(frames))
		for &f, i in frames {
			if i >= len(c.ids) {
				break
			}
			testing.expectf(t, f.id == c.ids[i], "%s: frame %d is %s", c.name, i, f.id)
			testing.expectf(t, f.problem == .None, "%s %s: %v", c.name, f.id, f.problem)
			header := data[f.offset:][:10]
			testing.expectf(
				t,
				string(header[:4]) == f.id,
				"%s %s: offset %d",
				c.name,
				f.id,
				f.offset,
			)
			testing.expectf(
				t,
				bytes.equal(data[f.offset + 10:][:f.size], f.data),
				"%s %s: data",
				c.name,
				f.id,
			)
		}
	}
	tags := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.v2.padding, 10)
	title := tags.v2.frames[0]
	testing.expect_value(t, string(title.data), "\x00Paper Satellites\x00")
	index, ok := odid3.find_frame(&tags.v2, "TXXX")
	testing.expect(t, ok && index == 8)
	_, ok = odid3.find_frame(&tags.v2, "TXXX", 9)
	testing.expect(t, !ok)
}

@(test)
skip_picture_data :: proc(t: ^testing.T) {
	data := fixture(t, "v23_cover.mp3")
	full := read(t, data)
	defer odid3.destroy(&full)
	skipped, err := odid3.read_bytes(data, {skip_picture_data = true})
	defer odid3.destroy(&skipped)
	testing.expect_value(t, err, nil)

	picture := full.v2.frames[2]
	testing.expect_value(t, picture.problem, odid3.Frame_Problem.None)
	testing.expect(t, bytes.has_prefix(picture.data, text("\x00image/png\x00\x03")))

	skipped_picture := skipped.v2.frames[2]
	testing.expect_value(t, skipped_picture.id, "APIC")
	testing.expect_value(t, skipped_picture.problem, odid3.Frame_Problem.Skipped_Picture)
	testing.expect(t, skipped_picture.data == nil)
	testing.expect_value(t, skipped_picture.size, picture.size)
	testing.expect_value(t, string(skipped.v2.frames[0].data), string(full.v2.frames[0].data))
}

@(test)
frame_flags_in_each_version :: proc(t: ^testing.T) {
	v23 := tag_file(
		3,
		0,
		frame(3, "TIT2", text("\x00A"), 0xE0, 0),
		frame(3, "TPE1", text("\x00B"), 0x80, 0),
	)
	tags := read(t, v23)
	testing.expect_value(
		t,
		tags.v2.frames[0].status,
		odid3.Frame_Status{.Discard_On_Tag_Alter, .Discard_On_File_Alter, .Read_Only},
	)
	testing.expect_value(t, tags.v2.frames[1].status, odid3.Frame_Status{.Discard_On_Tag_Alter})
	testing.expect_value(t, tags.v2.frames[0].stored_flags, [2]u8{0xE0, 0})
	odid3.destroy(&tags)

	v24 := tag_file(
		4,
		0,
		frame(4, "TIT2", text("\x03A"), 0x70, 0),
		frame(4, "TPE1", text("\x03B"), 0x20, 0),
	)
	tags = read(t, v24)
	testing.expect_value(
		t,
		tags.v2.frames[0].status,
		odid3.Frame_Status{.Discard_On_Tag_Alter, .Discard_On_File_Alter, .Read_Only},
	)
	testing.expect_value(t, tags.v2.frames[1].status, odid3.Frame_Status{.Discard_On_File_Alter})
	odid3.destroy(&tags)
}

@(test)
grouping_and_encryption_bytes :: proc(t: ^testing.T) {
	v23 := tag_file(3, 0, frame(3, "PRIV", concat({0x07, 0x2A}, text("payload")), 0, 0x60))
	tags := read(t, v23)
	f := tags.v2.frames[0]
	testing.expect_value(t, f.format, odid3.Frame_Format{.Encryption, .Grouping})
	testing.expect_value(t, f.method, 0x07)
	testing.expect_value(t, f.group, 0x2A)
	testing.expect_value(t, string(f.data), "payload")
	odid3.destroy(&tags)

	v24 := tag_file(
		4,
		0,
		frame(4, "PRIV", concat({0x2A, 0x07, 0, 0, 0, 7}, text("payload")), 0, 0x45),
	)
	tags = read(t, v24)
	f = tags.v2.frames[0]
	testing.expect_value(
		t,
		f.format,
		odid3.Frame_Format{.Grouping, .Encryption, .Data_Length_Indicator},
	)
	testing.expect_value(t, f.group, 0x2A)
	testing.expect_value(t, f.method, 0x07)
	testing.expect_value(t, string(f.data), "payload")
	odid3.destroy(&tags)

	too_short := tag_file(3, 0, frame(3, "TIT2", text("\x00A"), 0, 0x80))
	tags = read(t, too_short)
	f = tags.v2.frames[0]
	testing.expect_value(t, f.problem, odid3.Frame_Problem.Too_Short)
	testing.expect_value(t, string(f.data), "\x00A")
	odid3.destroy(&tags)
}

@(test)
extended_headers :: proc(t: ^testing.T) {
	title := frame(3, "TIT2", text("\x00Title"))
	with_crc := concat({0, 0, 0, 10, 0x80, 0, 0, 0, 0, 16, 0xDE, 0xAD, 0xBE, 0xEF})
	tags := read(t, tag_file(3, 0x40, with_crc, title, zeros(16)))
	testing.expect_value(t, tags.warnings, odid3.Warnings{})
	testing.expect(t, tags.v2.extended.present)
	testing.expect_value(t, tags.v2.extended.padding_size, 16)
	testing.expect_value(t, tags.v2.extended.crc, 0xDEADBEEF)
	testing.expect_value(t, tags.v2.frames[0].id, "TIT2")
	odid3.destroy(&tags)

	without_crc := concat({0, 0, 0, 6, 0, 0, 0, 0, 0, 0})
	tags = read(t, tag_file(3, 0x40, without_crc, title))
	testing.expect_value(t, tags.warnings, odid3.Warnings{})
	testing.expect(t, tags.v2.extended.crc == nil)
	testing.expect_value(t, len(tags.v2.frames), 1)
	odid3.destroy(&tags)

	title24 := frame(4, "TIT2", text("\x03Title"))
	all_flags := concat({0, 0, 0, 15, 1, 0x70, 0, 5, 0x0D, 0x7A, 0x5B, 0x3C, 0x2D, 1, 0x21})
	tags = read(t, tag_file(4, 0x40, all_flags, title24))
	testing.expect_value(t, tags.warnings, odid3.Warnings{})
	ext := tags.v2.extended
	testing.expect(t, ext.present && ext.update)
	testing.expect_value(t, ext.crc, u32(0x0D) << 28 | 0x7A << 21 | 0x5B << 14 | 0x3C << 7 | 0x2D)
	testing.expect_value(t, ext.restrictions, 0x21)
	testing.expect_value(t, tags.v2.frames[0].id, "TIT2")
	odid3.destroy(&tags)
}

@(test)
bad_extended_headers :: proc(t: ^testing.T) {
	title := frame(3, "TIT2", text("\x00Title"))
	wrong_size := concat({0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0})
	tags := read(t, tag_file(3, 0x40, wrong_size, title))
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Bad_Extended_Header})
	testing.expect_value(t, tags.v2.frames[0].id, "TIT2")
	odid3.destroy(&tags)

	huge := concat({0x7F, 0x7F, 0x7F, 0x7F, 1, 0})
	tags = read(t, tag_file(4, 0x40, huge, frame(4, "TIT2", text("\x03Title"))))
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Bad_Extended_Header})
	testing.expect_value(t, len(tags.v2.frames), 0)
	odid3.destroy(&tags)
}

@(test)
damaged_frames :: proc(t: ^testing.T) {
	title := frame(3, "TIT2", text("\x00Title"))
	tags := read(t, tag_file(3, 0, title, text("ti\x00\x00\x00\x00\x02\x00\x00\x00ab")))
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Damaged_Frames})
	testing.expect_value(t, len(tags.v2.frames), 1)
	odid3.destroy(&tags)

	too_large := concat(text("TPE1"), {0, 0, 1, 0, 0, 0}, text("abc"))
	tags = read(t, tag_file(3, 0, title, too_large))
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Damaged_Frames})
	testing.expect_value(t, len(tags.v2.frames), 1)
	odid3.destroy(&tags)

	tags = read(t, tag_file(3, 0, title, text("TPE")))
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Damaged_Frames})
	odid3.destroy(&tags)
}

@(test)
truncated_tag_keeps_the_frames_before_the_cut :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "truncated_tag.mp3"))
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Truncated_Tag})
	testing.expect_value(t, len(tags.v2.frames), 2)
	testing.expect_value(t, tags.v2.frames[1].id, "TPUB")
}

@(test)
padding_and_what_is_left_in_it :: proc(t: ^testing.T) {
	title := frame(4, "TIT2", text("\x03Title"))
	tags := read(t, tag_file(4, 0, title, zeros(100)))
	testing.expect_value(t, tags.v2.padding, 100)
	testing.expect_value(t, tags.warnings, odid3.Warnings{})
	odid3.destroy(&tags)

	junk := zeros(100)
	junk[60] = 'x'
	tags = read(t, tag_file(4, 0, title, junk))
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Data_In_Padding})
	testing.expect_value(t, tags.v2.padding, 100)
	odid3.destroy(&tags)
}

@(test)
plain_frame_sizes_written_by_itunes :: proc(t: ^testing.T) {
	// 200 is 0x000000C8, not a syncsafe number; 256 is 0x00000100, 128 read as syncsafe.
	for size in ([]int{200, 256}) {
		data := concat({3}, letters(size - 1))
		plain := concat(text("TIT2"), {0, 0, u8(size >> 8), u8(size), 0, 0}, data)
		tags := read(t, tag_file(4, 0, plain, frame(4, "TPE1", text("\x03Artist"))))
		defer odid3.destroy(&tags)
		testing.expect_value(t, tags.warnings, odid3.Warnings{.Plain_Frame_Sizes})
		testing.expect_value(t, len(tags.v2.frames), 2)
		testing.expect_value(t, len(tags.v2.frames[0].data), size)
		testing.expect_value(t, tags.v2.frames[1].id, "TPE1")
	}
}

@(test)
frame_allocation_failures_leak_nothing :: proc(t: ^testing.T) {
	data := fixture(t, "v24_full.mp3")
	for budget in 0 ..< 64 {
		f := Failing{context.allocator, budget}
		tags, err := odid3.read_bytes(data, {}, failing_allocator(&f))
		if err == nil {
			testing.expect_value(t, len(tags.v2.frames), 11)
			odid3.destroy(&tags)
			return
		}
	}
	testing.fail_now(t, "reading never succeeded")
}
