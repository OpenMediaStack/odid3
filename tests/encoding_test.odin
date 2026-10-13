package odid3_tests

import "core:bytes"
import "core:mem"
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

// A frame whose text would not survive re-encoding, in a tag of version major: set_encoding on the
// tag and the write options leave it as it is and change a title beside it as they would alone,
// while set_encoding on that frame alone gives .Bad_Content. The byte order only reaches a frame in
// UTF-16 with a byte order mark.
expect_left_as_is :: proc(
	t: ^testing.T,
	major: u8,
	kept: []u8,
	encoding: odid3.Encoding,
	order: odid3.Byte_Order,
	loc := #caller_location,
) {
	expect_kept :: proc(
		t: ^testing.T,
		tag, alone: ^odid3.Tag,
		id: string,
		data: []u8,
		loc := #caller_location,
	) {
		testing.expectf(
			t,
			len(tag.frames) == 2 &&
			len(alone.frames) == 1 &&
			tag.frames[0].id == id &&
			bytes.equal(tag.frames[0].data, data) &&
			bytes.equal(tag.frames[1].data, alone.frames[0].data),
			"%x: %d frames",
			data,
			len(tag.frames),
			loc = loc,
		)
	}
	other_order := odid3.Byte_Order.Big_Endian if order == .Little_Endian else .Little_Endian
	in_utf16 := concat({1}, utf16("T", other_order))
	title := frame22("TT2", in_utf16) if major == 2 else frame(major, "TIT2", in_utf16)
	id := string(kept[:3]) if major == 2 else string(kept[:4])
	data := kept[6:] if major == 2 else kept[10:]
	both := read(t, tag_file(major, 0, kept, title), loc)
	defer odid3.destroy(&both)
	alone := read(t, tag_file(major, 0, title), loc)
	defer odid3.destroy(&alone)
	for options in ([]odid3.Write_Options{{encoding = encoding}, {utf16_byte_order = order}}) {
		written, err := odid3.render(&both.v2, options, context.temp_allocator)
		testing.expect_value(t, err, nil, loc = loc)
		wanted, wanted_err := odid3.render(&alone.v2, options, context.temp_allocator)
		testing.expect_value(t, wanted_err, nil, loc = loc)
		again := read(t, written, loc)
		defer odid3.destroy(&again)
		title_alone := read(t, wanted, loc)
		defer odid3.destroy(&title_alone)
		expect_kept(t, &again.v2, &title_alone.v2, id, data, loc)
	}
	bad := odid3.Error(odid3.Format_Error.Bad_Content)
	before := frames_snapshot(&both.v2)
	refused := &both.v2.frames[0]
	testing.expect_value(t, odid3.set_encoding(refused, both.v2.version, encoding), bad, loc = loc)
	if data[0] == 1 {
		testing.expect_value(
			t,
			odid3.set_encoding(refused, both.v2.version, .UTF16, order),
			bad,
			loc = loc,
		)
	}
	testing.expect_value(t, frames_snapshot(&both.v2), before, loc = loc)
	testing.expect_value(t, odid3.set_encoding(&both.v2, encoding, order), nil, loc = loc)
	testing.expect_value(t, odid3.set_encoding(&alone.v2, encoding, order), nil, loc = loc)
	expect_kept(t, &both.v2, &alone.v2, id, data, loc)
}

@(test)
text_that_would_not_survive :: proc(t: ^testing.T) {
	expect_left_as_is(
		t,
		3,
		frame(3, "COMM", text("\x00eng\x00line1\x00line2")),
		.UTF16,
		.Big_Endian,
	)
	expect_left_as_is(
		t,
		3,
		frame(3, "TALB", text("\x01\xFF\xFE\x00\xD8A\x00")),
		.Latin1,
		.Big_Endian,
	)

	// Inside a chapter too.
	album := frame(4, "TALB", text("\x01\xFF\xFE\x00\xD8A\x00"))
	title := frame(4, "TIT2", text("\x01\xFF\xFEA\x00"))
	chapters := read(t, tag_file(4, 0, chapter_frame(4, "ch0", 0, 10, album, title)))
	defer odid3.destroy(&chapters)
	encoded, err := odid3.render(&chapters.v2, {encoding = .Latin1}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	ordered, order_err := odid3.render(
		&chapters.v2,
		{utf16_byte_order = .Big_Endian},
		context.temp_allocator,
	)
	testing.expect_value(t, order_err, nil)
	testing.expect_value(t, odid3.set_encoding(&chapters.v2, odid3.Encoding.Latin1), nil)
	latin1 := read(t, encoded)
	defer odid3.destroy(&latin1)
	big := read(t, ordered)
	defer odid3.destroy(&big)
	results := []struct {
		tag:   ^odid3.Tag,
		title: string,
	}{{&chapters.v2, "\x00A"}, {&latin1.v2, "\x00A"}, {&big.v2, "\x01\xFE\xFF\x00A"}}
	for r in results {
		if !testing.expect_value(t, len(r.tag.frames), 1) {
			continue
		}
		chapter := expect_content(t, decode(t, &r.tag.frames[0], .V2_4), odid3.Chapter)
		testing.expect(
			t,
			len(chapter.frames) == 2 &&
			bytes.equal(chapter.frames[0].data, album[10:]) &&
			string(chapter.frames[1].data) == r.title,
		)
	}

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
bytes_after_a_url_are_not_lost :: proc(t: ^testing.T) {
	junk := concat({1}, utf16("", .Little_Endian), {0, 0}, text("http://x\x00junk"))
	expect_left_as_is(t, 3, frame(3, "WXXX", junk), .Latin1, .Big_Endian)
	expect_left_as_is(t, 2, frame22("WXX", junk), .Latin1, .Big_Endian)

	// A terminator alone after the URL holds nothing.
	ended := read(
		t,
		tag_file(
			3,
			0,
			frame(3, "WXXX", concat({1}, utf16("", .Little_Endian), {0, 0}, text("http://x\x00"))),
		),
	)
	defer odid3.destroy(&ended)
	testing.expect_value(t, odid3.set_encoding(&ended.v2, odid3.Encoding.Latin1), nil)
	testing.expect_value(t, string(ended.v2.frames[0].data), "\x00\x00http://x")
}

@(test)
odd_utf16_bytes_and_nuls_after_the_text :: proc(t: ^testing.T) {
	// Decoding drops the odd last byte of a UTF-16 string, so it is lost unless it is a NUL, which
	// some writers end UTF-16 text with in place of two.
	odd_bytes := [?][]u8 {
		frame(4, "TIT2", {0x02, 0x00, 'A', 'B'}),
		frame(4, "TPE1", text("\x01\xFF\xFEA\x00B")),
		frame(4, "TXXX", concat({1}, utf16("d", .Little_Endian), {0, 0}, text("A\x00B"))),
		frame(4, "COMM", concat({2}, text("eng"), {0x00, 'd', 0, 0, 0x00, 'A', 'B'})),
		frame(4, "TPE2", text("\x01\xFF\xFEA\x00\x00\x00B")),
		frame(4, "COMM", concat({1}, text("eng"), utf16("d", .Little_Endian), {'B'})),
		// Text after NULs is no terminator.
		frame(4, "COMM", text("\x03engd\x00text\x00\x00X")),
		frame(4, "USLT", text("\x03engd\x00lyrics\x00X")),
		frame(4, "WXXX", text("\x03d\x00http://x\x00\x00X")),
	}
	for odd in odd_bytes {
		expect_left_as_is(t, 4, odd, .Latin1, .Big_Endian)
	}

	// An odd last NUL, and NULs alone after a comment or a URL (such as a doubled terminator),
	// hold nothing either.
	nothing_lost := [?]struct {
		frame: []u8,
		want:  string,
	} {
		{frame(4, "TIT2", {0x02, 0x00, 'A', 0x00}), "\x00A"},
		{frame(4, "TPE1", text("\x01\xFF\xFEA\x00\x00")), "\x00A"},
		{
			frame(4, "COMM", concat({2}, text("eng"), {0x00, 'd', 0, 0, 0x00, 'A', 0x00})),
			"\x00engd\x00A",
		},
		{frame(4, "COMM", text("\x03engd\x00text\x00\x00")), "\x00engd\x00text"},
		{
			frame(
				4,
				"COMM",
				concat(
					{1},
					text("eng"),
					utf16("d", .Little_Endian),
					{0, 0},
					utf16("c", .Little_Endian),
					zeros(5),
				),
			),
			"\x00engd\x00c",
		},
		{frame(4, "WXXX", text("\x03site\x00http://x\x00\x00")), "\x00site\x00http://x"},
	}
	for c in nothing_lost {
		tags := read(t, tag_file(4, 0, c.frame))
		defer odid3.destroy(&tags)
		testing.expect_value(t, odid3.set_encoding(&tags.v2, odid3.Encoding.Latin1), nil)
		testing.expect_value(t, string(tags.v2.frames[0].data), c.want)
	}
}

@(test)
a_real_replacement_character_survives :: proc(t: ^testing.T) {
	// U+FFFD written as it should be (FD FF or FF FD) is a character like any other. Strings
	// without a byte order mark follow a big endian first string, where 00 D8 is "Ø".
	frames := concat(
		frame(4, "TIT2", concat({1}, utf16("A\uFFFD", .Little_Endian))),
		frame(4, "TPE1", concat({1}, utf16("B", .Big_Endian), {0, 0, 0xFF, 0xFD, 0x00, 0xD8})),
		frame(4, "TXXX", concat({1}, utf16("\uFFFD", .Big_Endian), {0, 0, 0x00, 0xD8})),
		frame(
			4,
			"COMM",
			concat({1}, text("eng"), utf16("d", .Big_Endian), {0, 0, 0xFF, 0xFD, 0x00, 0xD8}),
		),
		frame(4, "WXXX", concat({1}, utf16("\uFFFD", .Little_Endian), {0, 0}, text("http://x"))),
		frame(
			4,
			"APIC",
			concat(
				{1},
				text("image/png\x00\x03"),
				utf16("\uFFFD", .Big_Endian),
				{0, 0, 0x89, 'P', 'N', 'G'},
			),
		),
	)
	in_utf8 := [?]string {
		"\x03A\uFFFD",
		"\x03B\x00\uFFFDØ",
		"\x03\uFFFD\x00Ø",
		"\x03engd\x00\uFFFDØ",
		"\x03\uFFFD\x00http://x",
		"\x03image/png\x00\x03\uFFFD\x00\x89PNG",
	}
	expect_utf8 :: proc(t: ^testing.T, tag: ^odid3.Tag, want: []string, loc := #caller_location) {
		testing.expect_value(t, odid3.set_encoding(tag, odid3.Encoding.UTF8), nil, loc = loc)
		testing.expect_value(t, len(tag.frames), len(want), loc = loc)
		for f, i in tag.frames[:min(len(tag.frames), len(want))] {
			testing.expectf(t, string(f.data) == want[i], "%s: %x", f.id, f.data, loc = loc)
		}
	}

	tags := read(t, tag_file(4, 0, frames))
	defer odid3.destroy(&tags)
	written, err := odid3.render(&tags.v2, {encoding = .UTF8}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	again := read(t, concat(written, fixture(t, "no_tag.mp3")))
	defer odid3.destroy(&again)
	expect_utf8(t, &again.v2, in_utf8[:])
	expect_utf8(t, &tags.v2, in_utf8[:])

	for order in odid3.Byte_Order {
		swapped := read(t, tag_file(4, 0, frames))
		defer odid3.destroy(&swapped)
		testing.expect_value(t, odid3.set_encoding(&swapped.v2, .UTF16, order), nil)
		expect_utf8(t, &swapped.v2, in_utf8[:])

		original := read(t, tag_file(4, 0, frames))
		defer odid3.destroy(&original)
		rendered, render_err := odid3.render(
			&original.v2,
			{utf16_byte_order = order},
			context.temp_allocator,
		)
		testing.expect_value(t, render_err, nil)
		read_back := read(t, concat(rendered, fixture(t, "no_tag.mp3")))
		defer odid3.destroy(&read_back)
		expect_utf8(t, &read_back.v2, in_utf8[:])
	}

	// D8 00 after a big endian first string is a surrogate without its pair, though it would be
	// "Ø" in little endian; a real U+FFFD does not make one survive. Descriptions are checked too.
	unpaired := []u8{0xFE, 0xFF, 0xD8, 0x00}
	png := []u8{0, 0, 0x89, 'P', 'N', 'G'}
	lone_surrogates := [?][]u8 {
		frame(4, "TPE1", concat({1}, utf16("B", .Big_Endian), {0, 0, 0xD8, 0x00})),
		frame(4, "COMM", concat({1}, text("eng"), utf16("d", .Big_Endian), {0, 0, 0xD8, 0x00})),
		frame(4, "TIT2", concat({1}, utf16("\uFFFD", .Big_Endian), {0xD8, 0x00})),
		frame(4, "TXXX", concat({1}, unpaired, {0, 0}, utf16("v", .Big_Endian))),
		frame(4, "WXXX", concat({1}, unpaired, {0, 0}, text("http://x"))),
		frame(4, "COMM", concat({1}, text("eng"), unpaired, {0, 0}, utf16("c", .Big_Endian))),
		frame(4, "APIC", concat({1}, text("image/png\x00\x03"), unpaired, png)),
	}
	for lone in lone_surrogates {
		expect_left_as_is(t, 4, lone, .UTF8, .Little_Endian)
	}
	// Little endian, so that reading one byte off would find no surrogate.
	unpaired_le := []u8{0xFF, 0xFE, 0x00, 0xD8}
	picture := frame22("PIC", concat({1}, text("PNG\x03"), unpaired_le, png))
	expect_left_as_is(t, 2, picture, .Latin1, .Big_Endian)
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

	// What render keeps in a frame read at top level, an encoding byte above 3 or an odd ID, it
	// keeps inside a chapter too, while set_encoding and the write options change the frames
	// beside it; so does UTF-8 in ID3v2.3 when only the byte order of UTF-16 changes.
	odd := chapter_frame(
		3,
		"ch0",
		0,
		10,
		frame(3, "TALB", text("\x07abc")),
		frame(3, "TT2\x00", text("\x00T")),
		frame(3, "TIT2", text("\x00T")),
	)
	unknown := read(t, tag_file(3, 0, odd))
	defer odid3.destroy(&unknown)
	rendered, option_err := odid3.render(&unknown.v2, {encoding = .UTF16}, context.temp_allocator)
	testing.expect_value(t, option_err, nil)
	written := read(t, rendered)
	defer odid3.destroy(&written)
	testing.expect_value(t, odid3.set_encoding(&unknown.v2, odid3.Encoding.UTF16), nil)
	for tag in ([]^odid3.Tag{&written.v2, &unknown.v2}) {
		if !testing.expect_value(t, len(tag.frames), 1) {
			continue
		}
		chapter = expect_content(t, decode(t, &tag.frames[0], .V2_3), odid3.Chapter)
		testing.expect(
			t,
			len(chapter.frames) == 3 &&
			string(chapter.frames[0].data) == "\x07abc" &&
			chapter.frames[1].id == "TT2\x00" &&
			string(chapter.frames[1].data) == "\x01\xFF\xFET\x00" &&
			string(chapter.frames[2].data) == "\x01\xFF\xFET\x00",
		)
	}
	little := frame(3, "TIT2", concat({1}, utf16("T", .Little_Endian)))
	utf8 := read(
		t,
		tag_file(3, 0, chapter_frame(3, "ch0", 0, 10, frame(3, "TALB", text("\x03abc")), little)),
	)
	defer odid3.destroy(&utf8)
	ordered, order_err := odid3.render(
		&utf8.v2,
		{utf16_byte_order = .Big_Endian},
		context.temp_allocator,
	)
	testing.expect_value(t, order_err, nil)
	big := read(t, ordered)
	defer odid3.destroy(&big)
	if !testing.expect_value(t, len(big.v2.frames), 1) {
		return
	}
	chapter = expect_content(t, decode(t, &big.v2.frames[0], .V2_3), odid3.Chapter)
	testing.expect(
		t,
		len(chapter.frames) == 2 &&
		string(chapter.frames[0].data) == "\x03abc" &&
		string(chapter.frames[1].data) == "\x01\xFE\xFF\x00T",
	)
}

@(test)
undecodable_chapters_keep_their_bytes :: proc(t: ^testing.T) {
	// A CHAP or CTOC whose content does not decode holds no text odid3 can find: set_encoding and
	// the write options leave it as it is, and change the frames beside it.
	for major in ([]u8{3, 4}) {
		title := frame(major, "TIT2", concat({1}, utf16("T", .Little_Endian)))
		for chapter in undecodable_chapters(major) {
			tags := read(t, tag_file(major, 0, chapter, title))
			defer odid3.destroy(&tags)
			encoded, encoding_err := odid3.render(
				&tags.v2,
				{encoding = .Latin1},
				context.temp_allocator,
			)
			testing.expect_value(t, encoding_err, nil)
			ordered, order_err := odid3.render(
				&tags.v2,
				{utf16_byte_order = .Big_Endian},
				context.temp_allocator,
			)
			testing.expect_value(t, order_err, nil)
			testing.expect_value(t, odid3.set_encoding(&tags.v2, odid3.Encoding.Latin1), nil)
			latin1 := read(t, encoded)
			defer odid3.destroy(&latin1)
			big := read(t, ordered)
			defer odid3.destroy(&big)
			results := []struct {
				tag:   ^odid3.Tag,
				title: string,
			}{{&tags.v2, "\x00T"}, {&latin1.v2, "\x00T"}, {&big.v2, "\x01\xFE\xFF\x00T"}}
			for r in results {
				frames := r.tag.frames[:]
				testing.expectf(
					t,
					len(frames) == 2 &&
					frames[0].id == string(chapter[:4]) &&
					bytes.equal(frames[0].data, chapter[10:]) &&
					string(frames[1].data) == r.title,
					"%q in ID3v2.%d: %d frames",
					string(chapter),
					major,
					len(frames),
				)
			}
		}
	}
}

@(test)
undecodable_layouts_keep_their_bytes :: proc(t: ^testing.T) {
	// A COMM, USLT or APIC whose data does not follow its layout holds no text odid3 can find:
	// set_encoding on the tag and the write options leave it as it is, and change the frames beside
	// it, while set_encoding on that frame alone refuses it.
	Damaged :: struct {
		major:    u8,
		id, data: string,
	}
	Expected :: struct {
		tag:   ^odid3.Tag,
		title: string,
	}
	damaged := []Damaged {
		{2, "COM", "\x00en"},
		{2, "ULT", "\x01en"},
		{2, "PIC", "\x00PN"},
		{2, "PIC", "\x01PNG"},
		{2, "PIC", "\x00PNG\x03cover"},
		{3, "COMM", "\x00en"},
		{3, "COMM", "\x01"},
		{3, "USLT", "\x01en"},
		{3, "APIC", "\x00image/png"},
		{3, "APIC", "\x01image/png\x00"},
		{3, "APIC", "\x00image/png\x00\x03cover"},
		{4, "COMM", "\x00en"},
		{4, "USLT", "\x01en"},
		{4, "APIC", "\x00image/png"},
		{4, "APIC", "\x01image/png\x00"},
	}
	for d in damaged {
		title := concat({1}, utf16("T", .Little_Endian))
		body: []u8
		if d.major == 2 {
			body = concat(frame22(d.id, text(d.data)), frame22("TT2", title))
		} else {
			body = concat(frame(d.major, d.id, text(d.data)), frame(d.major, "TIT2", title))
		}
		tags := read(t, tag_file(d.major, 0, body))
		defer odid3.destroy(&tags)
		// Every call reaches the damaged frame: the encoding asked is not its own, or its UTF-16 is
		// in the other byte order.
		other := odid3.Encoding.UTF16 if d.data[0] == 0 else .Latin1
		encoded, encoding_err := odid3.render(&tags.v2, {encoding = other}, context.temp_allocator)
		testing.expect_value(t, encoding_err, nil)
		ordered, order_err := odid3.render(
			&tags.v2,
			{utf16_byte_order = .Big_Endian},
			context.temp_allocator,
		)
		testing.expect_value(t, order_err, nil)
		testing.expect_value(
			t,
			odid3.set_encoding(&tags.v2.frames[0], tags.v2.version, other),
			odid3.Error(odid3.Format_Error.Bad_Content),
		)
		testing.expect_value(t, odid3.set_encoding(&tags.v2, other), nil)
		reencoded := read(t, encoded)
		defer odid3.destroy(&reencoded)
		big := read(t, ordered)
		defer odid3.destroy(&big)
		in_other := "\x00T" if other == .Latin1 else string(title)
		results := []Expected {
			{&tags.v2, in_other},
			{&reencoded.v2, in_other},
			{&big.v2, "\x01\xFE\xFF\x00T"},
		}
		for r in results {
			frames := r.tag.frames[:]
			testing.expectf(
				t,
				len(frames) == 2 &&
				frames[0].id == d.id &&
				string(frames[0].data) == d.data &&
				string(frames[1].data) == r.title,
				"%s %q in ID3v2.%d: %d frames",
				d.id,
				d.data,
				d.major,
				len(frames),
			)
		}
	}

	// Inside a chapter too; the damaged APIC is in UTF-16, so that Latin-1 reaches it.
	picture := frame(4, "APIC", text("\x01image/png\x00"))
	inside := frame(4, "TIT2", concat({1}, utf16("T", .Little_Endian)))
	chapters := read(t, tag_file(4, 0, chapter_frame(4, "ch0", 0, 10, picture, inside)))
	defer odid3.destroy(&chapters)
	encoded, encoding_err := odid3.render(
		&chapters.v2,
		{encoding = .Latin1},
		context.temp_allocator,
	)
	testing.expect_value(t, encoding_err, nil)
	ordered, order_err := odid3.render(
		&chapters.v2,
		{utf16_byte_order = .Big_Endian},
		context.temp_allocator,
	)
	testing.expect_value(t, order_err, nil)
	testing.expect_value(t, odid3.set_encoding(&chapters.v2, odid3.Encoding.Latin1), nil)
	latin1 := read(t, encoded)
	defer odid3.destroy(&latin1)
	big := read(t, ordered)
	defer odid3.destroy(&big)
	results := []Expected {
		{&chapters.v2, "\x00T"},
		{&latin1.v2, "\x00T"},
		{&big.v2, "\x01\xFE\xFF\x00T"},
	}
	for r in results {
		if !testing.expect_value(t, len(r.tag.frames), 1) {
			continue
		}
		chapter := expect_content(t, decode(t, &r.tag.frames[0], .V2_4), odid3.Chapter)
		testing.expect(
			t,
			len(chapter.frames) == 2 &&
			string(chapter.frames[0].data) == "\x01image/png\x00" &&
			string(chapter.frames[1].data) == r.title,
		)
	}
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

@(test)
encoding_as_a_write_option :: proc(t: ^testing.T) {
	for c in ([]struct {
			name:     string,
			encoding: odid3.Encoding,
		}{{"v23_full.mp3", .UTF16}, {"v23_unicode.mp3", .UTF16}, {"v24_full.mp3", .UTF16BE}, {"v24_unicode.mp3", .UTF8}, {"v24_unicode.mp3", .Latin1}}) {
		tags := read(t, fixture(t, c.name))
		defer odid3.destroy(&tags)
		before := all_fields(&tags.v2)
		data := make([][]u8, len(tags.v2.frames), context.temp_allocator)
		for f, i in tags.v2.frames {
			data[i] = f.data
		}
		rendered, err := odid3.render(&tags.v2, {encoding = c.encoding}, context.temp_allocator)
		if c.encoding == .Latin1 {
			// Not every character of the unicode fixture fits in Latin-1: nothing is written.
			testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Not_Encodable))
			continue
		}
		testing.expect_value(t, err, nil)
		for f, i in tags.v2.frames {
			testing.expectf(
				t,
				raw_data(f.data) == raw_data(data[i]),
				"%s: the tag changed",
				c.name,
			)
		}
		again := read(t, concat(rendered, fixture(t, "no_tag.mp3")))
		defer odid3.destroy(&again)
		testing.expect_value(t, all_fields(&again.v2), before)
		for &f in again.v2.frames {
			content, decode_err := odid3.decode_frame(&f, again.v2.version, context.temp_allocator)
			if text, is_text := content.(odid3.Text); is_text && decode_err == nil {
				testing.expectf(
					t,
					text.encoding == c.encoding,
					"%s: %s in %v",
					c.name,
					f.id,
					text.encoding,
				)
			}
		}
	}

	tags := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&tags)
	_, err := odid3.render(&tags.v2, {encoding = .UTF8}, context.temp_allocator)
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Encoding_Not_In_Version))
}

@(test)
encoding_option_with_other_options :: proc(t: ^testing.T) {
	// Extra terminators give empty values, which are not joined.
	tags := read(
		t,
		tag_file(
			3,
			0,
			frame(3, "TIT2", text("\x00Title\x00\x00")),
			frame(3, "TALB", text("\x00Album\x00\x00\x00")),
		),
	)
	defer odid3.destroy(&tags)
	options := odid3.Write_Options {
		encoding          = .UTF16,
		unsynchronisation = true,
		compression       = true,
		padding           = 0,
	}
	rendered, err := odid3.render(&tags.v2, options, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, rendered[5], 0x80)
	again := read(t, concat(rendered, fixture(t, "no_tag.mp3")))
	defer odid3.destroy(&again)
	testing.expect_value(t, tag_field(&again.v2, .Title), "Title")
	testing.expect_value(t, tag_field(&again.v2, .Album), "Album")
	for f in again.v2.frames {
		testing.expectf(t, .Compression in f.format, "%s: %v", f.id, f.format)
	}

	_, err = odid3.render(&tags.v2, {encoding = .UTF16, footer = true}, context.temp_allocator)
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Not_In_Version))

	v22 := read(t, fixture(t, "v22.mp3"))
	defer odid3.destroy(&v22)
	_, err = odid3.render(&v22.v2, {encoding = .UTF8}, context.temp_allocator)
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Encoding_Not_In_Version))
	rendered, err = odid3.render(&v22.v2, {encoding = .UTF16}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	again22 := read(t, concat(rendered, fixture(t, "no_tag.mp3")))
	defer odid3.destroy(&again22)
	testing.expect_value(t, all_fields(&again22.v2), all_fields(&v22.v2))
}

@(test)
encoding_option_reaches_every_text :: proc(t: ^testing.T) {
	for name in ([]string{"v23_full.mp3", "v24_chapters.mp3"}) {
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		rendered, err := odid3.render(&tags.v2, {encoding = .UTF16}, context.temp_allocator)
		testing.expect_value(t, err, nil)
		again := read(t, concat(rendered, fixture(t, "no_tag.mp3")))
		defer odid3.destroy(&again)
		check :: proc(t: ^testing.T, frames: []odid3.Frame, version: odid3.V2_Version) {
			for &f in frames {
				content, err := odid3.decode_frame(&f, version, context.temp_allocator)
				testing.expectf(t, err == nil, "%s: %v", f.id, err)
				encoding := odid3.Encoding.UTF16
				#partial switch c in content {
				case odid3.Text:
					encoding = c.encoding
				case odid3.User_Text:
					encoding = c.encoding
				case odid3.Comment:
					encoding = c.encoding
				case odid3.Picture:
					encoding = c.encoding
				case odid3.Chapter:
					check(t, c.frames[:], version)
				case odid3.Table_Of_Contents:
					check(t, c.frames[:], version)
				}
				testing.expectf(t, encoding == .UTF16, "%s in %v", f.id, encoding)
			}
		}
		check(t, again.v2.frames[:], again.v2.version)
	}
}

@(test)
encoding_option_allocation_failures :: proc(t: ^testing.T) {
	for name in ([]string{"v23_full.mp3", "v24_chapters.mp3"}) {
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		rendered := false
		for budget in 0 ..< 256 {
			failing := Failing{context.allocator, budget}
			allocator := failing_allocator(&failing)
			bytes, err := odid3.render(&tags.v2, {encoding = .UTF16}, allocator)
			if err == nil {
				delete(bytes, allocator)
				rendered = true
				break
			}
			testing.expectf(
				t,
				err == odid3.Error(mem.Allocator_Error.Out_Of_Memory),
				"%s: %v",
				name,
				err,
			)
		}
		testing.expectf(t, rendered, "%s never rendered", name)
	}
}

// The byte order mark of a UTF-16 text frame, or 0 when it has none.
text_frame_mark :: proc(f: odid3.Frame) -> (mark: u16) {
	if len(f.data) >= 3 && f.data[0] == u8(odid3.Encoding.UTF16) {
		mark = u16(f.data[1]) << 8 | u16(f.data[2])
	}
	return
}

@(test)
utf16_byte_order :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&tags)
	before := all_fields(&tags.v2)

	// In place: every text frame in big endian UTF-16, then left so without an order.
	testing.expect_value(t, odid3.set_encoding(&tags.v2, .UTF16, odid3.Byte_Order.Big_Endian), nil)
	marks := 0
	for f in tags.v2.frames {
		if f.id[0] == 'T' {
			testing.expectf(t, text_frame_mark(f) == 0xFEFF, "%s: %x", f.id, f.data)
			marks += 1
		}
	}
	testing.expect(t, marks > 0)
	testing.expect_value(t, all_fields(&tags.v2), before)
	big, big_err := odid3.render(&tags.v2, {padding = 0}, context.temp_allocator)
	testing.expect_value(t, big_err, nil)
	testing.expect_value(t, odid3.set_encoding(&tags.v2, .UTF16), nil)
	same, same_err := odid3.render(&tags.v2, {padding = 0}, context.temp_allocator)
	testing.expect_value(t, same_err, nil)
	testing.expect(t, bytes.equal(big, same))

	// On write: the tags stay big endian, the bytes are little endian.
	little, err := odid3.render(
		&tags.v2,
		{padding = 0, utf16_byte_order = .Little_Endian},
		context.temp_allocator,
	)
	testing.expect_value(t, err, nil)
	again := read(t, concat(little, fixture(t, "no_tag.mp3")))
	defer odid3.destroy(&again)
	testing.expect_value(t, all_fields(&again.v2), before)
	for f in again.v2.frames {
		if f.id[0] == 'T' {
			testing.expectf(t, text_frame_mark(f) == 0xFFFE, "%s: %x", f.id, f.data)
		}
	}
	for f in tags.v2.frames {
		if f.id[0] == 'T' {
			testing.expectf(t, text_frame_mark(f) == 0xFEFF, "%s changed", f.id)
		}
	}

	// One frame, and the order with another encoding.
	title := &again.v2.frames[0]
	testing.expect_value(
		t,
		odid3.set_encoding(title, .V2_3, .UTF16, odid3.Byte_Order.Big_Endian),
		nil,
	)
	testing.expect_value(t, text_frame_mark(title^), 0xFEFF)
	latin1 := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&latin1)
	rendered, render_err := odid3.render(
		&latin1.v2,
		{encoding = .UTF16, utf16_byte_order = .Big_Endian},
		context.temp_allocator,
	)
	testing.expect_value(t, render_err, nil)
	big_again := read(t, concat(rendered, fixture(t, "no_tag.mp3")))
	defer odid3.destroy(&big_again)
	testing.expect_value(t, all_fields(&big_again.v2), before)
	testing.expect_value(t, text_frame_mark(big_again.v2.frames[0]), 0xFEFF)
}

// s in UTF-16 after its byte order mark.
utf16 :: proc(s: string, order: odid3.Byte_Order) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	units := [2]u8{0xFF, 0xFE} if order == .Little_Endian else {0xFE, 0xFF}
	append(&out, ..units[:])
	for r in s {
		hi, lo := u8(r >> 8), u8(r)
		if order == .Little_Endian {
			append(&out, lo, hi)
		} else {
			append(&out, hi, lo)
		}
	}
	return out[:]
}

// The byte order marks of each kind in data.
marks :: proc(data: []u8) -> (big, little: int) {
	for i := 0; i + 1 < len(data); i += 1 {
		switch {
		case data[i] == 0xFE && data[i + 1] == 0xFF:
			big += 1
		case data[i] == 0xFF && data[i + 1] == 0xFE:
			little += 1
		}
	}
	return
}

@(test)
frames_already_in_the_order_stay :: proc(t: ^testing.T) {
	for order in odid3.Byte_Order {
		le := order == .Little_Endian
		frames := concat(
			frame(3, "TCON", concat({1}, utf16("Rock", order), {0, 0}, utf16("Pop", order))),
			frame(3, "TPE1", concat({1}, utf16("A", order), {0, 0}, utf16("B", order))),
			frame(3, "WXXX", concat({1}, utf16("", order), {0, 0}, text("http://x\x00junk"))),
			// A lone surrogate, which re-encoding would not keep.
			frame(3, "TALB", concat({1}, utf16("", order), {0x00, 0xD8} if le else {0xD8, 0x00})),
			frame(3, "TIT3", text("\x00Latin")),
		)
		tags := read(t, tag_file(3, 0, frames))
		defer odid3.destroy(&tags)
		rendered, err := odid3.render(
			&tags.v2,
			{padding = 0, utf16_byte_order = order},
			context.temp_allocator,
		)
		testing.expect_value(t, err, nil)
		testing.expectf(
			t,
			bytes.equal(rendered, concat(v2_header(3, 0, len(frames)), frames)),
			"%v: %x",
			order,
			rendered,
		)
		testing.expect_value(t, odid3.set_encoding(&tags.v2, .UTF16, order), nil)
		testing.expectf(
			t,
			bytes.equal(tags.v2.frames[0].data, frames[10:][:len(tags.v2.frames[0].data)]),
			"%v: set_encoding changed TCON",
			order,
		)
	}
}

@(test)
every_utf16_string_takes_the_order :: proc(t: ^testing.T) {
	v23 := concat(
		frame(
			3,
			"COMM",
			concat(
				{1},
				text("eng"),
				utf16("desc", .Little_Endian),
				{0, 0},
				utf16("text", .Little_Endian),
			),
		),
		frame(
			3,
			"TXXX",
			concat({1}, utf16("mood", .Little_Endian), {0, 0}, utf16("Calm", .Little_Endian)),
		),
		frame(3, "WXXX", concat({1}, utf16("site", .Little_Endian), {0, 0}, text("http://x"))),
		frame(
			3,
			"APIC",
			concat(
				{1},
				text("image/png\x00\x03"),
				utf16("cover", .Little_Endian),
				{0, 0},
				{0x89, 'P', 'N', 'G'},
			),
		),
		frame(3, "TIT2", concat({1}, utf16("Title", .Little_Endian))),
		frame(3, "TPE1", text("\x00Latin")),
	)
	tags := read(t, tag_file(3, 0, v23))
	defer odid3.destroy(&tags)
	before := all_fields(&tags.v2)
	testing.expect_value(t, odid3.set_encoding(&tags.v2, .UTF16, odid3.Byte_Order.Big_Endian), nil)
	strings := [?]int{2, 2, 1, 1, 1, 1}
	for n, i in strings {
		big, little := marks(tags.v2.frames[i].data)
		testing.expectf(
			t,
			big == n && little == 0,
			"%s: %x",
			tags.v2.frames[i].id,
			tags.v2.frames[i].data,
		)
	}
	testing.expect_value(t, all_fields(&tags.v2), before)

	// Once more changes nothing, and a setter keeps the order.
	data := tags.v2.frames[0].data
	testing.expect_value(t, odid3.set_encoding(&tags.v2, .UTF16, odid3.Byte_Order.Big_Endian), nil)
	testing.expect(t, raw_data(tags.v2.frames[0].data) == raw_data(data))
	testing.expect_value(t, odid3.set(&tags.v2, .Title, "Bé"), nil)
	for f in tags.v2.frames {
		if f.id == "TIT2" {
			big, little := marks(f.data)
			testing.expectf(t, big == 1 && little == 0, "%x", f.data)
		}
	}

	// The option with the encoding the version lacks, and with Latin-1.
	_, err := odid3.render(
		&tags.v2,
		{encoding = .UTF16BE, utf16_byte_order = .Big_Endian},
		context.temp_allocator,
	)
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Encoding_Not_In_Version))
	latin1 := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&latin1)
	rendered, latin1_err := odid3.render(
		&latin1.v2,
		{padding = 0, encoding = .Latin1, utf16_byte_order = .Big_Endian},
		context.temp_allocator,
	)
	testing.expect_value(t, latin1_err, nil)
	plain, _ := odid3.render(&latin1.v2, {padding = 0}, context.temp_allocator)
	testing.expect(t, bytes.equal(rendered, plain))
}

@(test)
byte_order_allocation_failures :: proc(t: ^testing.T) {
	for name in ([]string{"v23_unicode.mp3", "v24_chapters.mp3"}) {
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		rendered := false
		for budget in 0 ..< 256 {
			failing := Failing{context.allocator, budget}
			allocator := failing_allocator(&failing)
			out, err := odid3.render(&tags.v2, {utf16_byte_order = .Big_Endian}, allocator)
			if err == nil {
				delete(out, allocator)
				rendered = true
				break
			}
			testing.expectf(
				t,
				err == odid3.Error(mem.Allocator_Error.Out_Of_Memory),
				"%s: %v",
				name,
				err,
			)
		}
		testing.expectf(t, rendered, "%s never rendered", name)
	}
}
