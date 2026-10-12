package odid3_tests

import "core:bytes"
import "core:testing"

import odid3 "../"

expect_no_false_sync :: proc(t: ^testing.T, name: string, b: []u8, loc := #caller_location) {
	for i in 0 ..< len(b) - 1 {
		if b[i] == 0xFF && b[i + 1] >= 0xE0 {
			testing.expectf(t, false, "%s: false sync at %d", name, i, loc = loc)
			return
		}
	}
	testing.expectf(t, len(b) == 0 || b[len(b) - 1] != 0xFF, "%s ends with 0xFF", name, loc = loc)
}

@(test)
unsynchronisation_option_in_each_version :: proc(t: ^testing.T) {
	for name in ([]string{"v22_pic.mp3", "v23_unicode.mp3", "v23_cover.mp3", "v24_unicode.mp3", "v24_full.mp3"}) {
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		rendered, err := odid3.render(&tags.v2, {unsynchronisation = true}, context.temp_allocator)
		testing.expectf(t, err == nil, "%s: %v", name, err)
		testing.expectf(t, rendered[5] & 0x80 != 0, "%s: no unsynchronisation flag", name)
		expect_no_false_sync(t, name, rendered[10:])

		again := read(t, rendered)
		defer odid3.destroy(&again)
		testing.expectf(t, again.warnings == {}, "%s: %v", name, again.warnings)
		testing.expectf(t, .Unsynchronisation in again.v2.flags, "%s: %v", name, again.v2.flags)
		testing.expectf(t, len(again.v2.frames) == len(tags.v2.frames), "%s: frame count", name)
		for i in 0 ..< min(len(again.v2.frames), len(tags.v2.frames)) {
			a, b := again.v2.frames[i], tags.v2.frames[i]
			testing.expectf(
				t,
				a.id == b.id && bytes.equal(a.data, b.data),
				"%s: frame %d differs",
				name,
				i,
			)
			if tags.v2.version == .V2_4 {
				testing.expectf(
					t,
					.Unsynchronisation in a.format,
					"%s: frame %d not unsynchronised",
					name,
					i,
				)
			}
		}
	}
}

@(test)
whole_tag_ending_with_0xff :: proc(t: ^testing.T) {
	priv := frame(3, "PRIV", text("owner\x00\xFF"))
	tags := read(t, tag_file(3, 0, priv))
	defer odid3.destroy(&tags)
	rendered, err := odid3.render(
		&tags.v2,
		{padding = 0, unsynchronisation = true},
		context.temp_allocator,
	)
	testing.expect_value(t, err, nil)
	body := unsynchronise(priv)
	testing.expect(t, bytes.equal(rendered, concat(v2_header(3, 0x80, len(body)), body)))
	testing.expect_value(t, rendered[len(rendered) - 1], 0)

	padded, _ := odid3.render(
		&tags.v2,
		{padding = 4, unsynchronisation = true},
		context.temp_allocator,
	)
	body = unsynchronise(concat(priv, zeros(4)))
	testing.expect(t, bytes.equal(padded, concat(v2_header(3, 0x80, len(body)), body)))
}

@(test)
frames_unsynchronised_one_by_one :: proc(t: ^testing.T) {
	ff_data := text("owner\x00\xFF\xE0\xFF")
	tags := read(t, tag_file(4, 0, frame(4, "PRIV", ff_data), frame(4, "TIT2", text("\x03Title"))))
	defer odid3.destroy(&tags)

	tags.v2.frames[0].format += {.Unsynchronisation}
	rendered, err := odid3.render(&tags.v2, {padding = 0}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	want := concat(
		frame(4, "PRIV", unsynchronise(ff_data), 0, 0x02),
		frame(4, "TIT2", text("\x03Title")),
	)
	testing.expect(t, bytes.equal(rendered, concat(v2_header(4, 0, len(want)), want)))

	tags.v2.frames[1].format += {.Unsynchronisation}
	every, _ := odid3.render(&tags.v2, {padding = 0}, context.temp_allocator)
	testing.expect_value(t, every[5], 0x80)

	tags.v2.frames[0].format += {.Data_Length_Indicator}
	with_length, _ := odid3.render(&tags.v2, {padding = 0}, context.temp_allocator)
	again := read(t, with_length)
	defer odid3.destroy(&again)
	testing.expect_value(t, again.v2.frames[0].data_length, len(ff_data))
	testing.expect(t, bytes.equal(again.v2.frames[0].data, ff_data))
}

@(test)
lying_unsynchronisation_flag_is_written_plain :: proc(t: ^testing.T) {
	data := text("owner\x00\xFF\xE0")
	tags := read(t, tag_file(4, 0, frame(4, "PRIV", data, 0, 0x02)))
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.v2.frames[0].problem, odid3.Frame_Problem.Bad_Unsynchronisation)
	rendered, err := odid3.render(&tags.v2, {padding = 0}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	want := frame(4, "PRIV", data)
	testing.expect(t, bytes.equal(rendered, concat(v2_header(4, 0, len(want)), want)))

	fixed, _ := odid3.render(
		&tags.v2,
		{padding = 0, unsynchronisation = true},
		context.temp_allocator,
	)
	again := read(t, fixed)
	defer odid3.destroy(&again)
	testing.expect_value(t, again.v2.frames[0].problem, odid3.Frame_Problem.None)
	testing.expect(t, bytes.equal(again.v2.frames[0].data, data))
}

@(test)
unsynchronisation_through_write_bytes :: proc(t: ^testing.T) {
	file := fixture(t, "v23_unicode.mp3")
	tags := read(t, file)
	defer odid3.destroy(&tags)
	out, err := odid3.write_bytes(file, &tags, {unsynchronisation = true}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	again := read(t, out)
	defer odid3.destroy(&again)
	testing.expect_value(t, again.v2.flags, odid3.Tag_Flags{.Unsynchronisation})
	testing.expect(
		t,
		bytes.equal(slice_of(out, again.layout.audio), slice_of(file, tags.layout.audio)),
	)
}
