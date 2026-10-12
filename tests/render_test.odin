package odid3_tests

import "core:bytes"
import "core:testing"

import odid3 "../"

@(test)
unchanged_tags_render_byte_for_byte :: proc(t: ^testing.T) {
	cases := []struct {
		name:   string,
		footer: bool,
	} {
		{"v23_full.mp3", false},
		{"v24_full.mp3", false},
		{"v23_cover.mp3", false},
		{"v23_unicode.mp3", false},
		{"v24_unicode.mp3", false},
		{"v23_comm.mp3", false},
		{"v22.mp3", false},
		{"v22_pic.mp3", false},
		{"v23_chapters.mp3", false},
		{"v24_chapters.mp3", false},
		{"v24_appended.mp3", true},
	}
	for c in cases {
		file := fixture(t, c.name)
		tags := read(t, file)
		defer odid3.destroy(&tags)
		r := tags.layout.v2 if tags.layout.v2.size > 0 else tags.layout.v2_appended
		rendered, err := odid3.render(
			&tags.v2,
			{padding = tags.v2.padding, footer = c.footer},
			context.temp_allocator,
		)
		testing.expectf(t, err == nil, "%s: %v", c.name, err)
		testing.expectf(
			t,
			bytes.equal(rendered, slice_of(file, r)),
			"%s renders otherwise",
			c.name,
		)
	}
}

@(test)
rendered_tags_read_back_the_same :: proc(t: ^testing.T) {
	for name in fixture_names(t) {
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		if tags.v2.version == .None {
			continue
		}
		rendered, err := odid3.render(&tags.v2, {}, context.temp_allocator)
		testing.expectf(t, err == nil, "%s: %v", name, err)
		again := read(t, rendered)
		defer odid3.destroy(&again)
		testing.expectf(t, len(again.v2.frames) == len(tags.v2.frames), "%s: frame count", name)
		for i in 0 ..< min(len(again.v2.frames), len(tags.v2.frames)) {
			a, b := again.v2.frames[i], tags.v2.frames[i]
			same :=
				a.id == b.id &&
				a.problem == b.problem &&
				bytes.equal(a.data, b.data) &&
				a.group == b.group &&
				a.method == b.method
			testing.expectf(t, same, "%s: frame %d (%s) differs", name, i, b.id)
		}
		testing.expect_value(t, again.v2.padding, odid3.DEFAULT_PADDING)
	}
}

@(test)
padding_and_footer :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v24_full.mp3"))
	defer odid3.destroy(&tags)
	frames_size := tags.layout.v2.size - 10 - i64(tags.v2.padding)

	plain := odid3.render(&tags.v2, {}, context.temp_allocator) or_else nil
	testing.expect_value(t, i64(len(plain)), 10 + frames_size + odid3.DEFAULT_PADDING)
	none := odid3.render(&tags.v2, {padding = 0}, context.temp_allocator) or_else nil
	testing.expect_value(t, i64(len(none)), 10 + frames_size)
	footer :=
		odid3.render(&tags.v2, {padding = 500, footer = true}, context.temp_allocator) or_else nil
	testing.expect_value(t, i64(len(footer)), 10 + frames_size + 10)
	testing.expect_value(t, string(footer[len(footer) - 10:][:3]), "3DI")
	again := read(t, concat(footer, zeros(10)))
	defer odid3.destroy(&again)
	testing.expect_value(t, again.warnings, odid3.Warnings{})
	testing.expect_value(t, again.v2.flags, odid3.Tag_Flags{.Footer})
}

@(test)
tags_that_cannot_be_rendered :: proc(t: ^testing.T) {
	expect_error :: proc(
		t: ^testing.T,
		tag: ^odid3.Tag,
		options: odid3.Write_Options,
		want: odid3.Format_Error,
		loc := #caller_location,
	) {
		_, err := odid3.render(tag, options, context.temp_allocator)
		testing.expect_value(t, err, odid3.Error(want), loc = loc)
	}
	none: odid3.Tag
	expect_error(t, &none, {}, .No_Version)

	v23 := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&v23)
	expect_error(t, &v23.v2, {footer = true}, .Not_In_Version)

	utf8 := read(t, tag_file(4, 0, frame(4, "TIT2", text("\x03Café"))))
	defer odid3.destroy(&utf8)
	utf8.v2.version = .V2_3
	expect_error(t, &utf8.v2, {}, .Encoding_Not_In_Version)

	v22_ids := read(t, fixture(t, "v22.mp3"))
	defer odid3.destroy(&v22_ids)
	v22_ids.v2.version = .V2_4
	expect_error(t, &v22_ids.v2, {}, .Bad_Frame_Id)

	skipped, _ := odid3.read_bytes(fixture(t, "v23_cover.mp3"), {skip_picture_data = true})
	defer odid3.destroy(&skipped)
	expect_error(t, &skipped.v2, {}, .Incomplete_Tag)
}

@(test)
frames_written_back_as_stored :: proc(t: ^testing.T) {
	encrypted23 := frame(3, "PRIV", concat({0x80, 0x2A}, text("secret")), 0x20, 0x60)
	encrypted24 := frame(4, "PRIV", concat({0x2A, 0x80, 0, 0, 0, 9}, text("secret")), 0x10, 0x45)
	bad_zlib := frame(3, "TIT2", concat({0, 0, 0, 20}, text("not a zlib stream")), 0, 0x80)
	too_short := frame(3, "TPE1", text("\x00A"), 0, 0x80)
	for major, i in ([]u8{3, 4, 3, 3}) {
		f := ([][]u8{encrypted23, encrypted24, bad_zlib, too_short})[i]
		file := tag_file(major, 0, f)
		tags := read(t, file)
		defer odid3.destroy(&tags)
		rendered := odid3.render(&tags.v2, {padding = 0}, context.temp_allocator) or_else nil
		testing.expectf(
			t,
			bytes.equal(rendered, file[:len(file) - 4]),
			"frame %d is not written back as stored",
			i,
		)
	}
}

// The unsynchronisation flag lied, so the bytes were never unsynchronised: they are written back as
// they were, without that flag.
@(test)
compressed_frame_with_a_lying_unsynchronisation_flag_is_kept :: proc(t: ^testing.T) {
	stored := concat({0, 0, 0, 5}, {0xFF, 0xE0, 0x01, 0x02})
	tags := read(t, tag_file(4, 0, frame(4, "TIT2", stored, 0, 0x0B)))
	defer odid3.destroy(&tags)
	rendered := odid3.render(&tags.v2, {padding = 0}, context.temp_allocator) or_else nil
	testing.expect(t, bytes.equal(rendered[10:], frame(4, "TIT2", stored, 0, 0x09)))
}
