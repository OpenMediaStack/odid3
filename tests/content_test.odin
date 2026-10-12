package odid3_tests

import "core:mem"
import "core:slice"
import "core:testing"

import odid3 "../"

decode :: proc(
	t: ^testing.T,
	f: ^odid3.Frame,
	version: odid3.V2_Version,
	loc := #caller_location,
) -> odid3.Frame_Content {
	content, err := odid3.decode_frame(f, version, context.temp_allocator)
	testing.expectf(t, err == nil, "%s: %v", f.id, err, loc = loc)
	return content
}

// The content of the only frame of a tag made of it.
decode_one :: proc(
	t: ^testing.T,
	major: u8,
	frame_bytes: []u8,
	loc := #caller_location,
) -> (
	odid3.Frame_Content,
	odid3.Error,
) {
	tags := read(t, tag_file(major, 0, frame_bytes), loc)
	defer odid3.destroy(&tags)
	return odid3.decode_frame(&tags.v2.frames[0], tags.v2.version, context.temp_allocator)
}

// The content as a T, or a failed test.
expect_content :: proc(
	t: ^testing.T,
	content: odid3.Frame_Content,
	$T: typeid,
	loc := #caller_location,
) -> T {
	value, ok := content.(T)
	testing.expectf(t, ok, "%v is not a %v", content, typeid_of(T), loc = loc)
	return value
}

frame_with_id :: proc(
	t: ^testing.T,
	tag: ^odid3.Tag,
	id: string,
	loc := #caller_location,
) -> ^odid3.Frame {
	index, ok := odid3.find_frame(tag, id)
	if !ok {
		testing.fail_now(t, "no such frame", loc)
	}
	return &tag.frames[index]
}

expect_text :: proc(
	t: ^testing.T,
	content: odid3.Frame_Content,
	encoding: odid3.Encoding,
	values: ..string,
	loc := #caller_location,
) {
	text, ok := content.(odid3.Text)
	testing.expectf(t, ok, "not a text frame: %v", content, loc = loc)
	testing.expect_value(t, text.encoding, encoding, loc = loc)
	testing.expectf(
		t,
		slice.equal(text.values, values),
		"values %q, want %q",
		text.values,
		values,
		loc = loc,
	)
}

@(test)
every_fixture_frame_decodes :: proc(t: ^testing.T) {
	for name in fixture_names(t) {
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		for &f in tags.v2.frames {
			content, err := odid3.decode_frame(&f, tags.v2.version)
			defer odid3.destroy(&content)
			decodable :=
				f.problem == .None ||
				f.problem == .Bad_Data_Length ||
				f.problem == .Bad_Unsynchronisation && f.format & {.Compression, .Encryption} == {}
			switch {
			case decodable:
				testing.expectf(t, err == nil, "%s %s: %v", name, f.id, err)
			case:
				testing.expectf(
					t,
					err == odid3.Format_Error.Not_Decodable,
					"%s %s: %v",
					name,
					f.id,
					err,
				)
			}
		}
	}
}

@(test)
text_in_every_encoding :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&tags)
	expect_text(t, decode(t, &tags.v2.frames[0], .V2_3), .Latin1, "Paper Satellites")

	unicode23 := read(t, fixture(t, "v23_unicode.mp3"))
	defer odid3.destroy(&unicode23)
	expect_text(t, decode(t, &unicode23.v2.frames[0], .V2_3), .UTF16, "Café")
	expect_text(t, decode(t, &unicode23.v2.frames[1], .V2_3), .UTF16, "坂本龍一")
	expect_text(t, decode(t, &unicode23.v2.frames[2], .V2_3), .UTF16, "Ελληνικά")

	unicode24 := read(t, fixture(t, "v24_unicode.mp3"))
	defer odid3.destroy(&unicode24)
	expect_text(t, decode(t, &unicode24.v2.frames[1], .V2_4), .UTF8, "坂本龍一")

	be, _ := decode_one(t, 4, frame(4, "TIT2", text("\x02\x00C\x00a\x00f\x00\xE9")))
	expect_text(t, be, .UTF16BE, "Café")
	bom_be, _ := decode_one(t, 3, frame(3, "TIT2", text("\x01\xFE\xFF\x00C\x00a")))
	expect_text(t, bom_be, .UTF16, "Ca")
	no_bom, _ := decode_one(t, 3, frame(3, "TIT2", text("\x01C\x00a\x00")))
	expect_text(t, no_bom, .UTF16, "Ca")
	not_utf8, _ := decode_one(t, 4, frame(4, "TIT2", text("\x03Caf\xE9")))
	expect_text(t, not_utf8, .UTF8, "Café")
}

@(test)
utf16_corner_cases :: proc(t: ^testing.T) {
	pair, _ := decode_one(t, 3, frame(3, "TIT2", text("\x01\xFF\xFE\x3D\xD8\x00\xDE")))
	expect_text(t, pair, .UTF16, "😀")
	lone_high, _ := decode_one(t, 3, frame(3, "TIT2", text("\x01\xFF\xFE\x3D\xD8A\x00")))
	expect_text(t, lone_high, .UTF16, "�A")
	lone_low, _ := decode_one(t, 3, frame(3, "TIT2", text("\x01\xFF\xFE\x00\xDEA\x00")))
	expect_text(t, lone_low, .UTF16, "�A")
	odd_byte, _ := decode_one(t, 3, frame(3, "TIT2", text("\x01\xFF\xFEA\x00B")))
	expect_text(t, odd_byte, .UTF16, "A")
	inner_bom, _ := decode_one(t, 3, frame(3, "TIT2", text("\x01\xFF\xFEA\x00\xFF\xFEB\x00")))
	expect_text(t, inner_bom, .UTF16, "AB")
}

@(test)
several_values_in_v24_only :: proc(t: ^testing.T) {
	v24, _ := decode_one(t, 4, frame(4, "TCON", text("\x03Rock\x00Pop")))
	expect_text(t, v24, .UTF8, "Rock", "Pop")
	terminated, _ := decode_one(t, 4, frame(4, "TCON", text("\x03Rock\x00")))
	expect_text(t, terminated, .UTF8, "Rock")
	utf16 := concat({1}, text("\xFF\xFER\x00\x00\x00\xFE\xFF\x00P"))
	two_boms, _ := decode_one(t, 4, frame(4, "TPE1", utf16))
	expect_text(t, two_boms, .UTF16, "R", "P")
	v23, _ := decode_one(t, 3, frame(3, "TCON", text("\x00Rock\x00Pop")))
	expect_text(t, v23, .Latin1, "Rock")
	empty, _ := decode_one(t, 4, frame(4, "TCON", text("\x03")))
	expect_text(t, empty, .UTF8)
}

@(test)
user_text_comments_and_urls :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v24_full.mp3"))
	defer odid3.destroy(&tags)
	// The first TXXX holds ffmpeg's comment.
	first, _ := odid3.find_frame(&tags.v2, "TXXX")
	index, found := odid3.find_frame(&tags.v2, "TXXX", first + 1)
	testing.expect(t, found)
	mood := expect_content(t, decode(t, &tags.v2.frames[index], .V2_4), odid3.User_Text)
	testing.expect_value(t, mood.description, "mood")
	testing.expect(t, slice.equal(mood.values, []string{"Calm"}))

	comm := read(t, fixture(t, "v23_comm.mp3"))
	defer odid3.destroy(&comm)
	comment := expect_content(
		t,
		decode(t, frame_with_id(t, &comm.v2, "COMM"), .V2_3),
		odid3.Comment,
	)
	testing.expect_value(t, comment.language, [3]u8{'e', 'n', 'g'})
	testing.expect_value(t, comment.description, "")
	testing.expect_value(t, comment.text, "Recorded in one take.")

	v22 := read(t, fixture(t, "v22.mp3"))
	defer odid3.destroy(&v22)
	v22_comment := expect_content(
		t,
		decode(t, frame_with_id(t, &v22.v2, "COM"), .V2_2),
		odid3.Comment,
	)
	testing.expect_value(t, v22_comment.text, "Recorded in one take.")
	expect_text(t, decode(t, frame_with_id(t, &v22.v2, "TCO"), .V2_2), .Latin1, "(17)")

	url, _ := decode_one(t, 3, frame(3, "WOAR", text("https://example.com/artist\x00")))
	testing.expect_value(t, expect_content(t, url, odid3.Url).url, "https://example.com/artist")
	user_url, _ := decode_one(t, 4, frame(4, "WXXX", text("\x03Shop\x00https://example.com")))
	testing.expect_value(t, expect_content(t, user_url, odid3.User_Url).description, "Shop")
	testing.expect_value(t, expect_content(t, user_url, odid3.User_Url).url, "https://example.com")
	lyrics, _ := decode_one(t, 3, frame(3, "USLT", text("\x00fraVerse\x00La la")))
	testing.expect_value(t, expect_content(t, lyrics, odid3.Comment).description, "Verse")
	testing.expect_value(t, expect_content(t, lyrics, odid3.Comment).text, "La la")
}

@(test)
pictures :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v23_cover.mp3"))
	defer odid3.destroy(&tags)
	picture := expect_content(
		t,
		decode(t, frame_with_id(t, &tags.v2, "APIC"), .V2_3),
		odid3.Picture,
	)
	testing.expect_value(t, picture.mime, "image/png")
	testing.expect_value(t, picture.type, odid3.Picture_Type.Front_Cover)
	testing.expect(t, len(picture.data) > 8 && string(picture.data[1:4]) == "PNG")

	v22 := read(t, fixture(t, "v22_pic.mp3"))
	defer odid3.destroy(&v22)
	pic := expect_content(t, decode(t, frame_with_id(t, &v22.v2, "PIC"), .V2_2), odid3.Picture)
	testing.expect_value(t, pic.mime, "image/png")
	testing.expect_value(t, pic.type, odid3.Picture_Type.Front_Cover)
	testing.expect_value(t, pic.description, "")
	testing.expect(t, string(pic.data[1:4]) == "PNG")

	described, _ := decode_one(
		t,
		4,
		frame(4, "APIC", text("\x03image/jpeg\x00\x04Back\x00\xFF\xD8")),
	)
	back := expect_content(t, described, odid3.Picture)
	testing.expect_value(t, back.type, odid3.Picture_Type.Back_Cover)
	testing.expect_value(t, back.description, "Back")
	testing.expect_value(t, string(back.data), "\xFF\xD8")
}

@(test)
binary_frames :: proc(t: ^testing.T) {
	ufid, _ := decode_one(t, 4, frame(4, "UFID", text("http://musicbrainz.org\x00id-123")))
	testing.expect_value(
		t,
		expect_content(t, ufid, odid3.Unique_File_Id).owner,
		"http://musicbrainz.org",
	)
	testing.expect_value(
		t,
		string(expect_content(t, ufid, odid3.Unique_File_Id).identifier),
		"id-123",
	)
	popm, _ := decode_one(t, 3, frame(3, "POPM", text("me@example.com\x00\xC4\x00\x00\x01\x02")))
	testing.expect_value(t, expect_content(t, popm, odid3.Popularimeter).rating, 0xC4)
	testing.expect_value(t, expect_content(t, popm, odid3.Popularimeter).counter, 258)
	popm_no_counter, _ := decode_one(t, 3, frame(3, "POPM", text("me@example.com\x00\x01")))
	testing.expect_value(t, expect_content(t, popm_no_counter, odid3.Popularimeter).counter, 0)
	pcnt, _ := decode_one(t, 3, frame(3, "PCNT", {0, 0, 0, 7}))
	testing.expect_value(t, expect_content(t, pcnt, odid3.Play_Counter).counter, 7)
	huge, _ := decode_one(t, 3, frame(3, "PCNT", {1, 0, 0, 0, 0, 0, 0, 0, 0}))
	testing.expect_value(t, expect_content(t, huge, odid3.Play_Counter).counter, max(u64))
	priv, _ := decode_one(t, 4, frame(4, "PRIV", text("WM/Provider\x00\x01\x02")))
	testing.expect_value(t, expect_content(t, priv, odid3.Private).owner, "WM/Provider")
	testing.expect_value(t, string(expect_content(t, priv, odid3.Private).data), "\x01\x02")
	other, _ := decode_one(t, 4, frame(4, "MCDI", {1, 2, 3}))
	testing.expect_value(t, string(expect_content(t, other, odid3.Binary).data), "\x01\x02\x03")
}

@(test)
contents_that_cannot_be_right :: proc(t: ^testing.T) {
	cases := [][]u8 {
		frame(4, "TIT2", text("\x04Title")),
		frame(4, "TIT2", {}),
		frame(4, "COMM", text("\x03en")),
		frame(4, "APIC", text("\x03image/png")),
		frame(4, "POPM", text("me@example.com")),
		frame(4, "APIC", text("\x00image/jpeg\x00\x03\xFF\xD8\xFF\xE0")),
	}
	for c in cases {
		_, err := decode_one(t, 4, c)
		testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Bad_Content))
	}
	_, err := decode_one(t, 3, frame(3, "PRIV", concat({0x80}, text("secret")), 0, 0x40))
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Not_Decodable))
}

@(test)
decoding_allocation_failures_leak_nothing :: proc(t: ^testing.T) {
	tags := read(
		t,
		tag_file(
			4,
			0,
			frame(4, "APIC", text("\x01image/png\x00\x03\xFF\xFED\x00\x00\x00\x89PNG")),
			frame(4, "TCON", text("\x03Rock\x00Pop\x00Jazz")),
			frame(4, "COMM", text("\x03engNote\x00Text")),
			frame(4, "TXXX", text("\x03mood\x00Calm\x00Warm")),
			frame(4, "WXXX", text("\x03Shop\x00https://example.com")),
			frame(4, "UFID", text("owner\x00id")),
			frame(4, "POPM", text("me@example.com\x00\x01\x02")),
			frame(4, "PRIV", text("owner\x00data")),
		),
	)
	defer odid3.destroy(&tags)
	for &f in tags.v2.frames {
		for budget in 0 ..< 16 {
			failing := Failing{context.allocator, budget}
			allocator := failing_allocator(&failing)
			content, err := odid3.decode_frame(&f, .V2_4, allocator)
			if err == nil {
				odid3.destroy(&content, allocator)
				break
			}
			testing.expect_value(t, err, odid3.Error(mem.Allocator_Error.Out_Of_Memory))
		}
	}
}

@(test)
compressed_frame_with_a_lying_unsynchronisation_flag :: proc(t: ^testing.T) {
	stored := concat({0, 0, 0, 5}, {0xFF, 0xE0, 0x01, 0x02})
	_, err := decode_one(t, 4, frame(4, "TIT2", stored, 0, 0x0B))
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Not_Decodable))
}

@(test)
itunes_text_frames :: proc(t: ^testing.T) {
	feed, _ := decode_one(t, 3, frame(3, "WFED", text("\x00http://example.com/feed.xml\x00")))
	expect_text(t, feed, .Latin1, "http://example.com/feed.xml")
	grouping, _ := decode_one(t, 4, frame(4, "GRP1", text("\x03Group")))
	expect_text(t, grouping, .UTF8, "Group")
	movement, _ := decode_one(t, 4, frame(4, "MVNM", text("\x03Allegro")))
	expect_text(t, movement, .UTF8, "Allegro")
}

@(test)
v22_frame_ids :: proc(t: ^testing.T) {
	tags := read(
		t,
		tag_file(
			2,
			0,
			frame22("TXX", text("\x00mood\x00Calm")),
			frame22("WXX", text("\x00Shop\x00https://example.com")),
			frame22("UFI", text("owner\x00id")),
			frame22("POP", text("me@example.com\x00\x80\x00\x00\x00\x03")),
			frame22("CNT", {0, 0, 0, 9}),
		),
	)
	defer odid3.destroy(&tags)
	frames := tags.v2.frames[:]
	testing.expect_value(t, len(frames), 5)
	mood := expect_content(t, decode(t, &frames[0], .V2_2), odid3.User_Text)
	testing.expect_value(t, mood.description, "mood")
	testing.expect(t, slice.equal(mood.values, []string{"Calm"}))
	testing.expect_value(
		t,
		expect_content(t, decode(t, &frames[1], .V2_2), odid3.User_Url).url,
		"https://example.com",
	)
	testing.expect_value(
		t,
		expect_content(t, decode(t, &frames[2], .V2_2), odid3.Unique_File_Id).owner,
		"owner",
	)
	popm := expect_content(t, decode(t, &frames[3], .V2_2), odid3.Popularimeter)
	testing.expect_value(t, popm.rating, 0x80)
	testing.expect_value(t, popm.counter, 3)
	testing.expect_value(
		t,
		expect_content(t, decode(t, &frames[4], .V2_2), odid3.Play_Counter).counter,
		9,
	)
}

@(test)
utf16_strings_of_one_frame :: proc(t: ^testing.T) {
	comm, _ := decode_one(
		t,
		3,
		frame(3, "COMM", text("\x01eng\xFF\xFEN\x00\x00\x00\xFF\xFET\x00")),
	)
	comment := expect_content(t, comm, odid3.Comment)
	testing.expect_value(t, comment.description, "N")
	testing.expect_value(t, comment.text, "T")

	big, _ := decode_one(t, 3, frame(3, "COMM", text("\x01eng\xFE\xFF\x00N\x00\x00\x00T")))
	testing.expect_value(t, expect_content(t, big, odid3.Comment).text, "T")

	user, _ := decode_one(
		t,
		4,
		frame(4, "TXXX", text("\x01\xFE\xFF\x00D\x00\x00\x00A\x00\x00\x00B")),
	)
	user_text := expect_content(t, user, odid3.User_Text)
	testing.expect_value(t, user_text.description, "D")
	testing.expect(t, slice.equal(user_text.values, []string{"A", "B"}))

	values, _ := decode_one(t, 4, frame(4, "TPE1", text("\x01\xFE\xFF\x00A\x00\x00\x00B")))
	expect_text(t, values, .UTF16, "A", "B")
}

@(test)
utf8_byte_order_mark_is_dropped :: proc(t: ^testing.T) {
	title, _ := decode_one(t, 4, frame(4, "TIT2", text("\x03\xEF\xBB\xBFTitle")))
	expect_text(t, title, .UTF8, "Title")
}

@(test)
pictures_given_by_url_or_unknown_format :: proc(t: ^testing.T) {
	linked, _ := decode_one(
		t,
		3,
		frame(3, "APIC", text("\x00-->\x00\x03\x00http://example.com/cover.jpg")),
	)
	picture := expect_content(t, linked, odid3.Picture)
	testing.expect_value(t, picture.mime, "-->")
	testing.expect_value(t, string(picture.data), "http://example.com/cover.jpg")

	unknown, _ := decode_one(
		t,
		2,
		frame22("PIC", {0x00, 0xE9, 0x00, 0xFF, 0x03, 0x00, 0xFF, 0xD8}),
	)
	testing.expect_value(t, expect_content(t, unknown, odid3.Picture).mime, "\u00e9\x00\u00ff")
}

@(test)
frames_that_are_not_their_content :: proc(t: ^testing.T) {
	tags, err := odid3.read_bytes(
		fixture(t, "v23_cover.mp3"),
		{skip_picture_data = true},
		context.allocator,
	)
	testing.expect_value(t, err, nil)
	defer odid3.destroy(&tags)
	skipped := frame_with_id(t, &tags.v2, "APIC")
	testing.expect_value(t, skipped.problem, odid3.Frame_Problem.Skipped_Picture)
	_, skipped_err := odid3.decode_frame(skipped, .V2_3, context.temp_allocator)
	testing.expect_value(t, skipped_err, odid3.Error(odid3.Format_Error.Not_Decodable))

	_, short_err := decode_one(t, 3, frame(3, "TIT2", text("\x00A"), 0, 0x80))
	testing.expect_value(t, short_err, odid3.Error(odid3.Format_Error.Not_Decodable))
}

@(test)
plain_frame_with_a_lying_unsynchronisation_flag :: proc(t: ^testing.T) {
	content, err := decode_one(t, 4, frame(4, "TIT2", text("\x00A\xFF\xE0B"), 0, 0x02))
	testing.expect_value(t, err, nil)
	expect_text(t, content, .Latin1, "A\u00ff\u00e0B")
}
