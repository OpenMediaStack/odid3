package odid3_tests

import "core:bytes"
import "core:mem"
import "core:strings"
import "core:testing"

import odid3 "../"

expect_same_frames :: proc(
	t: ^testing.T,
	name: string,
	got, want: ^odid3.Tag,
	loc := #caller_location,
) {
	testing.expectf(t, len(got.frames) == len(want.frames), "%s: frame count", name, loc = loc)
	for i in 0 ..< min(len(got.frames), len(want.frames)) {
		a, b := got.frames[i], want.frames[i]
		same := a.id == b.id && a.problem == .None && bytes.equal(a.data, b.data)
		testing.expectf(t, same, "%s: frame %d (%s) differs", name, i, b.id, loc = loc)
	}
}

@(test)
compression_option_in_v23_and_v24 :: proc(t: ^testing.T) {
	for name in ([]string{"v23_full.mp3", "v23_cover.mp3", "v24_full.mp3", "v24_unicode.mp3"}) {
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		rendered, err := odid3.render(&tags.v2, {compression = true}, context.temp_allocator)
		testing.expectf(t, err == nil, "%s: %v", name, err)
		again := read(t, rendered)
		defer odid3.destroy(&again)
		testing.expectf(t, again.warnings == {}, "%s: %v", name, again.warnings)
		expect_same_frames(t, name, &again.v2, &tags.v2)
		want := odid3.Frame_Format{.Compression}
		if tags.v2.version == .V2_4 {
			want += {.Data_Length_Indicator}
		}
		for f in again.v2.frames {
			testing.expectf(t, f.format == want, "%s: %s has %v", name, f.id, f.format)
			testing.expectf(t, f.data_length == len(f.data), "%s: %s size", name, f.id)
		}
	}
}

@(test)
frames_compressed_one_by_one :: proc(t: ^testing.T) {
	long := strings.repeat("la ", 200, context.temp_allocator)
	value := strings.concatenate({"\x00", long}, context.temp_allocator)
	for major in ([]u8{3, 4}) {
		tags := read(
			t,
			tag_file(
				major,
				0,
				frame(major, "TIT2", text(value)),
				frame(major, "TPE1", text("\x00Kite")),
			),
		)
		defer odid3.destroy(&tags)
		tags.v2.frames[0].format += {.Compression}
		rendered, err := odid3.render(&tags.v2, {padding = 0}, context.temp_allocator)
		testing.expect_value(t, err, nil)
		testing.expectf(t, len(rendered) < len(value) / 4, "%d bytes", len(rendered))
		want_flags: u8 = 0x80 if major == 3 else 0x09
		testing.expect_value(t, rendered[10 + 9], want_flags)

		again := read(t, rendered)
		defer odid3.destroy(&again)
		expect_same_frames(t, "one by one", &again.v2, &tags.v2)
		testing.expect_value(t, again.v2.frames[1].format, odid3.Frame_Format{})
	}
}

@(test)
compressed_fixtures_read_back_the_same :: proc(t: ^testing.T) {
	for name in ([]string{"v23_compressed.mp3", "v24_compressed.mp3"}) {
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		rendered, err := odid3.render(&tags.v2, {}, context.temp_allocator)
		testing.expectf(t, err == nil, "%s: %v", name, err)
		again := read(t, rendered)
		defer odid3.destroy(&again)
		expect_same_frames(t, name, &again.v2, &tags.v2)
		for f, i in again.v2.frames {
			testing.expectf(
				t,
				f.format == tags.v2.frames[i].format,
				"%s: %s has %v",
				name,
				f.id,
				f.format,
			)
		}
	}
}

@(test)
compressed_and_unsynchronised :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v23_cover.mp3"))
	defer odid3.destroy(&tags)
	dropped, convert_err := odid3.convert(&tags.v2, .V2_4, context.temp_allocator)
	testing.expect_value(t, convert_err, nil)
	testing.expect_value(t, len(dropped), 0)
	rendered, err := odid3.render(
		&tags.v2,
		{compression = true, unsynchronisation = true},
		context.temp_allocator,
	)
	testing.expect_value(t, err, nil)
	for i in 10 ..< len(rendered) - 1 {
		if rendered[i] == 0xFF && rendered[i + 1] >= 0xE0 {
			testing.expectf(t, false, "false sync at %d", i)
			break
		}
	}
	again := read(t, rendered)
	defer odid3.destroy(&again)
	expect_same_frames(t, "v23_cover.mp3 in ID3v2.4", &again.v2, &tags.v2)
	for f in again.v2.frames {
		want := odid3.Frame_Format{.Compression, .Unsynchronisation, .Data_Length_Indicator}
		testing.expectf(t, f.format == want, "%s has %v", f.id, f.format)
	}
}

@(test)
no_compression_in_v22 :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v22.mp3"))
	defer odid3.destroy(&tags)
	_, err := odid3.render(&tags.v2, {compression = true}, context.temp_allocator)
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Not_In_Version))
}

@(test)
chapters_stay_readable :: proc(t: ^testing.T) {
	content := text("\x00A compressed chapter title")
	n := len(content)
	inner := frame(
		3,
		"TIT2",
		concat({u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)}, zlib_stored(content)),
		0,
		0x80,
	)
	tags := read(t, tag_file(3, 0, chapter_frame(3, "ch0", 0, 10, inner)))
	defer odid3.destroy(&tags)

	// A preview: the chapter converted, never written, still decodes.
	preview, err := odid3.clone(&tags.v2)
	testing.expect_value(t, err, nil)
	defer odid3.destroy(&preview)
	dropped, convert_err := odid3.convert(&preview, .V2_4, context.temp_allocator)
	testing.expect(t, convert_err == nil && len(dropped) == 0)
	decoded, decode_err := odid3.decode_frame(&preview.frames[0], .V2_4, context.temp_allocator)
	testing.expect_value(t, decode_err, nil)
	chapter := expect_content(t, decoded, odid3.Chapter)
	testing.expect(t, len(chapter.frames) == 1 && chapter.frames[0].problem == .None)
	testing.expect(t, len(chapter.frames) == 1 && bytes.equal(chapter.frames[0].data, content))

	// The option leaves chapters uncompressed, so their frames inflate once read again.
	rendered, render_err := odid3.render(&tags.v2, {compression = true}, context.temp_allocator)
	testing.expect_value(t, render_err, nil)
	again := read(t, rendered)
	defer odid3.destroy(&again)
	testing.expect(t, .Compression not_in again.v2.frames[0].format)
	reread, _ := odid3.decode_frame(&again.v2.frames[0], .V2_3, context.temp_allocator)
	inside := expect_content(t, reread, odid3.Chapter)
	testing.expect(t, len(inside.frames) == 1 && bytes.equal(inside.frames[0].data, content))
}

@(test)
compression_with_the_other_flags_and_options :: proc(t: ^testing.T) {
	title := text("\x00Grouped, compressed")
	// ID3v2.3: the decompressed size, then the group; ID3v2.4: the group, then the length.
	for major in ([]u8{3, 4}) {
		grouping: u8 = 0x20 if major == 3 else 0x40
		tags := read(
			t,
			tag_file(major, 0, frame(major, "TIT2", concat({0xFF}, title), 0, grouping)),
		)
		defer odid3.destroy(&tags)
		for options in ([]odid3.Write_Options{{compression = true}, {compression = true, unsynchronisation = true}}) {
			rendered, err := odid3.render(&tags.v2, options, context.temp_allocator)
			testing.expect_value(t, err, nil)
			want: u8 = 0xA0 if major == 3 else 0x49
			if major == 4 && options.unsynchronisation {
				want = 0x4B
			}
			testing.expect_value(t, rendered[10 + 9], want)
			again := read(t, rendered)
			defer odid3.destroy(&again)
			f := again.v2.frames[0]
			testing.expectf(
				t,
				f.group == 0xFF && bytes.equal(f.data, title),
				"ID3v2.%d %v",
				major,
				options,
			)
		}
	}

	v24 := read(t, fixture(t, "v24_full.mp3"))
	defer odid3.destroy(&v24)
	with_footer, footer_err := odid3.render(
		&v24.v2,
		{compression = true, footer = true},
		context.temp_allocator,
	)
	testing.expect_value(t, footer_err, nil)
	footed := read(t, concat(with_footer, zeros(10)))
	defer odid3.destroy(&footed)
	expect_same_frames(t, "footer", &footed.v2, &v24.v2)

	// An encrypted frame is written as stored; one encrypted by hand is not compressed either.
	encrypted := read(t, tag_file(4, 0, frame(4, "PRIV", concat({0x07}, text("secret")), 0, 0x04)))
	defer odid3.destroy(&encrypted)
	stored, _ := odid3.render(
		&encrypted.v2,
		{compression = true, padding = 0},
		context.temp_allocator,
	)
	testing.expect_value(t, stored[19], 0x04)
	by_hand := one_new_frame(.V2_4, "PRIV", text("ciphertext"))
	defer odid3.destroy(&by_hand)
	by_hand.frames[0].format = {.Encryption}
	by_hand.frames[0].method = 0x07
	ciphered, _ := odid3.render(
		&by_hand,
		{compression = true, padding = 0},
		context.temp_allocator,
	)
	testing.expect_value(t, ciphered[19], 0x04)

	empty := read(t, tag_file(4, 0, frame(4, "TIT2", nil)))
	defer odid3.destroy(&empty)
	nothing, _ := odid3.render(&empty.v2, {compression = true}, context.temp_allocator)
	back := read(t, nothing)
	defer odid3.destroy(&back)
	testing.expect(t, len(back.v2.frames) == 1 && len(back.v2.frames[0].data) == 0)
}

@(test)
compression_allocation_failures :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v23_cover.mp3"))
	defer odid3.destroy(&tags)
	succeeded := false
	for budget in 0 ..< 64 {
		failing := Failing{context.allocator, budget}
		allocator := failing_allocator(&failing)
		rendered, err := odid3.render(
			&tags.v2,
			{compression = true, unsynchronisation = true},
			allocator,
		)
		if err == nil {
			delete(rendered, allocator)
			succeeded = true
			break
		}
		testing.expect_value(t, err, odid3.Error(mem.Allocator_Error.Out_Of_Memory))
	}
	testing.expect(t, succeeded)
}
