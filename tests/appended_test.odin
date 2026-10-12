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
	for data in ([][]u8{concat(audio, appended, ape, v1_tag()), concat(audio, ape, appended, v1_tag())}) {
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
	leading = leading[:len(leading) - 4]
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
