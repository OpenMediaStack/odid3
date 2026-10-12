package odid3_tests

import "core:bytes"
import "core:testing"

import odid3 "../"

@(test)
file_without_tags_is_all_audio :: proc(t: ^testing.T) {
	for name in ([]string{"no_tag.mp3", "garbage.mp3", "tiny_tag.mp3"}) {
		data := fixture(t, name)
		tags := read(t, data)
		defer odid3.destroy(&tags)
		testing.expectf(t, tags.v2.version == .None, "%s: v2 %v", name, tags.v2.version)
		testing.expectf(t, tags.v1.version == .None, "%s: v1 %v", name, tags.v1.version)
		testing.expectf(t, tags.warnings == {}, "%s: warnings %v", name, tags.warnings)
		expect_range(t, name, tags.layout.audio, 0, i64(len(data)))
	}
}

@(test)
empty_input :: proc(t: ^testing.T) {
	tags := read(t, nil)
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.layout, odid3.Layout{})
	testing.expect_value(t, tags.warnings, odid3.Warnings{})
}

@(test)
audio_follows_the_tags_written_by_ffmpeg :: proc(t: ^testing.T) {
	cases := []struct {
		name: string,
		v2:   odid3.V2_Version,
		v1:   odid3.V1_Version,
	} {
		{"v23_full.mp3", .V2_3, .None},
		{"v24_full.mp3", .V2_4, .None},
		{"v23_unicode.mp3", .V2_3, .None},
		{"v24_unicode.mp3", .V2_4, .None},
		{"v23_cover.mp3", .V2_3, .None},
		{"v23_v1_long_title.mp3", .V2_3, .V1_1},
		{"v1_0_ascii.mp3", .None, .V1_0},
		{"v1_1_ascii.mp3", .None, .V1_1},
		{"v1_latin1.mp3", .None, .V1_0},
		{"v1_utf8_cut.mp3", .None, .V1_0},
	}
	for c in cases {
		data := fixture(t, c.name)
		tags := read(t, data)
		defer odid3.destroy(&tags)
		testing.expectf(t, tags.v2.version == c.v2, "%s: v2 %v", c.name, tags.v2.version)
		testing.expectf(t, tags.v1.version == c.v1, "%s: v1 %v", c.name, tags.v1.version)
		testing.expectf(t, tags.warnings == {}, "%s: warnings %v", c.name, tags.warnings)

		layout := tags.layout
		testing.expect_value(t, layout.file_size, i64(len(data)))
		testing.expectf(t, layout.v2.offset == 0, "%s: v2 at %v", c.name, layout.v2.offset)
		testing.expectf(
			t,
			layout.audio.offset == layout.v2.size,
			"%s: audio at %v",
			c.name,
			layout.audio.offset,
		)
		audio := slice_of(data, layout.audio)
		testing.expectf(
			t,
			len(audio) > 2 && audio[0] == 0xFF && audio[1] & 0xE0 == 0xE0,
			"%s: the audio does not start with an MPEG frame",
			c.name,
		)
		audio_end := i64(len(data))
		if c.v1 != .None {
			audio_end -= 128
			expect_range(t, c.name, layout.v1, audio_end, 128)
		}
		testing.expect_value(t, layout.audio.offset + layout.audio.size, audio_end)
	}
}

@(test)
audio_between_hand_built_tags_is_kept_whole :: proc(t: ^testing.T) {
	no_tag := fixture(t, "no_tag.mp3")
	cases := []struct {
		name: string,
		v2:   odid3.V2_Version,
		v1:   odid3.V1_Version,
	} {
		{"v22.mp3", .V2_2, .None},
		{"v23_comm.mp3", .V2_3, .None},
		{"ape.mp3", .None, .None},
		{"ape_v1.mp3", .None, .V1_0},
		{"lyrics3v1_v1.mp3", .None, .V1_0},
		{"lyrics3v2_v1.mp3", .None, .V1_0},
		{"v1_enhanced.mp3", .None, .V1_0},
	}
	for c in cases {
		data := fixture(t, c.name)
		tags := read(t, data)
		defer odid3.destroy(&tags)
		testing.expectf(t, tags.v2.version == c.v2, "%s: v2 %v", c.name, tags.v2.version)
		testing.expectf(t, tags.v1.version == c.v1, "%s: v1 %v", c.name, tags.v1.version)
		testing.expectf(t, tags.warnings == {}, "%s: warnings %v", c.name, tags.warnings)
		testing.expectf(
			t,
			bytes.equal(slice_of(data, tags.layout.audio), no_tag),
			"%s: audio %v is not no_tag.mp3",
			c.name,
			tags.layout.audio,
		)
	}
}

@(test)
trailing_tags :: proc(t: ^testing.T) {
	audio_size := i64(len(fixture(t, "no_tag.mp3")))

	ape := fixture(t, "ape.mp3")
	tags := read(t, ape)
	expect_range(t, "ape.mp3 ape", tags.layout.ape, audio_size, i64(len(ape)) - audio_size)
	odid3.destroy(&tags)

	ape_v1 := fixture(t, "ape_v1.mp3")
	tags = read(t, ape_v1)
	size := i64(len(ape_v1))
	expect_range(t, "ape_v1.mp3 ape", tags.layout.ape, audio_size, size - 128 - audio_size)
	expect_range(t, "ape_v1.mp3 v1", tags.layout.v1, size - 128, 128)
	odid3.destroy(&tags)

	for name in ([]string{"lyrics3v1_v1.mp3", "lyrics3v2_v1.mp3"}) {
		data := fixture(t, name)
		tags = read(t, data)
		size = i64(len(data))
		expect_range(t, name, tags.layout.lyrics3, audio_size, size - 128 - audio_size)
		testing.expect(t, bytes.has_prefix(slice_of(data, tags.layout.lyrics3), {'L', 'Y'}))
		expect_range(t, name, tags.layout.v1, size - 128, 128)
		odid3.destroy(&tags)
	}

	enhanced := fixture(t, "v1_enhanced.mp3")
	tags = read(t, enhanced)
	size = i64(len(enhanced))
	expect_range(t, "v1_enhanced.mp3 TAG+", tags.layout.v1_enhanced, size - 128 - 227, 227)
	expect_range(t, "v1_enhanced.mp3 v1", tags.layout.v1, size - 128, 128)
	odid3.destroy(&tags)
}

@(test)
ape_footer_with_a_size_too_large :: proc(t: ^testing.T) {
	footer := concat(
		transmute([]u8)string("APETAGEX"),
		{0xD0, 0x07, 0, 0},
		{0xFF, 0xFF, 0, 0},
		{1, 0, 0, 0},
		{0, 0, 0, 0x80},
		zeros(8),
	)
	data := concat(zeros(100), footer)
	tags := read(t, data)
	defer odid3.destroy(&tags)
	expect_range(t, "ape", tags.layout.ape, 100, 32)
	expect_range(t, "audio", tags.layout.audio, 0, 100)
}

@(test)
tag_flags_by_version :: proc(t: ^testing.T) {
	audio := zeros(16)
	cases := []struct {
		major:      u8,
		flags:      u8,
		version:    odid3.V2_Version,
		want:       odid3.Tag_Flags,
		total_size: i64,
	} {
		{2, 0xC0, .V2_2, {.Unsynchronisation, .Compression}, 30},
		{3, 0xE0, .V2_3, {.Unsynchronisation, .Extended_Header, .Experimental}, 30},
		{3, 0x10, .V2_3, {}, 30},
		{4, 0xF0, .V2_4, {.Unsynchronisation, .Extended_Header, .Experimental, .Footer}, 40},
	}
	for c in cases {
		data := concat(v2_header(c.major, c.flags, 20), zeros(30), audio)
		tags := read(t, data)
		defer odid3.destroy(&tags)
		testing.expect_value(t, tags.v2.version, c.version)
		testing.expect_value(t, tags.v2.flags, c.want)
		expect_range(t, "v2", tags.layout.v2, 0, c.total_size)
		expect_range(t, "audio", tags.layout.audio, c.total_size, i64(len(data)) - c.total_size)
	}
}

@(test)
truncated_tag :: proc(t: ^testing.T) {
	data := concat(v2_header(3, 0, 1000), zeros(40))
	tags := read(t, data)
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Truncated_Tag})
	expect_range(t, "v2", tags.layout.v2, 0, 50)
	expect_range(t, "audio", tags.layout.audio, 50, 0)
	odid3.destroy(&tags)

	cut := fixture(t, "truncated_tag.mp3")
	tags = read(t, cut)
	testing.expect_value(t, tags.v2.version, odid3.V2_Version.V2_3)
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Truncated_Tag})
	expect_range(t, "v2", tags.layout.v2, 0, i64(len(cut)))
	odid3.destroy(&tags)
}

@(test)
headers_that_cannot_be_right :: proc(t: ^testing.T) {
	audio := zeros(200)
	not_syncsafe := concat(transmute([]u8)string("ID3"), {3, 0, 0, 0, 0, 0x80, 0})
	bad_version := concat(transmute([]u8)string("ID3"), {0xFF, 0, 0, 0, 0, 0, 10})
	for header in ([][]u8{not_syncsafe, bad_version}) {
		data := concat(header, audio)
		tags := read(t, data)
		defer odid3.destroy(&tags)
		testing.expect_value(t, tags.warnings, odid3.Warnings{.Bad_Header})
		testing.expect_value(t, tags.v2.version, odid3.V2_Version.None)
		expect_range(t, "audio", tags.layout.audio, 0, i64(len(data)))
	}
}

@(test)
version_after_2_4_is_kept_as_unknown_bytes :: proc(t: ^testing.T) {
	data := concat(v2_header(5, 0, 20), zeros(20), zeros(100))
	tags := read(t, data)
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Unsupported_Version})
	testing.expect_value(t, tags.v2.version, odid3.V2_Version.None)
	expect_range(t, "v2", tags.layout.v2, 0, 0)
	expect_range(t, "audio", tags.layout.audio, 0, i64(len(data)))
}

@(test)
second_tag_after_the_first :: proc(t: ^testing.T) {
	first := concat(v2_header(4, 0, 20), zeros(20))
	second := concat(v2_header(3, 0, 30), zeros(30))
	audio := fixture(t, "no_tag.mp3")
	data := concat(first, second, audio)
	tags := read(t, data)
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Second_V2_Tag})
	testing.expect_value(t, tags.v2.version, odid3.V2_Version.V2_4)
	expect_range(t, "v2", tags.layout.v2, 0, 30)
	expect_range(t, "audio", tags.layout.audio, 70, i64(len(audio)))
}

@(test)
v1_is_never_inside_the_v2_tag :: proc(t: ^testing.T) {
	body := zeros(140)
	copy(body[140 - 128:], "TAG")
	data := concat(v2_header(3, 0, 140), body)
	tags := read(t, data)
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.v1.version, odid3.V1_Version.None)
	expect_range(t, "v1", tags.layout.v1, 0, 0)
	expect_range(t, "audio", tags.layout.audio, 150, 0)
}
