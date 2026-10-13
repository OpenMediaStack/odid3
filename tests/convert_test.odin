package odid3_tests

import "core:mem"
import "core:testing"

import odid3 "../"

convert :: proc(
	t: ^testing.T,
	tag: ^odid3.Tag,
	to: odid3.V2_Version,
	loc := #caller_location,
) -> odid3.Dropped_Frames {
	dropped, err := odid3.convert(tag, to, context.temp_allocator)
	testing.expectf(t, err == nil, "convert: %v", err, loc = loc)
	return dropped
}

all_fields :: proc(tag: ^odid3.Tag) -> (values: [odid3.Field]string) {
	for f in odid3.Field {
		values[f] = tag_field(tag, f)
	}
	return
}

@(test)
fields_survive_conversions :: proc(t: ^testing.T) {
	for name in fixture_names(t) {
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		from := tags.v2.version
		if from != .V2_3 && from != .V2_4 || tags.warnings & odid3.DAMAGE_WARNINGS != {} {
			continue
		}
		before := all_fields(&tags.v2)
		other: odid3.V2_Version = .V2_4 if from == .V2_3 else .V2_3
		dropped := convert(t, &tags.v2, other)
		testing.expectf(t, len(dropped) == 0, "%s: dropped %v", name, dropped)
		rendered, err := odid3.render(&tags.v2, {}, context.temp_allocator)
		testing.expectf(t, err == nil, "%s: %v", name, err)
		again := read(t, rendered)
		defer odid3.destroy(&again)
		testing.expect_value(t, again.v2.version, other)
		after := all_fields(&again.v2)
		for f in odid3.Field {
			if before[f] != after[f] {
				testing.expectf(t, false, "%s %v: %q became %q", name, f, before[f], after[f])
			}
		}
		convert(t, &again.v2, from)
		testing.expect_value(t, all_fields(&again.v2), before)
	}
}

@(test)
dates_and_people :: proc(t: ^testing.T) {
	frames := concat(
		frame(4, "TDRC", text("\x032019-05-03T10:20")),
		frame(4, "TDOR", text("\x031987-01-01")),
		frame(4, "TIPL", text("\x03producer\x00Ada\x00")),
		frame(4, "TMCL", text("\x03piano\x00Bea\x00")),
	)
	tags := read(t, tag_file(4, 0, frames))
	defer odid3.destroy(&tags)
	convert(t, &tags.v2, .V2_3)
	for c in ([]struct {
			id, data: string,
		}{{"TYER", "\x002019"}, {"TDAT", "\x000305"}, {"TIME", "\x001020"}, {"TORY", "\x001987"}, {"IPLS", "\x00producer\x00Ada\x00piano\x00Bea\x00"}}) {
		index, ok := odid3.find_frame(&tags.v2, c.id)
		testing.expectf(t, ok && string(tags.v2.frames[index].data) == c.data, "%s: %v", c.id, ok)
	}
	convert(t, &tags.v2, .V2_4)
	testing.expect_value(t, tag_field(&tags.v2, .Date), "2019-05-03T10:20")
	index, ok := odid3.find_frame(&tags.v2, "TIPL")
	testing.expect(
		t,
		ok && string(tags.v2.frames[index].data[1:]) == "producer\x00Ada\x00piano\x00Bea\x00",
	)
}

@(test)
text_is_reencoded_for_v23 :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v24_unicode.mp3"))
	defer odid3.destroy(&tags)
	convert(t, &tags.v2, .V2_3)
	for &f in tags.v2.frames {
		testing.expectf(t, f.data[0] <= 1, "%s still in encoding %d", f.id, f.data[0])
	}
	testing.expect_value(t, tags.v2.frames[0].data[0], 0)
	testing.expect_value(t, tags.v2.frames[1].data[0], 1)
	testing.expect_value(t, tag_field(&tags.v2, .Artist), "坂本龍一")

	several := read(t, tag_file(4, 0, frame(4, "TPE1", text("\x03Ada\x00Bea"))))
	defer odid3.destroy(&several)
	convert(t, &several.v2, .V2_3)
	testing.expect_value(t, tag_field(&several.v2, .Artist), "Ada/Bea")
}

expect_frames :: proc(t: ^testing.T, tag: ^odid3.Tag, want: []string, loc := #caller_location) {
	testing.expect_value(t, len(tag.frames), len(want), loc = loc)
	for f, i in tag.frames[:min(len(tag.frames), len(want))] {
		testing.expectf(t, string(f.data) == want[i], "%s: %x", f.id, f.data, loc = loc)
	}
}

@(test)
text_a_conversion_carries_in_part :: proc(t: ^testing.T) {
	// Re-encoded for ID3v2.3, text after a URL or a comment, a surrogate without its pair (D8 00
	// in UTF-16BE, 00 D8 after a little endian byte order mark) and an odd last byte of UTF-16
	// cannot be carried: the frames are kept without them, the surrogate as U+FFFD, and listed.
	partly := read(
		t,
		tag_file(
			4,
			0,
			frame(4, "WXXX", text("\x03site\x00http://x\x00junk")),
			frame(4, "COMM", text("\x03engd\x00text\x00more")),
			frame(4, "TIT2", {0x02, 0xD8, 0x00, 0x00, 0x41}),
			frame(
				4,
				"TPE1",
				concat({1}, utf16("B", .Little_Endian), {0, 0, 0xFF, 0xFE, 0x00, 0xD8}),
			),
			frame(4, "TALB", {0x02, 0x00, 'A', 'B'}),
		),
	)
	defer odid3.destroy(&partly)
	expect_dropped(
		t,
		convert(t, &partly.v2, .V2_3),
		{
			{"WXXX", .Partly_Converted},
			{"COMM", .Partly_Converted},
			{"TIT2", .Partly_Converted},
			{"TPE1", .Partly_Converted},
			{"TALB", .Partly_Converted},
		},
	)
	expect_frames(
		t,
		&partly.v2,
		{
			"\x00site\x00http://x",
			"\x00engd\x00text",
			"\x01\xFF\xFE\xFD\xFF\x41\x00",
			"\x01\xFF\xFEB\x00/\x00\xFD\xFF",
			"\x00A",
		},
	)

	// A real U+FFFD is a character like any other, and neither a final terminator, even doubled,
	// nor an odd last NUL of UTF-16 is a lost byte.
	whole := read(
		t,
		tag_file(
			4,
			0,
			frame(4, "WXXX", text("\x03\uFFFD\x00http://x\x00")),
			frame(4, "COMM", text("\x03engd\x00\uFFFD\x00")),
			frame(4, "TIT2", {0x02, 0xFF, 0xFD, 0x00, 0x41}),
			frame(
				4,
				"TPE1",
				concat({1}, utf16("B", .Little_Endian), {0, 0}, utf16("\uFFFD", .Little_Endian)),
			),
			frame(4, "WXXX", text("\x03w\x00http://y\x00\x00")),
			frame(4, "COMM", text("\x03enge\x00text\x00\x00")),
			frame(4, "TALB", {0x02, 0x00, 'A', 0x00}),
		),
	)
	defer odid3.destroy(&whole)
	expect_dropped(t, convert(t, &whole.v2, .V2_3), {})
	expect_frames(
		t,
		&whole.v2,
		{
			"\x01\xFF\xFE\xFD\xFF\x00\x00http://x",
			"\x01eng\xFF\xFEd\x00\x00\x00\xFF\xFE\xFD\xFF",
			"\x01\xFF\xFE\xFD\xFF\x41\x00",
			"\x01\xFF\xFEB\x00/\x00\xFD\xFF",
			"\x00w\x00http://y",
			"\x00enge\x00text",
			"\x00A",
		},
	)

	// Inside a chapter, and on the way to ID3v2.2, the same.
	lone := frame(4, "TIT2", {0x02, 0xD8, 0x00, 0x00, 0x41})
	chaptered := read(t, tag_file(4, 0, chapter_frame(4, "ch0", 0, 10, lone)))
	defer odid3.destroy(&chaptered)
	expect_dropped(t, convert(t, &chaptered.v2, .V2_3), {{"TIT2", .Partly_Converted}})
	v22 := read(t, tag_file(4, 0, frame(4, "COMM", text("\x03engd\x00text\x00more"))))
	defer odid3.destroy(&v22)
	expect_dropped(t, convert(t, &v22.v2, .V2_2), {{"COMM", .Partly_Converted}})
	expect_frames(t, &v22.v2, {"\x00engd\x00text"})
}

@(test)
rebuilt_frames_carry_text_in_part :: proc(t: ^testing.T) {
	// ID3v2.4, section 4: a UTF-16 string without a byte order mark follows the order of the
	// first one, here big endian.
	big := read(t, tag_file(4, 0, frame(4, "TIPL", {1, 0xFE, 0xFF, 0, 'p', 0, 0, 0, 'A', 0, 0})))
	defer odid3.destroy(&big)
	expect_dropped(t, convert(t, &big.v2, .V2_3), {})
	expect_frames(t, &big.v2, {"\x01\xFE\xFF\x00p\x00\x00\xFE\xFF\x00A\x00\x00"})

	// People, the original year, the year and picture descriptions are decoded and encoded again:
	// a surrogate without its pair (00 D8 after a little endian byte order mark) becomes U+FFFD
	// and the frame is listed, once even when merged into a frame of another group, as when an
	// odd last byte other than a NUL is dropped; a real U+FFFD (FD FF) is carried as it is. Values
	// after the first of a TDAT or TIME are listed too.
	lone := []u8{0xFF, 0xFE, 0x00, 0xD8}
	real := []u8{0xFF, 0xFE, 0xFD, 0xFF}
	cases := []struct {
		major:   u8,
		frame:   []u8,
		to:      odid3.V2_Version,
		dropped: string,
		want:    string,
	} {
		{
			3,
			frame(3, "IPLS", concat({1, 0xFF, 0xFE, 'p', 0, 0, 0}, lone, {0, 0})),
			.V2_4,
			"IPLS",
			"\x01\xFF\xFEp\x00\x00\x00\xFF\xFE\xFD\xFF\x00\x00",
		},
		{
			3,
			frame(3, "IPLS", concat({1, 0xFF, 0xFE, 'p', 0, 0, 0}, real, {0, 0})),
			.V2_4,
			"",
			"\x01\xFF\xFEp\x00\x00\x00\xFF\xFE\xFD\xFF\x00\x00",
		},
		{
			3,
			frame(3, "IPLS", {1, 0xFF, 0xFE, 'p', 0, 0, 0, 0xFF, 0xFE, 'A'}),
			.V2_4,
			"IPLS",
			"\x01\xFF\xFEp\x00\x00\x00\xFF\xFE\x00\x00",
		},
		{
			3,
			frame(3, "IPLS", {1, 0xFF, 0xFE, 'p', 0, 0, 0, 0xFF, 0xFE, 'A', 0, 0}),
			.V2_4,
			"",
			"\x01\xFF\xFEp\x00\x00\x00\xFF\xFEA\x00\x00\x00",
		},
		{
			4,
			concat(
				frame(4, "TIPL", text("\x00a\x00b\x00")),
				frame(4, "TMCL", concat({1, 0xFF, 0xFE, 'p', 0, 0, 0}, lone, {0, 0})),
			),
			.V2_3,
			"TMCL",
			"\x01\xFF\xFEa\x00\x00\x00\xFF\xFEb\x00\x00\x00\xFF\xFEp\x00\x00\x00\xFF\xFE\xFD\xFF\x00\x00",
		},
		{
			4,
			concat(
				frame(4, "TIPL", text("\x00a\x00b\x00")),
				frame(
					4,
					"TMCL",
					concat({0x2A, 1, 0xFF, 0xFE, 'p', 0, 0, 0}, lone, {0, 0}),
					0,
					0x40,
				),
			),
			.V2_3,
			"TMCL",
			"\x01\xFF\xFEa\x00\x00\x00\xFF\xFEb\x00\x00\x00\xFF\xFEp\x00\x00\x00\xFF\xFE\xFD\xFF\x00\x00",
		},
		{
			3,
			frame(3, "TORY", concat({1}, lone[:2], {'1', 0, '9', 0}, lone[2:], {'9', 0})),
			.V2_4,
			"TORY",
			"\x01\xFF\xFE1\x009\x00\xFD\xFF9\x00",
		},
		{
			3,
			frame(3, "TORY", concat({1}, real[:2], {'1', 0, '9', 0}, real[2:], {'9', 0})),
			.V2_4,
			"",
			"\x01\xFF\xFE1\x009\x00\xFD\xFF9\x00",
		},
		{3, frame(3, "TYER", concat({1}, lone)), .V2_4, "TYER", "\x01\xFF\xFE\xFD\xFF"},
		{3, frame(3, "TYER", concat({1}, real)), .V2_4, "", "\x01\xFF\xFE\xFD\xFF"},
		{
			3,
			concat(
				frame(3, "TYER", text("\x002001")),
				frame(
					3,
					"TDAT",
					concat({1, 0xFF, 0xFE, '0', 0, '1', 0, '0', 0, '2', 0, 0, 0}, lone),
				),
			),
			.V2_4,
			"TDAT",
			"\x002001-02-01",
		},
		{
			3,
			concat(
				frame(3, "TYER", text("\x002001")),
				frame(3, "TDAT", text("\x000102")),
				frame(3, "TIME", text("\x001200\x00junk")),
			),
			.V2_4,
			"TIME",
			"\x002001-02-01T12:00",
		},
		{
			3,
			frame(3, "APIC", concat(text("\x01image/jpeg\x00\x03"), lone, {0, 0, 0xFF, 0xD8})),
			.V2_2,
			"APIC",
			"\x01JPG\x03\xFF\xFE\xFD\xFF\x00\x00\xFF\xD8",
		},
		{
			4,
			frame(4, "APIC", concat(text("\x01image/jpeg\x00\x03"), lone, {0, 0, 0xFF, 0xD8})),
			.V2_2,
			"APIC",
			"\x01JPG\x03\xFF\xFE\xFD\xFF\x00\x00\xFF\xD8",
		},
		{
			3,
			frame(3, "APIC", concat(text("\x01image/jpeg\x00\x03"), real, {0, 0, 0xFF, 0xD8})),
			.V2_2,
			"",
			"\x01JPG\x03\xFF\xFE\xFD\xFF\x00\x00\xFF\xD8",
		},
		{
			2,
			frame22("PIC", concat(text("\x01JPG\x03"), lone, {0, 0, 0xFF, 0xD8})),
			.V2_3,
			"PIC",
			"\x01image/jpeg\x00\x03\xFF\xFE\xFD\xFF\x00\x00\xFF\xD8",
		},
		{
			2,
			frame22("PIC", concat(text("\x01JPG\x03"), lone, {0, 0, 0xFF, 0xD8})),
			.V2_4,
			"PIC",
			"\x01image/jpeg\x00\x03\xFF\xFE\xFD\xFF\x00\x00\xFF\xD8",
		},
		{
			2,
			frame22("PIC", concat(text("\x01JPG\x03"), real, {0, 0, 0xFF, 0xD8})),
			.V2_3,
			"",
			"\x01image/jpeg\x00\x03\xFF\xFE\xFD\xFF\x00\x00\xFF\xD8",
		},
	}
	for c in cases {
		tags := read(t, tag_file(c.major, 0, c.frame))
		defer odid3.destroy(&tags)
		dropped := convert(t, &tags.v2, c.to)
		want := []odid3.Dropped_Frame{} if c.dropped == "" else {{c.dropped, .Partly_Converted}}
		expect_dropped(t, dropped, want)
		expect_frames(t, &tags.v2, {c.want})
	}

	for c in cases {
		succeeded := false
		for budget in 0 ..< 40 {
			failing := Failing{context.allocator, 1 << 30}
			allocator := failing_allocator(&failing)
			tags, read_err := odid3.read_bytes(tag_file(c.major, 0, c.frame), {}, allocator)
			testing.expect_value(t, read_err, nil)
			before := frames_snapshot(&tags.v2)
			failing.left = budget
			dropped, err := odid3.convert(&tags.v2, c.to, allocator)
			failing.left = 1 << 30
			odid3.destroy(&dropped, allocator)
			if err == nil {
				succeeded = true
			} else {
				testing.expectf(
					t,
					frames_snapshot(&tags.v2) == before,
					"%x at %d",
					c.frame,
					budget,
				)
			}
			odid3.destroy(&tags)
			if succeeded {
				break
			}
		}
		testing.expectf(t, succeeded, "%x never converted", c.frame)
	}

	// A picture ID3v2.2 has no image format for is dropped, and listed for that alone.
	webp := read(
		t,
		tag_file(3, 0, frame(3, "APIC", concat(text("\x01image/webp\x00\x03"), lone, {0, 0}))),
	)
	defer odid3.destroy(&webp)
	expect_dropped(t, convert(t, &webp.v2, .V2_2), {{"APIC", .No_Equivalent}})
}

@(test)
frames_a_conversion_drops :: proc(t: ^testing.T) {
	v24 := read(
		t,
		tag_file(
			4,
			0,
			frame(4, "RVA2", text("track\x00\x01")),
			frame(4, "XYZW", text("data"), 0x40),
			frame(4, "ABCD", text("kept")),
			frame(4, "PRIV", concat({0x80}, text("secret")), 0, 0x0C),
		),
	)
	defer odid3.destroy(&v24)
	dropped := convert(t, &v24.v2, .V2_3)
	want := []odid3.Dropped_Frame {
		{"RVA2", .No_Equivalent},
		{"XYZW", .Discard_On_Tag_Alter},
		{"PRIV", .Encrypted},
	}
	testing.expect_value(t, len(dropped), len(want))
	for d, i in dropped {
		testing.expectf(
			t,
			d.id == want[i].id && d.reason == want[i].reason,
			"%v, want %v",
			d,
			want[i],
		)
	}
	testing.expect_value(t, len(v24.v2.frames), 1)
	testing.expect_value(t, v24.v2.frames[0].id, "ABCD")

	v23 := read(
		t,
		tag_file(
			3,
			0,
			frame(3, "RVAD", {0x03, 0x10, 0, 0, 0, 0}),
			frame(3, "TIT2", text("\x00Title")),
		),
	)
	defer odid3.destroy(&v23)
	dropped = convert(t, &v23.v2, .V2_4)
	testing.expect_value(t, len(dropped), 1)
	testing.expect_value(t, dropped[0].id, "RVAD")
}

@(test)
converting_from_and_to_none :: proc(t: ^testing.T) {
	tag: odid3.Tag
	defer odid3.destroy(&tag)
	convert(t, &tag, .V2_4)
	testing.expect_value(t, tag.version, odid3.V2_Version.V2_4)
	testing.expect_value(t, odid3.set(&tag, .Title, "From nothing"), nil)
	rendered := odid3.render(&tag, {}, context.temp_allocator) or_else nil
	tags := read(t, rendered)
	defer odid3.destroy(&tags)
	testing.expect_value(t, field(&tags, .Title), "From nothing")

	dropped := convert(t, &tags.v2, .None)
	testing.expect_value(t, len(dropped), 1)
	testing.expect_value(t, dropped[0].reason, odid3.Drop_Reason.Tag_Removed)
	testing.expect_value(t, tags.v2.version, odid3.V2_Version.None)
	testing.expect_value(t, len(tags.v2.frames), 0)
}

@(test)
conversion_allocation_failures_leak_nothing :: proc(t: ^testing.T) {
	data := fixture(t, "v24_unicode.mp3")
	succeeded := false
	for budget in 0 ..< 200 {
		failing := Failing{context.allocator, budget}
		allocator := failing_allocator(&failing)
		tags, err := odid3.read_bytes(data, {}, allocator)
		if err != nil {
			continue
		}
		dropped, convert_err := odid3.convert(&tags.v2, .V2_3, allocator)
		odid3.destroy(&dropped, allocator)
		odid3.destroy(&tags)
		if convert_err == nil {
			succeeded = true
			break
		}
		testing.expect_value(t, convert_err, odid3.Error(mem.Allocator_Error.Out_Of_Memory))
	}
	testing.expect(t, succeeded)
}

@(test)
a_clone_previews_a_conversion :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v24_full.mp3"))
	defer odid3.destroy(&tags)
	before := all_fields(&tags.v2)

	preview, err := odid3.clone(&tags.v2)
	testing.expect_value(t, err, nil)
	defer odid3.destroy(&preview)
	convert(t, &preview, .V2_3)
	testing.expect_value(t, preview.version, odid3.V2_Version.V2_3)
	testing.expect_value(t, tags.v2.version, odid3.V2_Version.V2_4)
	testing.expect_value(t, all_fields(&tags.v2), before)
	testing.expect_value(t, tag_field(&preview, .Title), before[.Title])

	enhanced := read(t, fixture(t, "v1_enhanced.mp3"))
	defer odid3.destroy(&enhanced)
	copy_of, clone_err := odid3.clone(&enhanced)
	testing.expect_value(t, clone_err, nil)
	defer odid3.destroy(&copy_of)
	testing.expect_value(t, copy_of.v1.title, enhanced.v1.title)
	testing.expect(t, raw_data(copy_of.v1.title) != raw_data(enhanced.v1.title))
	e, ok := copy_of.v1.enhanced.?
	testing.expect(t, ok)
	testing.expect_value(t, e.genre, enhanced.v1.enhanced.?.genre)
	testing.expect_value(t, copy_of.layout, enhanced.layout)
}

@(test)
clone_allocation_failures_leak_nothing :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v1_enhanced.mp3"))
	defer odid3.destroy(&tags)
	full := read(t, fixture(t, "v24_full.mp3"))
	defer odid3.destroy(&full)
	tags.v2, full.v2 = full.v2, tags.v2
	succeeded := false
	for budget in 0 ..< 64 {
		failing := Failing{context.allocator, budget}
		allocator := failing_allocator(&failing)
		duplicate, err := odid3.clone(&tags, allocator)
		if err == nil {
			odid3.destroy(&duplicate)
			succeeded = true
			break
		}
		testing.expect_value(t, err, odid3.Error(mem.Allocator_Error.Out_Of_Memory))
	}
	testing.expect(t, succeeded)
}

expect_dropped :: proc(
	t: ^testing.T,
	dropped: odid3.Dropped_Frames,
	want: []odid3.Dropped_Frame,
	loc := #caller_location,
) {
	same := len(dropped) == len(want)
	for d, i in dropped {
		same = same && i < len(want) && d.id == want[i].id && d.reason == want[i].reason
	}
	testing.expectf(t, same, "dropped %v, want %v", dropped, want, loc = loc)
}

@(test)
dates_carried_as_far_as_they_go :: proc(t: ^testing.T) {
	to_v23 := []struct {
		date:  string,
		want:  string,
		fully: bool,
	} {
		{"2019-05-03T10:20", "2019-05-03T10:20", true},
		{"2019-05", "2019", false},
		{"2019-05-03T10", "2019-05-03", false},
		{"2019-05-03T10:20:30", "2019-05-03T10:20", false},
		{"2019-05-03T10:20:30Z", "2019-05-03T10:20", false},
		{"2019\x002020", "2019", false},
	}
	for c in to_v23 {
		tags := read(t, tag_file(4, 0, frame(4, "TDRC", concat(text("\x03"), text(c.date)))))
		defer odid3.destroy(&tags)
		dropped := convert(t, &tags.v2, .V2_3)
		testing.expectf(
			t,
			tag_field(&tags.v2, .Date) == c.want,
			"%q gave %q",
			c.date,
			tag_field(&tags.v2, .Date),
		)
		want := []odid3.Dropped_Frame{} if c.fully else {{"TDRC", .Partly_Converted}}
		expect_dropped(t, dropped, want)
	}
	not_a_date := read(
		t,
		tag_file(4, 0, frame(4, "TDRC", text("\x03abc")), frame(4, "TIT2", text("\x03T"))),
	)
	defer odid3.destroy(&not_a_date)
	expect_dropped(t, convert(t, &not_a_date.v2, .V2_3), {{"TDRC", .No_Equivalent}})

	to_v24 := []struct {
		frames: []u8,
		date:   string,
		want:   []odid3.Dropped_Frame,
	} {
		{frame(3, "TYER", text("\x0019")), "19", {}},
		{
			concat(frame(3, "TDAT", text("\x000305")), frame(3, "TIME", text("\x001020"))),
			"",
			{{"TDAT", .No_Equivalent}, {"TIME", .No_Equivalent}},
		},
		{
			concat(frame(3, "TYER", text("\x002019")), frame(3, "TIME", text("\x001020"))),
			"2019",
			{{"TIME", .No_Equivalent}},
		},
		{
			concat(frame(3, "TYER", text("\x002019")), frame(3, "TDAT", text("\x000013"))),
			"2019",
			{{"TDAT", .No_Equivalent}},
		},
		{
			concat(frame(3, "TYER", text("\x002019")), frame(3, "TYER", text("\x002020"))),
			"2019",
			{{"TYER", .No_Equivalent}},
		},
		{
			concat(frame(3, "TYER", text("\x002019")), frame(3, "TDRC", text("\x002018-01-02"))),
			"2018-01-02",
			{{"TYER", .No_Equivalent}},
		},
	}
	for c, i in to_v24 {
		tags := read(t, tag_file(3, 0, c.frames))
		defer odid3.destroy(&tags)
		dropped := convert(t, &tags.v2, .V2_4)
		testing.expectf(
			t,
			tag_field(&tags.v2, .Date) == c.date,
			"case %d gave %q",
			i,
			tag_field(&tags.v2, .Date),
		)
		expect_dropped(t, dropped, c.want)
	}

	encrypted := read(t, tag_file(4, 0, frame(4, "TDRC", concat({0x80}, text("secret")), 0, 0x04)))
	defer odid3.destroy(&encrypted)
	expect_dropped(t, convert(t, &encrypted.v2, .V2_3), {{"TDRC", .Encrypted}})

	original := read(t, tag_file(4, 0, frame(4, "TDOR", text("\x031987-01-02"))))
	defer odid3.destroy(&original)
	expect_dropped(t, convert(t, &original.v2, .V2_3), {{"TDOR", .Partly_Converted}})
	testing.expect_value(t, original.v2.frames[0].id, "TORY")
	testing.expect_value(t, string(original.v2.frames[0].data), "\x001987")
}

@(test)
several_values_are_joined_for_v23 :: proc(t: ^testing.T) {
	tags := read(
		t,
		tag_file(
			4,
			0,
			frame(4, "TPE1", text("\x00Ada\x00Bea")),
			frame(4, "TCON", text("\x0017\x00Synthwave")),
			frame(4, "TXXX", text("\x00mood\x00Calm\x00Warm")),
		),
	)
	defer odid3.destroy(&tags)
	expect_dropped(t, convert(t, &tags.v2, .V2_3), {})
	testing.expect_value(t, string(tags.v2.frames[0].data), "\x00Ada/Bea")
	testing.expect_value(t, string(tags.v2.frames[1].data), "\x00(17)Synthwave")
	testing.expect_value(t, tag_field(&tags.v2, .Genre), "Rock; Synthwave")
	mood, found, _ := odid3.user_text(&tags.v2, "mood", context.temp_allocator)
	testing.expect(t, found && mood == "Calm/Warm")
}

@(test)
people_pairs :: proc(t: ^testing.T) {
	tags := read(
		t,
		tag_file(
			4,
			0,
			frame(4, "TIPL", text("\x00producer\x00Ada\x00engineer")),
			frame(4, "TMCL", text("\x00piano\x00Bea")),
		),
	)
	defer odid3.destroy(&tags)
	expect_dropped(t, convert(t, &tags.v2, .V2_3), {})
	testing.expect_value(t, len(tags.v2.frames), 1)
	testing.expect_value(t, tags.v2.frames[0].id, "IPLS")
	testing.expect_value(
		t,
		string(tags.v2.frames[0].data),
		"\x00producer\x00Ada\x00engineer\x00\x00piano\x00Bea\x00",
	)
}

@(test)
chapters_follow_the_version :: proc(t: ^testing.T) {
	title := concat(text("\x03"), letters(200))
	tags := read(t, tag_file(4, 0, chapter_frame(4, "ch0", 0, 10, frame(4, "TIT2", title))))
	defer odid3.destroy(&tags)
	expect_dropped(t, convert(t, &tags.v2, .V2_3), {})
	rendered, err := odid3.render(&tags.v2, {}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	again := read(t, rendered)
	defer odid3.destroy(&again)
	content, decode_err := odid3.decode_frame(&again.v2.frames[0], .V2_3, context.temp_allocator)
	testing.expect_value(t, decode_err, nil)
	chapter := expect_content(t, content, odid3.Chapter)
	testing.expect_value(t, chapter.warnings, odid3.Warnings{})
	testing.expect_value(t, len(chapter.frames), 1)
	if len(chapter.frames) == 1 {
		testing.expect_value(
			t,
			string(chapter.frames[0].data),
			string(concat(text("\x00"), letters(200))),
		)
	}
}

@(test)
compressed_and_encrypted_frames_keep_their_size :: proc(t: ^testing.T) {
	stored := frame(3, "PRIV", concat({0, 0, 0, 20, 0x80}, text("secret")), 0, 0xC0)
	tags := read(t, tag_file(3, 0, stored))
	defer odid3.destroy(&tags)
	expect_dropped(t, convert(t, &tags.v2, .V2_4), {})
	testing.expect(t, .Data_Length_Indicator in tags.v2.frames[0].format)
	rendered, _ := odid3.render(&tags.v2, {}, context.temp_allocator)
	again := read(t, rendered)
	defer odid3.destroy(&again)
	testing.expect_value(t, again.v2.frames[0].data_length, 20)
	expect_dropped(t, convert(t, &again.v2, .V2_3), {})
}

@(test)
a_failed_conversion_leaves_the_tag_as_it_was :: proc(t: ^testing.T) {
	data := tag_file(
		4,
		0,
		frame(4, "TIT2", text("\x03Title")),
		frame(4, "RVA2", text("track\x00\x01")),
		frame(4, "TDRC", text("\x032019-05-03T10:20:30")),
		frame(4, "TIPL", text("\x03producer\x00Ada\x00engineer")),
		frame(4, "TPE1", text("\x03Ada\x00Bea")),
		frame(4, "COMM", text("\x03engd\x00text\x00more")),
	)
	succeeded := false
	for budget in 0 ..< 128 {
		failing := Failing{context.allocator, 1 << 30}
		tags, read_err := odid3.read_bytes(data, {}, failing_allocator(&failing))
		testing.expect_value(t, read_err, nil)
		before := frames_snapshot(&tags.v2)
		failing.left = budget
		dropped, err := odid3.convert(&tags.v2, .V2_3, failing_allocator(&failing))
		failing.left = 1 << 30
		if err == nil {
			testing.expect_value(t, len(dropped), 3)
			odid3.destroy(&dropped, failing_allocator(&failing))
			succeeded = true
		} else {
			testing.expect(t, dropped == nil)
			testing.expect_value(t, tags.v2.version, odid3.V2_Version.V2_4)
			testing.expectf(
				t,
				frames_snapshot(&tags.v2) == before,
				"budget %d changed the tag",
				budget,
			)
		}
		odid3.destroy(&tags)
		if succeeded {
			break
		}
	}
	testing.expect(t, succeeded)
}

@(test)
v22_tags_convert_both_ways :: proc(t: ^testing.T) {
	for name in ([]string{"v22.mp3", "v22_pic.mp3"}) {
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		before := all_fields(&tags.v2)
		pictures_before := len(odid3.pictures(&tags.v2, context.temp_allocator))
		for to in ([]odid3.V2_Version{.V2_3, .V2_4, .V2_2}) {
			dropped := convert(t, &tags.v2, to)
			testing.expectf(t, len(dropped) == 0, "%s to %v: dropped %v", name, to, dropped)
			rendered, err := odid3.render(&tags.v2, {}, context.temp_allocator)
			testing.expectf(t, err == nil, "%s to %v: %v", name, to, err)
			again := read(t, rendered)
			defer odid3.destroy(&again)
			testing.expect_value(t, again.v2.version, to)
			testing.expect_value(t, all_fields(&again.v2), before)
			all := odid3.pictures(&again.v2, context.temp_allocator)
			testing.expect_value(t, len(all), pictures_before)
			for p in all {
				testing.expect_value(t, p.mime, "image/png")
				testing.expect_value(t, p.type, odid3.Picture_Type.Front_Cover)
			}
		}
	}
}

@(test)
v24_tags_to_v22 :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v24_full.mp3"))
	defer odid3.destroy(&tags)
	before := all_fields(&tags.v2)
	dropped := convert(t, &tags.v2, .V2_2)
	testing.expect_value(t, len(dropped), 0)
	// The date stays where TDRC was.
	ids := [?]string{"TT2", "TP1", "TP2", "TAL", "TYE", "TRK", "TPA", "TCO", "TXX", "TPB", "TXX"}
	for &f, i in tags.v2.frames {
		testing.expectf(t, i < len(ids) && f.id == ids[i], "frame %d is %s", i, f.id)
		testing.expectf(t, f.data[0] <= 1, "%s in encoding %d", f.id, f.data[0])
	}
	testing.expect_value(t, all_fields(&tags.v2), before)
}

@(test)
frames_v22_cannot_hold :: proc(t: ^testing.T) {
	frames := concat(
		frame(4, "PRIV", text("owner\x00data")),
		frame(4, "TIT2", text("\x03Title")),
		frame(4, "PCNT", {0, 0, 0, 4, 0, 0, 0, 1}, 0x10, 0x01),
		frame(4, "TPE1", concat({0x80}, text("secret")), 0, 0x04),
	)
	tags := read(t, tag_file(4, 0, frames))
	defer odid3.destroy(&tags)
	dropped := convert(t, &tags.v2, .V2_2)
	// The frames ID3v2.2 has no flags for go first, before the ID3v2.3 step.
	want := []odid3.Dropped_Frame{{"TPE1", .Encrypted}, {"PRIV", .No_Equivalent}}
	testing.expect_value(t, len(dropped), len(want))
	for d, i in dropped {
		testing.expectf(
			t,
			d.id == want[i].id && d.reason == want[i].reason,
			"%v, want %v",
			d,
			want[i],
		)
	}
	testing.expect_value(t, len(tags.v2.frames), 2)
	testing.expect_value(t, tags.v2.frames[1].format, odid3.Frame_Format{})

	unknown := read(
		t,
		tag_file(2, 0, frame22("XYZ", text("data")), frame22("TT2", text("\x00Title"))),
	)
	defer odid3.destroy(&unknown)
	dropped = convert(t, &unknown.v2, .V2_4)
	testing.expect_value(t, len(dropped), 1)
	testing.expect_value(t, dropped[0].id, "XYZ")
}

@(test)
grouped_people_go_alone_to_v22 :: proc(t: ^testing.T) {
	// A grouped TIPL or TMCL is dropped under its own ID before the people frames merge into IPLS:
	// it takes no other frame's people with it, nor is it kept in another's.
	cases := []struct {
		frames:  []u8,
		dropped: odid3.Dropped_Frame,
		want:    string,
	} {
		{
			concat(
				frame(4, "TIPL", concat({0x2A}, text("\x03producer\x00Ada")), 0, 0x40),
				frame(4, "TMCL", text("\x03piano\x00Bea")),
			),
			{"TIPL", .Grouped},
			"\x00piano\x00Bea\x00",
		},
		{
			concat(
				frame(4, "TIPL", text("\x03producer\x00Ada")),
				frame(4, "TMCL", concat({0x2A}, text("\x03piano\x00Bea")), 0, 0x40),
			),
			{"TMCL", .Grouped},
			"\x00producer\x00Ada\x00",
		},
	}
	for c in cases {
		tags := read(t, tag_file(4, 0, c.frames))
		defer odid3.destroy(&tags)
		expect_dropped(t, convert(t, &tags.v2, .V2_2), {c.dropped})
		expect_frames(t, &tags.v2, {c.want})
		testing.expect(t, len(tags.v2.frames) == 1 && tags.v2.frames[0].id == "IPL")
	}
}

@(test)
v23_tags_to_v22_take_v23_form_first :: proc(t: ^testing.T) {
	tags := read(
		t,
		tag_file(
			3,
			0,
			frame(3, "TIT2", text("\x03Café")),
			frame(3, "TDRC", text("\x002019-05-03T10:20")),
			frame(3, "TDOR", text("\x001987")),
			frame(3, "TIPL", text("\x00producer\x00Ada\x00")),
			frame(3, "GRP1", text("\x00Group")),
		),
	)
	defer odid3.destroy(&tags)
	expect_dropped(t, convert(t, &tags.v2, .V2_2), {})
	ids := [?]string{"TT2", "TYE", "TDA", "TIM", "TOR", "IPL", "GP1"}
	testing.expect_value(t, len(tags.v2.frames), len(ids))
	for &f, i in tags.v2.frames {
		testing.expectf(t, i < len(ids) && f.id == ids[i], "frame %d is %s", i, f.id)
		testing.expectf(t, f.data[0] <= 1, "%s in encoding %d", f.id, f.data[0])
	}
	testing.expect_value(t, tag_field(&tags.v2, .Date), "2019-05-03T10:20")
	expect_dropped(t, convert(t, &tags.v2, .V2_4), {})
	testing.expect_value(t, tag_field(&tags.v2, .Title), "Café")
	testing.expect_value(t, tags.v2.frames[len(tags.v2.frames) - 1].id, "GRP1")
}

@(test)
what_v22_cannot_take :: proc(t: ^testing.T) {
	// A compressed frame whose unsynchronisation flag lied is still compressed bytes.
	lied := read(
		t,
		tag_file(4, 0, frame(4, "TIT2", {0, 0, 0, 5, 0x78, 0x9C, 0xFF, 0xE0}, 0, 0x0B)),
	)
	defer odid3.destroy(&lied)
	expect_dropped(t, convert(t, &lied.v2, .V2_2), {{"TIT2", .Encrypted}})

	webp := frame(3, "APIC", text("\x00image/webp\x00\x03\x00RIFF"))
	jpeg := frame(3, "APIC", text("\x00image/jpeg\x00\x04\x00\xFF\xD8"))
	link := frame(3, "APIC", text("\x00-->\x00\x05\x00http://example.com/cover"))
	pictures := read(t, tag_file(3, 0, webp, jpeg, link))
	defer odid3.destroy(&pictures)
	expect_dropped(t, convert(t, &pictures.v2, .V2_2), {{"APIC", .No_Equivalent}})
	kept := odid3.pictures(&pictures.v2, context.temp_allocator)
	testing.expect_value(t, len(kept), 2)
	if len(kept) == 2 {
		testing.expect_value(t, kept[0].mime, "image/jpeg")
		testing.expect_value(t, kept[1].mime, "-->")
	}

	stereo := text("\x03\x10\x00\x01\x00\x02\x00\x03\x00\x04")
	surround := concat(stereo, text("\x00\x05\x00\x06\x00\x07\x00\x08"))
	volume := read(t, tag_file(3, 0, frame(3, "RVAD", surround)))
	defer odid3.destroy(&volume)
	expect_dropped(t, convert(t, &volume.v2, .V2_2), {{"RVAD", .Partly_Converted}})
	testing.expect_value(t, string(volume.v2.frames[0].data), string(stereo))
}

@(test)
v22_tags_not_read_whole :: proc(t: ^testing.T) {
	compressed := read(t, tag_file(2, 0x40, frame22("TT2", text("\x00Title"))))
	defer odid3.destroy(&compressed)
	_, err := odid3.convert(&compressed.v2, .V2_3, context.temp_allocator)
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Incomplete_Tag))

	for name in ([]string{"v22_pic.mp3", "v23_cover.mp3"}) {
		skipped, read_err := odid3.read_bytes(
			fixture(t, name),
			{skip_picture_data = true},
			context.allocator,
		)
		testing.expect_value(t, read_err, nil)
		defer odid3.destroy(&skipped)
		to: odid3.V2_Version = .V2_3 if skipped.v2.version == .V2_2 else .V2_2
		_, skipped_err := odid3.convert(&skipped.v2, to, context.temp_allocator)
		testing.expect_value(t, skipped_err, odid3.Error(odid3.Format_Error.Incomplete_Tag))
	}
}

@(test)
v22_conversion_allocation_failures :: proc(t: ^testing.T) {
	cases := []struct {
		name: string,
		to:   odid3.V2_Version,
	} {
		{"v22.mp3", .V2_4},
		{"v22_pic.mp3", .V2_4},
		{"v24_full.mp3", .V2_2},
		{"v23_cover.mp3", .V2_2},
	}
	for c in cases {
		succeeded := false
		for budget in 0 ..< 160 {
			failing := Failing{context.allocator, 1 << 30}
			tags, read_err := odid3.read_bytes(fixture(t, c.name), {}, failing_allocator(&failing))
			testing.expect_value(t, read_err, nil)
			before := frames_snapshot(&tags.v2)
			failing.left = budget
			dropped, err := odid3.convert(&tags.v2, c.to, failing_allocator(&failing))
			failing.left = 1 << 30
			if err == nil {
				odid3.destroy(&dropped, failing_allocator(&failing))
				succeeded = true
			} else {
				testing.expectf(
					t,
					frames_snapshot(&tags.v2) == before,
					"%s at budget %d",
					c.name,
					budget,
				)
			}
			odid3.destroy(&tags)
			if succeeded {
				break
			}
		}
		testing.expectf(t, succeeded, "%s never converted", c.name)
	}
}

@(test)
v22_frames_are_listed_under_their_ids :: proc(t: ^testing.T) {
	// On the way to ID3v2.4, these frames pass through RVAD, TYER, TDAT, TORY and IPLS.
	file := tag_file(
		2,
		0,
		frame22("PIC", concat(text("\x01JPG\x03"), {0xFF, 0xFE, 0x00, 0xD8, 0, 0})),
		frame22("RVA", {0x03, 0x10, 0, 1, 0, 2, 0, 3, 0, 4}),
		frame22("TYE", text("\x002019\x002020")),
		frame22("TDA", text("\x000013")),
		frame22("TOR", text("\x001987\x00junk")),
		frame22("IPL", {1, 0xFF, 0xFE, 'p', 0, 0, 0, 0xFF, 0xFE, 0x00, 0xD8, 0, 0}),
	)
	tags := read(t, file)
	defer odid3.destroy(&tags)
	expect_dropped(
		t,
		convert(t, &tags.v2, .V2_4),
		{
			{"PIC", .Partly_Converted},
			{"RVA", .No_Equivalent},
			{"TDA", .No_Equivalent},
			{"TYE", .Partly_Converted},
			{"TOR", .Partly_Converted},
			{"IPL", .Partly_Converted},
		},
	)

	succeeded := false
	for budget in 0 ..< 200 {
		failing := Failing{context.allocator, 1 << 30}
		allocator := failing_allocator(&failing)
		failed, read_err := odid3.read_bytes(file, {}, allocator)
		testing.expect_value(t, read_err, nil)
		before := frames_snapshot(&failed.v2)
		failing.left = budget
		dropped, err := odid3.convert(&failed.v2, .V2_4, allocator)
		failing.left = 1 << 30
		odid3.destroy(&dropped, allocator)
		if err == nil {
			succeeded = true
		} else {
			testing.expectf(t, frames_snapshot(&failed.v2) == before, "at budget %d", budget)
		}
		odid3.destroy(&failed)
		if succeeded {
			break
		}
	}
	testing.expect(t, succeeded)

	// A frame a caller added under a 4 letter ID is dropped under that ID.
	added := read(t, tag_file(2, 0, frame22("TYE", text("\x002019"))))
	defer odid3.destroy(&added)
	for id in ([]string{"TYER", "RVAD"}) {
		f := odid3.make_frame(id, text("\x00x"), added.v2.allocator)
		testing.expect_value(t, odid3.add_frame(&added.v2, f), nil)
	}
	expect_dropped(
		t,
		convert(t, &added.v2, .V2_4),
		{{"TYER", .No_Equivalent}, {"RVAD", .No_Equivalent}},
	)
}
