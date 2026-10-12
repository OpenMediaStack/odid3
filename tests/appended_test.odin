package odid3_tests

import "core:bytes"
import "core:testing"

import odid3 "../"

// An ID3v2.4 tag with a footer, holding body.
tag_with_footer :: proc(body: ..[]u8) -> []u8 {
	content := concat(..body)
	header := v2_header(4, 0x10, len(content))
	footer := concat(text("3DI"), header[3:])
	return concat(header, content, footer)
}

@(test)
appended_tag :: proc(t: ^testing.T) {
	file := fixture(t, "v24_appended.mp3")
	tags := read(t, file)
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.warnings, odid3.Warnings{})
	testing.expect_value(t, tags.v2.version, odid3.V2_Version.V2_4)
	testing.expect_value(t, tags.v2.flags, odid3.Tag_Flags{.Footer})
	testing.expect_value(t, string(tags.v2.frames[0].data), "\x03Appended title")
	testing.expect_value(t, string(file[tags.v2.frames[1].offset:][:4]), "TPE1")
	testing.expect_value(t, tags.v1.title, "Plain ASCII title")

	audio := fixture(t, "no_tag.mp3")
	expect_range(t, "v2", tags.layout.v2, 0, 0)
	expect_range(
		t,
		"appended",
		tags.layout.v2_appended,
		i64(len(audio)),
		i64(len(file) - len(audio) - 128),
	)
	testing.expect(t, bytes.equal(slice_of(file, tags.layout.audio), audio))
}

@(test)
appended_tag_and_ape_in_either_order :: proc(t: ^testing.T) {
	appended := tag_with_footer(frame(4, "TIT2", text("\x03Appended")))
	ape := ape_tag(40, true)
	audio := zeros(300)
	for data in ([][]u8 {
			concat(audio, appended, ape, v1_tag()),
			concat(audio, ape, appended, v1_tag()),
		}) {
		tags := read(t, data)
		defer odid3.destroy(&tags)
		testing.expect_value(t, tags.layout.v2_appended.size, i64(len(appended)))
		testing.expect_value(t, tags.layout.ape.size, i64(len(ape)))
		expect_range(t, "audio", tags.layout.audio, 0, 300)
		testing.expect_value(t, string(tags.v2.frames[0].data), "\x03Appended")
	}
}

@(test)
leading_and_appended_tags :: proc(t: ^testing.T) {
	leading := tag_file(3, 0, frame(3, "TIT2", text("\x00Leading")))
	appended := tag_with_footer(frame(4, "TIT2", text("\x03Appended")))
	tags := read(t, concat(leading, zeros(300), appended))
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Second_V2_Tag})
	testing.expect_value(t, string(tags.v2.frames[0].data), "\x00Leading")
	testing.expect_value(t, tags.layout.v2_appended.size, i64(len(appended)))
}

@(test)
footers_that_do_not_match :: proc(t: ^testing.T) {
	good := tag_with_footer(frame(4, "TIT2", text("\x03Title")))
	wrong_footer := concat(good)
	wrong_footer[len(wrong_footer) - 1] += 1
	tags := read(t, concat(wrong_footer, zeros(200)))
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Bad_Footer})
	testing.expect_value(t, len(tags.v2.frames), 1)
	odid3.destroy(&tags)

	tags = read(t, concat(zeros(200), wrong_footer))
	expect_range(t, "appended", tags.layout.v2_appended, 0, 0)
	expect_range(t, "audio", tags.layout.audio, 0, i64(200 + len(wrong_footer)))
	testing.expect_value(t, tags.v2.version, odid3.V2_Version.None)
	odid3.destroy(&tags)

	no_header := concat(good)
	copy(no_header, "XYZ")
	tags = read(t, concat(zeros(200), no_header))
	expect_range(t, "appended", tags.layout.v2_appended, 0, 0)
	odid3.destroy(&tags)
}

@(test)
appended_tag_and_lyrics3_in_either_order :: proc(t: ^testing.T) {
	appended := tag_with_footer(frame(4, "TIT2", text("\x03Appended")))
	lyrics := lyrics3_v2("Some lyrics")
	audio := zeros(300)
	for data in ([][]u8 {
			concat(audio, appended, lyrics, v1_tag()),
			concat(audio, lyrics, appended),
		}) {
		tags := read(t, data)
		defer odid3.destroy(&tags)
		testing.expect_value(t, tags.layout.v2_appended.size, i64(len(appended)))
		testing.expect_value(t, tags.layout.lyrics3.size, i64(len(lyrics)))
		expect_range(t, "audio", tags.layout.audio, 0, 300)
		testing.expect_value(t, string(tags.v2.frames[0].data), "\x03Appended")
	}
}

@(test)
appended_tag_holding_what_looks_like_id3v1 :: proc(t: ^testing.T) {
	appended := tag_with_footer(frame(4, "PRIV", letters(200)))
	data := concat(zeros(300), appended)
	copy(data[len(data) - 128:], "TAG")
	tags := read(t, data)
	defer odid3.destroy(&tags)
	expect_range(t, "v1", tags.layout.v1, 0, 0)
	expect_range(t, "appended", tags.layout.v2_appended, 300, i64(len(appended)))
	testing.expect_value(t, tags.warnings, odid3.Warnings{})
}

@(test)
footers_that_are_not_appended_tags :: proc(t: ^testing.T) {
	no_flag := concat(v2_header(4, 0, 30), letters(30), text("3DI"), v2_header(4, 0, 30)[3:])
	v23 := concat(v2_header(3, 0x10, 30), letters(30), text("3DI"), v2_header(3, 0x10, 30)[3:])
	for footer in ([][]u8{no_flag, v23}) {
		data := concat(zeros(300), footer)
		tags := read(t, data)
		defer odid3.destroy(&tags)
		expect_range(t, "appended", tags.layout.v2_appended, 0, 0)
		expect_range(t, "audio", tags.layout.audio, 0, i64(len(data)))
	}

	// A footer whose size reaches back into the leading tag, where a matching header seems to be.
	owner := text("owner\x00")
	priv_size := len(owner) + 10
	leading_size := 10 + 10 + priv_size
	fake := v2_header(4, 0x10, leading_size + 20 + 10 - 20 - (20 + len(owner)))
	leading := concat(v2_header(4, 0, 10 + priv_size), frame(4, "PRIV", concat(owner, fake)))
	data := concat(leading, letters(20), text("3DI"), fake[3:])
	tags := read(t, data)
	defer odid3.destroy(&tags)
	expect_range(t, "appended", tags.layout.v2_appended, 0, 0)
	expect_range(t, "audio", tags.layout.audio, i64(leading_size), 30)
	testing.expect_value(t, len(tags.v2.frames), 1)
}

@(test)
footer_flag_without_a_footer :: proc(t: ^testing.T) {
	content := frame(4, "TIT2", text("\x03Title"))
	audio := []u8{0xFF, 0xFB, 0x90, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	data := concat(v2_header(4, 0x10, len(content)), content, audio)
	tags := read(t, data)
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Bad_Footer})
	testing.expect_value(t, string(tags.v2.frames[0].data), "\x03Title")
	expect_range(t, "v2", tags.layout.v2, 0, i64(10 + len(content)))
	expect_range(t, "audio", tags.layout.audio, i64(10 + len(content)), i64(len(audio)))

	stacked := concat(v2_header(4, 0, len(content)), content, data)
	again := read(t, stacked)
	defer odid3.destroy(&again)
	testing.expect_value(t, again.warnings, odid3.Warnings{.Second_V2_Tag, .Bad_Footer})
	expect_range(t, "audio", again.layout.audio, i64(2 * (10 + len(content))), i64(len(audio)))
}
