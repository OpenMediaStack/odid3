package odid3_tests

import "core:mem"
import "core:strings"
import "core:testing"

import odid3 "../"

V1_Want :: struct {
	version: odid3.V1_Version,
	title:   string,
	artist:  string,
	album:   string,
	year:    string,
	comment: string,
	track:   u8,
	genre:   u8,
}

expect_v1 :: proc(t: ^testing.T, name: string, want: V1_Want, loc := #caller_location) {
	tags := read(t, fixture(t, name), loc)
	defer odid3.destroy(&tags)
	v1 := tags.v1
	got := V1_Want {
		v1.version,
		v1.title,
		v1.artist,
		v1.album,
		v1.year,
		v1.comment,
		v1.track,
		v1.genre,
	}
	testing.expectf(t, got == want, "%s:\n got %v\nwant %v", name, got, want, loc = loc)
}

@(test)
v1_versions_and_fields :: proc(t: ^testing.T) {
	ascii_v1_0 := V1_Want {
		.V1_0,
		"Plain ASCII title",
		"Plain ASCII artist",
		"Plain ASCII album",
		"1999",
		"A comment of exactly 30 bytes.",
		0,
		17,
	}
	expect_v1(t, "v1_0_ascii.mp3", ascii_v1_0)
	expect_v1(
		t,
		"v1_1_ascii.mp3",
		{
			.V1_1,
			"Track seven",
			"Plain ASCII artist",
			"Plain ASCII album",
			"2004",
			"Short comment",
			7,
			81,
		},
	)
	expect_v1(t, "ape_v1.mp3", ascii_v1_0)
	expect_v1(t, "lyrics3v1_v1.mp3", ascii_v1_0)
	expect_v1(t, "lyrics3v2_v1.mp3", ascii_v1_0)
	expect_v1(
		t,
		"v23_v1_long_title.mp3",
		{.V1_1, "A title longer than thirty cha", "Marlowe Kite", "", "", "", 3, 255},
	)
}

@(test)
v1_text_in_latin1_and_utf8 :: proc(t: ^testing.T) {
	expect_v1(t, "v1_latin1.mp3", {.V1_0, "Café", "Björk", "Señor", "", "Latin-1", 0, 255})
	expect_v1(t, "v1_utf8.mp3", {.V1_0, "Café", "Björk", "Señor", "", "UTF-8", 0, 255})
	expect_v1(
		t,
		"v1_utf8_cut.mp3",
		{.V1_0, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcÃ", "Cut in the middle", "", "", "", 0, 255},
	)
	expect_v1(
		t,
		"v1_utf8_cut_accents.mp3",
		{.V1_0, "Crème brûlée, à la franç", "", "", "", "", 0, 255},
	)
}

// An ID3v1 tag with the given title and comment, and the Enhanced TAG continuing the title.
v1_with_enhanced :: proc(title, more_title: []u8, comment: []u8 = nil, track: u8 = 0) -> []u8 {
	v1 := zeros(128)
	copy(v1, "TAG")
	copy(v1[3:33], title)
	copy(v1[97:127], comment)
	v1[126] = track if track != 0 else v1[126]
	v1[127] = 255
	if more_title == nil {
		return concat(zeros(200), v1)
	}
	enhanced := zeros(227)
	copy(enhanced, "TAG+")
	copy(enhanced[4:64], more_title)
	return concat(zeros(200), enhanced, v1)
}

v1_title :: proc(t: ^testing.T, data: []u8, loc := #caller_location) -> string {
	tags := read(t, data, loc)
	title := strings.clone(tags.v1.title, context.temp_allocator)
	odid3.destroy(&tags)
	return title
}

@(test)
enhanced_tag_continues_full_fields_only :: proc(t: ^testing.T) {
	thirty := text("ABCDEFGHIJKLMNOPQRSTUVWXYZabcd")
	testing.expect_value(
		t,
		v1_title(t, v1_with_enhanced(text("Short"), text("continued"))),
		"Short",
	)
	testing.expect_value(
		t,
		v1_title(t, v1_with_enhanced(thirty, text("continued"))),
		"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdcontinued",
	)
	split_utf8 := concat(thirty[:29], {0xC3})
	testing.expect_value(
		t,
		v1_title(t, v1_with_enhanced(split_utf8, concat({0xA9}, text("nd")))),
		"ABCDEFGHIJKLMNOPQRSTUVWXYZabcénd",
	)
	latin1 := concat(thirty[:29], {0xE9})
	testing.expect_value(
		t,
		v1_title(t, v1_with_enhanced(latin1, text("nd"))),
		"ABCDEFGHIJKLMNOPQRSTUVWXYZabcénd",
	)
	// A field padded with spaces has no NUL, so it counts as full and its spaces stay.
	padded := concat(text("Short"), transmute([]u8)strings.repeat(" ", 25, context.temp_allocator))
	testing.expect_value(
		t,
		v1_title(t, v1_with_enhanced(padded, text("continued"))),
		"Short                         continued",
	)
}

@(test)
v1_spaces_and_control_bytes :: proc(t: ^testing.T) {
	testing.expect_value(t, v1_title(t, v1_with_enhanced(text("Padded     "), nil)), "Padded")
	testing.expect_value(t, v1_title(t, v1_with_enhanced(text("      "), nil)), "")
	testing.expect_value(t, v1_title(t, v1_with_enhanced({0x80, 0x9F}, nil)), "\u0080\u009F")

	tags := read(t, v1_with_enhanced(text("Title"), nil, nil, 5))
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.v1.version, odid3.V1_Version.V1_1)
	testing.expect_value(t, tags.v1.comment, "")
	testing.expect_value(t, tags.v1.track, 5)
}

@(test)
v1_genre_numbers :: proc(t: ^testing.T) {
	expect_v1(t, "v1_genre_out_of_range.mp3", {.V1_0, "Unknown genre", "", "", "", "", 0, 200})
	testing.expect_value(t, odid3.genre_name(0), "Blues")
	testing.expect_value(t, odid3.genre_name(17), "Rock")
	testing.expect_value(t, odid3.genre_name(81), "Folk-Rock")
	testing.expect_value(t, odid3.genre_name(191), "Psybient")
	testing.expect_value(t, odid3.genre_name(67), "Psychedelic")
	testing.expect_value(t, odid3.genre_name(85), "Bebop")
	testing.expect_value(t, odid3.genre_name(123), "A Cappella")
	testing.expect_value(t, odid3.genre_name(192), "")
	testing.expect_value(t, odid3.genre_name(255), "")

	index, ok := odid3.genre_index(" folk-rock ")
	testing.expect(t, ok && index == 81)
	_, ok = odid3.genre_index("Chamber Folk")
	testing.expect(t, !ok)
	index, ok = odid3.genre_index("Psychadelic")
	testing.expect(t, ok && index == 67)
	index, ok = odid3.genre_index("bebob")
	testing.expect(t, ok && index == 85)
	index, ok = odid3.genre_index("A capella")
	testing.expect(t, ok && index == 123)
}

@(test)
enhanced_tag :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v1_enhanced.mp3"))
	defer odid3.destroy(&tags)
	v1 := tags.v1
	testing.expect_value(t, v1.version, odid3.V1_Version.V1_0)
	testing.expect_value(t, v1.title, "A title that needs the Enhanced TAG to fit")
	testing.expect_value(t, v1.artist, "Marlowe Kite")
	testing.expect_value(t, v1.album, "Small Hours")
	testing.expect_value(t, v1.year, "2019")
	testing.expect_value(t, v1.genre, 255)
	enhanced, ok := v1.enhanced.?
	testing.expect(t, ok)
	testing.expect_value(t, enhanced.speed, 2)
	testing.expect_value(t, enhanced.genre, "Chamber Folk")
	testing.expect_value(t, enhanced.start_time, "000:05")
	testing.expect_value(t, enhanced.end_time, "001:30")
}

@(test)
no_enhanced_tag_without_tag_plus :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v1_1_ascii.mp3"))
	defer odid3.destroy(&tags)
	_, ok := tags.v1.enhanced.?
	testing.expect(t, !ok)
}

@(test)
allocation_failures_leak_nothing :: proc(t: ^testing.T) {
	data := fixture(t, "v1_enhanced.mp3")
	for budget in 0 ..< 32 {
		f := Failing{context.allocator, budget}
		tags, err := odid3.read_bytes(data, {}, failing_allocator(&f))
		if err == nil {
			testing.expect_value(t, tags.v1.title, "A title that needs the Enhanced TAG to fit")
			odid3.destroy(&tags)
			return
		}
		testing.expect_value(t, err, mem.Allocator_Error.Out_Of_Memory)
	}
	testing.fail_now(t, "reading never succeeded")
}
