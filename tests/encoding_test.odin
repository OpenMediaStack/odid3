package odid3_tests

import "core:testing"

import odid3 "../"

@(test)
set_the_encoding_of_one_frame :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&tags)
	title := &tags.v2.frames[0]
	testing.expect_value(t, odid3.set_encoding(title, .V2_3, .UTF16), nil)
	testing.expect_value(
		t,
		string(title.data),
		"\x01\xFF\xFEP\x00a\x00p\x00e\x00r\x00 \x00S\x00a\x00t\x00e\x00l\x00l\x00i\x00t\x00e\x00s\x00",
	)
	testing.expect_value(
		t,
		odid3.set_encoding(title, .V2_3, .UTF8),
		odid3.Error(odid3.Format_Error.Encoding_Not_In_Version),
	)
	testing.expect_value(t, odid3.set_encoding(title, .V2_4, .UTF16BE), nil)
	testing.expect_value(t, tag_field(&tags.v2, .Title), "Paper Satellites")

	unicode := read(t, fixture(t, "v24_unicode.mp3"))
	defer odid3.destroy(&unicode)
	artist := &unicode.v2.frames[1]
	before := string(artist.data)
	testing.expect_value(
		t,
		odid3.set_encoding(artist, .V2_4, .Latin1),
		odid3.Error(odid3.Format_Error.Not_Encodable),
	)
	testing.expect_value(t, string(artist.data), before)
}

@(test)
set_the_encoding_of_a_whole_tag :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v23_cover.mp3"))
	defer odid3.destroy(&tags)
	before := all_fields(&tags.v2)
	testing.expect_value(t, odid3.set_encoding(&tags.v2, odid3.Encoding.UTF16), nil)
	for &f in tags.v2.frames {
		testing.expectf(t, f.data[0] == 1, "%s in encoding %d", f.id, f.data[0])
	}
	testing.expect_value(t, all_fields(&tags.v2), before)
	cover, found, _ := odid3.front_cover(&tags.v2, context.temp_allocator)
	testing.expect(t, found && cover.mime == "image/png")

	mixed := read(
		t,
		tag_file(
			4,
			0,
			frame(4, "TIT2", text("\x03Plain")),
			frame(4, "TPE1", text("\x03坂本")),
			frame(4, "PRIV", text("owner\x00\x03")),
		),
	)
	defer odid3.destroy(&mixed)
	testing.expect_value(
		t,
		odid3.set_encoding(&mixed.v2, odid3.Encoding.Latin1),
		odid3.Error(odid3.Format_Error.Not_Encodable),
	)
	testing.expect_value(t, mixed.v2.frames[0].data[0], 3)
	testing.expect_value(t, odid3.set_encoding(&mixed.v2, odid3.Encoding.UTF16BE), nil)
	testing.expect_value(t, mixed.v2.frames[0].data[0], 2)
	testing.expect_value(t, mixed.v2.frames[1].data[0], 2)
	testing.expect_value(t, string(mixed.v2.frames[2].data), "owner\x00\x03")
}

@(test)
encodings_change_nothing_else :: proc(t: ^testing.T) {
	// A frame already in the encoding keeps its bytes, BOM and terminator included.
	same := tag_file(
		3,
		0,
		frame(3, "TIT2", text("\x01\xFE\xFF\x00A")),
		frame(3, "TPE1", text("\x00Rock\x00")),
	)
	tags := read(t, same)
	defer odid3.destroy(&tags)
	before := frames_snapshot(&tags.v2)
	testing.expect_value(
		t,
		odid3.set_encoding(&tags.v2.frames[0], .V2_3, odid3.Encoding.UTF16),
		nil,
	)
	testing.expect_value(t, frames_snapshot(&tags.v2), before)

	// Several values before ID3v2.4 are joined, not cut to the first.
	several := read(t, tag_file(3, 0, frame(3, "TPE1", text("\x00A\x00B"))))
	defer odid3.destroy(&several)
	testing.expect_value(t, odid3.set_encoding(&several.v2, odid3.Encoding.UTF16), nil)
	testing.expect_value(t, tag_field(&several.v2, .Artist), "A/B")

	// A frame read with an odd ID can still be written once re-encoded.
	odd := read(
		t,
		tag_file(
			3,
			0,
			concat(text("TT2\x00"), {0, 0, 0, 3, 0, 0}, text("\x00Hi")),
			frame(3, "TPE1", text("\x00Kite")),
		),
	)
	defer odid3.destroy(&odd)
	testing.expect_value(t, odid3.set_encoding(&odd.v2, odid3.Encoding.UTF16), nil)
	_, render_err := odid3.render(&odd.v2, {}, context.temp_allocator)
	testing.expect_value(t, render_err, nil)

	// Flags stay.
	flagged := read(
		t,
		tag_file(4, 0, frame(4, "TIT2", concat({0x2A}, text("\x00Title")), 0x50, 0x40)),
	)
	defer odid3.destroy(&flagged)
	testing.expect_value(t, odid3.set_encoding(&flagged.v2, odid3.Encoding.UTF8), nil)
	f := flagged.v2.frames[0]
	testing.expect(
		t,
		f.status == {.Discard_On_Tag_Alter, .Read_Only} &&
		f.format == {.Grouping} &&
		f.group == 0x2A,
	)
	testing.expect_value(t, f.data[0], 3)
}

@(test)
text_that_would_not_survive :: proc(t: ^testing.T) {
	comment := read(t, tag_file(3, 0, frame(3, "COMM", text("\x00eng\x00line1\x00line2"))))
	defer odid3.destroy(&comment)
	testing.expect_value(
		t,
		odid3.set_encoding(&comment.v2, odid3.Encoding.UTF16),
		odid3.Error(odid3.Format_Error.Bad_Content),
	)
	lone := read(t, tag_file(3, 0, frame(3, "TALB", text("\x01\xFF\xFE\x00\xD8A\x00"))))
	defer odid3.destroy(&lone)
	testing.expect_value(
		t,
		odid3.set_encoding(&lone.v2, odid3.Encoding.Latin1),
		odid3.Error(odid3.Format_Error.Bad_Content),
	)

	undecoded := read(
		t,
		tag_file(
			3,
			0,
			frame(3, "USER", text("\x01eng\xFF\xFEH\x00i\x00")),
			frame(3, "TIT2", text("\x01\xFF\xFEA\x00")),
		),
	)
	defer odid3.destroy(&undecoded)
	testing.expect_value(
		t,
		odid3.set_encoding(&undecoded.v2.frames[0], .V2_3, odid3.Encoding.Latin1),
		odid3.Error(odid3.Format_Error.Not_Decodable),
	)
	testing.expect_value(t, odid3.set_encoding(&undecoded.v2, odid3.Encoding.Latin1), nil)
	testing.expect_value(t, undecoded.v2.frames[0].data[0], 1)
	testing.expect_value(t, undecoded.v2.frames[1].data[0], 0)

	// Empty frames and unknown encoding bytes are left as they are in a whole tag.
	odd := read(
		t,
		tag_file(
			3,
			0,
			frame(3, "TPE1", nil),
			frame(3, "TALB", text("\x07abc")),
			frame(3, "TIT2", text("\x00T")),
		),
	)
	defer odid3.destroy(&odd)
	testing.expect_value(t, odid3.set_encoding(&odd.v2, odid3.Encoding.UTF16), nil)
	testing.expect_value(t, odd.v2.frames[2].data[0], 1)
}

@(test)
frames_with_problems_and_chapters :: proc(t: ^testing.T) {
	wrong_length := frame(4, "TIT2", concat({0, 0, 0, 99}, text("\x01\xFF\xFEA\x00")), 0, 0x01)
	lying := frame(4, "TPE1", text("\x01\xFF\xFEB\x00"), 0, 0x02)
	tags := read(t, tag_file(4, 0, wrong_length, lying))
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.v2.frames[0].problem, odid3.Frame_Problem.Bad_Data_Length)
	testing.expect_value(t, odid3.set_encoding(&tags.v2, odid3.Encoding.UTF8), nil)
	testing.expect_value(t, tags.v2.frames[0].data[0], 3)
	testing.expect_value(t, tags.v2.frames[1].data[0], 3)

	inside := chapter_frame(4, "ch0", 0, 10, frame(4, "TIT2", text("\x01\xFF\xFEA\x00")))
	chapters := read(t, tag_file(4, 0, inside))
	defer odid3.destroy(&chapters)
	testing.expect_value(t, odid3.set_encoding(&chapters.v2, odid3.Encoding.Latin1), nil)
	content, err := odid3.decode_frame(&chapters.v2.frames[0], .V2_4, context.temp_allocator)
	testing.expect_value(t, err, nil)
	chapter := expect_content(t, content, odid3.Chapter)
	testing.expect(t, len(chapter.frames) == 1 && chapter.frames[0].data[0] == 0)

	cjk := chapter_frame(4, "ch0", 0, 10, frame(4, "TIT2", text("\x03坂本")))
	refused := read(t, tag_file(4, 0, cjk))
	defer odid3.destroy(&refused)
	testing.expect_value(
		t,
		odid3.set_encoding(&refused.v2, odid3.Encoding.Latin1),
		odid3.Error(odid3.Format_Error.Not_Encodable),
	)
}

@(test)
set_encoding_allocation_failures :: proc(t: ^testing.T) {
	for name in ([]string{"v23_cover.mp3", "v24_unicode.mp3", "v24_chapters.mp3"}) {
		succeeded := false
		for budget in 0 ..< 64 {
			failing := Failing{context.allocator, 1 << 30}
			tags, read_err := odid3.read_bytes(fixture(t, name), {}, failing_allocator(&failing))
			testing.expect_value(t, read_err, nil)
			before := frames_snapshot(&tags.v2)
			failing.left = budget
			err := odid3.set_encoding(&tags.v2, odid3.Encoding.UTF16)
			failing.left = 1 << 30
			if err == nil {
				succeeded = true
			} else {
				testing.expectf(
					t,
					frames_snapshot(&tags.v2) == before,
					"%s changed at budget %d",
					name,
					budget,
				)
			}
			odid3.destroy(&tags)
			if succeeded {
				break
			}
		}
		testing.expectf(t, succeeded, "%s never succeeded", name)
	}
}
