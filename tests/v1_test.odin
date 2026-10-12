package odid3_tests

import "core:mem"
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
}

@(test)
v1_genre_numbers :: proc(t: ^testing.T) {
	expect_v1(t, "v1_genre_out_of_range.mp3", {.V1_0, "Unknown genre", "", "", "", "", 0, 200})
	testing.expect_value(t, odid3.genre_name(0), "Blues")
	testing.expect_value(t, odid3.genre_name(17), "Rock")
	testing.expect_value(t, odid3.genre_name(81), "Folk-Rock")
	testing.expect_value(t, odid3.genre_name(191), "Psybient")
	testing.expect_value(t, odid3.genre_name(192), "")
	testing.expect_value(t, odid3.genre_name(255), "")

	index, ok := odid3.genre_index(" folk-rock ")
	testing.expect(t, ok && index == 81)
	_, ok = odid3.genre_index("Chamber Folk")
	testing.expect(t, !ok)
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
no_enhanced_tag_without_v1 :: proc(t: ^testing.T) {
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
		tags, err := odid3.read_bytes(data, failing_allocator(&f))
		if err == nil {
			testing.expect_value(t, tags.v1.title, "A title that needs the Enhanced TAG to fit")
			odid3.destroy(&tags)
			return
		}
		testing.expect_value(t, err, mem.Allocator_Error.Out_Of_Memory)
	}
	testing.fail_now(t, "reading never succeeded")
}
