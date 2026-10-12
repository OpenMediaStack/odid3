package odid3_tests

import "core:bytes"
import "core:mem"
import "core:slice"
import "core:strings"
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
		// Only problems kept with their frames come back: iTunes' plain sizes are gone.
		kept := tags.warnings & {.Frame_Problems}
		testing.expectf(t, again.warnings <= kept, "%s: %v", name, again.warnings)
		testing.expectf(t, len(again.v2.frames) == len(tags.v2.frames), "%s: frame count", name)
		for i in 0 ..< min(len(again.v2.frames), len(tags.v2.frames)) {
			a, b := again.v2.frames[i], tags.v2.frames[i]
			format := b.format
			if b.problem == .None {
				// Compression and unsynchronisation on write come with their own slices.
				format -= {.Compression, .Unsynchronisation}
			}
			same :=
				a.id == b.id &&
				a.problem == b.problem &&
				bytes.equal(a.data, b.data) &&
				a.status == b.status &&
				a.format == format &&
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

// A tag holding one frame made by hand, not read from a file.
one_new_frame :: proc(version: odid3.V2_Version, id: string, data: []u8) -> (tag: odid3.Tag) {
	tag.version = version
	tag.allocator = context.allocator
	frame := odid3.Frame {
		id          = strings.clone(id),
		data        = slice.clone(data),
		offset      = -1,
		data_length = -1,
		allocator   = context.allocator,
	}
	append(&tag.frames, frame)
	return
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

	// A new frame must use an encoding its version has, and a valid ID.
	new_frames := []struct {
		version: odid3.V2_Version,
		id:      string,
		data:    string,
		want:    odid3.Format_Error,
	} {
		{.V2_3, "TIT2", "\x03Café", .Encoding_Not_In_Version},
		{.V2_4, "TIT2", "\x07Café", .Encoding_Not_In_Version},
		{.V2_4, "tit2", "\x03Title", .Bad_Frame_Id},
		{.V2_4, "\x00ABC", "\x03Title", .Bad_Frame_Id},
		{.V2_4, "TI-2", "\x03Title", .Bad_Frame_Id},
	}
	for c in new_frames {
		tag := one_new_frame(c.version, c.id, text(c.data))
		defer odid3.destroy(&tag)
		expect_error(t, &tag, {}, c.want)
	}

	invalid := odid3.Tag {
		version = odid3.V2_Version(7),
	}
	expect_error(t, &invalid, {}, .No_Version)

	compressed_v22 := read(t, tag_file(2, 0x40, zeros(20)))
	defer odid3.destroy(&compressed_v22)
	testing.expect(t, .Compressed_V22_Tag in compressed_v22.warnings)
	expect_error(t, &compressed_v22.v2, {}, .Incomplete_Tag)
	_, replaced_err := odid3.render(
		&compressed_v22.v2,
		{replace_damaged = true},
		context.temp_allocator,
	)
	testing.expect_value(t, replaced_err, nil)

	too_much := read(t, tag_file(3, 0, frame(3, "TIT2", text("\x00Title"))))
	defer odid3.destroy(&too_much)
	expect_error(t, &too_much.v2, {padding = max(int) - 5}, .Tag_Too_Large)
	expect_error(t, &too_much.v2, {padding = 1 << 28}, .Tag_Too_Large)
	big_frame := one_new_frame(.V2_2, "TT2", make([]u8, 1 << 24, context.temp_allocator))
	defer odid3.destroy(&big_frame)
	expect_error(t, &big_frame, {}, .Tag_Too_Large)

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

@(test)
what_render_keeps_and_clears :: proc(t: ^testing.T) {
	// Read in ID3v2.3 with UTF-8, which only ID3v2.4 has: written back as read.
	utf8_file := tag_file(3, 0, frame(3, "TIT2", text("\x03Café")))
	utf8 := read(t, utf8_file)
	defer odid3.destroy(&utf8)
	rendered, err := odid3.render(&utf8.v2, {padding = 0}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, bytes.equal(rendered, utf8_file[:len(utf8_file) - 4]))

	// The revision and the experimental flag are kept; reserved flag bits are cleared.
	odd := concat(text("TIT2"), {0, 0, 0, 6}, {0x1F, 0x1F}, text("\x00Title"))
	header := v2_header(3, 0x20, len(odd))
	header[4] = 1
	tags := read(t, concat(header, odd))
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.v2.revision, 1)
	out, _ := odid3.render(&tags.v2, {padding = 0}, context.temp_allocator)
	testing.expect_value(t, out[4], 1)
	testing.expect_value(t, out[5], 0x20)
	testing.expect_value(t, out[18], 0)
	testing.expect_value(t, out[19], 0)

	// A negative padding is none.
	negative, _ := odid3.render(&tags.v2, {padding = -5}, context.temp_allocator)
	testing.expect_value(t, len(negative), len(out))

	// A data length indicator too large to be syncsafe, on a frame written as stored, stays.
	stored := frame(4, "PRIV", concat({0x80, 0x7F, 0xFF, 0xFF, 0xFF}, text("secret")), 0, 0x05)
	encrypted_file := tag_file(4, 0, stored)
	encrypted := read(t, encrypted_file)
	defer odid3.destroy(&encrypted)
	testing.expect_value(t, encrypted.v2.frames[0].problem, odid3.Frame_Problem.Encrypted)
	written, _ := odid3.render(&encrypted.v2, {padding = 0}, context.temp_allocator)
	testing.expect(t, bytes.equal(written, encrypted_file[:len(encrypted_file) - 4]))
}

@(test)
render_allocation_failures_leak_nothing :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v24_chapters.mp3"))
	defer odid3.destroy(&tags)
	succeeded := false
	for budget in 0 ..< 32 {
		failing := Failing{context.allocator, budget}
		allocator := failing_allocator(&failing)
		rendered, err := odid3.render(&tags.v2, {}, allocator)
		if err == nil {
			delete(rendered, allocator)
			succeeded = true
			break
		}
		testing.expect_value(t, err, odid3.Error(mem.Allocator_Error.Out_Of_Memory))
	}
	testing.expect(t, succeeded)
}
