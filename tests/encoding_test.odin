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
