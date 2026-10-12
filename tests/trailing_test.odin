package odid3_tests

import "core:fmt"
import "core:testing"

import odid3 "../"

ape_tag :: proc(items_size: int, has_header: bool) -> []u8 {
	le :: proc(n: int) -> []u8 {
		return concat({u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24)})
	}
	magic := transmute([]u8)string("APETAGEX")
	size := items_size + 32
	flags := 0x8000_0000 if has_header else 0
	header := concat(magic, le(2000), le(size), le(1), le(flags | 0x2000_0000), zeros(8))
	footer := concat(magic, le(2000), le(size), le(1), le(flags), zeros(8))
	if has_header {
		return concat(header, zeros(items_size), footer)
	}
	return concat(zeros(items_size), footer)
}

lyrics3_v2 :: proc(lyrics: string) -> []u8 {
	body := fmt.tprintf("LYRICSBEGINLYR%05d%s", len(lyrics), lyrics)
	return transmute([]u8)fmt.tprintf("%s%06dLYRICS200", body, len(body))
}

lyrics3_v1 :: proc(lyrics: string) -> []u8 {
	return transmute([]u8)fmt.tprintf("LYRICSBEGIN%sLYRICSEND", lyrics)
}

v1_tag :: proc() -> []u8 {
	tag := zeros(128)
	copy(tag, "TAG")
	tag[127] = 255
	return tag
}

@(test)
ape_and_lyrics3_in_either_order :: proc(t: ^testing.T) {
	audio := zeros(500)
	ape := ape_tag(40, true)
	lyrics := lyrics3_v2("[00:01]Hello")
	cases := []struct {
		data:        []u8,
		ape, lyrics: odid3.Range,
	} {
		{
			concat(audio, ape, lyrics, v1_tag()),
			{500, i64(len(ape))},
			{500 + i64(len(ape)), i64(len(lyrics))},
		},
		{
			concat(audio, lyrics, ape, v1_tag()),
			{500 + i64(len(lyrics)), i64(len(ape))},
			{500, i64(len(lyrics))},
		},
	}
	for c in cases {
		tags := read(t, c.data)
		defer odid3.destroy(&tags)
		expect_range(t, "ape", tags.layout.ape, c.ape.offset, c.ape.size)
		expect_range(t, "lyrics3", tags.layout.lyrics3, c.lyrics.offset, c.lyrics.size)
		expect_range(t, "audio", tags.layout.audio, 0, 500)
	}
}

@(test)
ape_without_header_and_with_a_size_too_small :: proc(t: ^testing.T) {
	audio := zeros(300)
	no_header := ape_tag(40, false)
	tags := read(t, concat(audio, no_header))
	expect_range(t, "ape without header", tags.layout.ape, 300, 72)
	odid3.destroy(&tags)

	tiny := ape_tag(0, false)
	tiny[len(tiny) - 32 + 12] = 4
	tags = read(t, concat(audio, tiny))
	expect_range(t, "ape too small", tags.layout.ape, 300, 32)
	odid3.destroy(&tags)

	lying_header := ape_tag(40, false)
	lying_header[len(lying_header) - 32 + 23] = 0x80
	tags = read(t, concat(audio, lying_header))
	expect_range(t, "ape with a missing header", tags.layout.ape, 300, 72)
	odid3.destroy(&tags)
}

@(test)
damaged_lyrics3_is_audio :: proc(t: ^testing.T) {
	audio := zeros(300)
	good := lyrics3_v2("[00:01]Hello")
	not_digits := concat(good)
	not_digits[len(not_digits) - 15] = 'x'
	before_start := concat(good)
	copy(before_start[len(before_start) - 15:], "999999")
	no_begin := concat(good)
	copy(no_begin, "LYRICSBEGAN")
	long_v1 := lyrics3_v1(string(zeros(5101)))
	for lyrics in ([][]u8{not_digits, before_start, no_begin, long_v1}) {
		data := concat(audio, lyrics, v1_tag())
		tags := read(t, data)
		defer odid3.destroy(&tags)
		expect_range(t, "lyrics3", tags.layout.lyrics3, 0, 0)
		expect_range(t, "audio", tags.layout.audio, 0, i64(len(data)) - 128)
	}

	longest_v1 := lyrics3_v1(string(zeros(5100)))
	tags := read(t, concat(audio, longest_v1, v1_tag()))
	defer odid3.destroy(&tags)
	expect_range(t, "lyrics3 v1", tags.layout.lyrics3, 300, i64(len(longest_v1)))
}

@(test)
enhanced_tag_needs_v1 :: proc(t: ^testing.T) {
	enhanced := zeros(227)
	copy(enhanced, "TAG+")
	data := concat(zeros(300), enhanced)
	tags := read(t, data)
	defer odid3.destroy(&tags)
	expect_range(t, "TAG+", tags.layout.v1_enhanced, 0, 0)
	expect_range(t, "audio", tags.layout.audio, 0, i64(len(data)))
}
