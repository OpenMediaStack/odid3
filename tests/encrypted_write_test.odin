package odid3_tests

import "core:bytes"
import "core:testing"

import odid3 "../"

render_alone :: proc(t: ^testing.T, tag: ^odid3.Tag, loc := #caller_location) -> []u8 {
	rendered, err := odid3.render(tag, {padding = 0}, context.temp_allocator)
	testing.expect_value(t, err, nil, loc = loc)
	return rendered
}

@(test)
encrypted_and_grouped_frames_are_written_as_read :: proc(t: ^testing.T) {
	v23 := concat(
		frame(3, "PRIV", concat({0x07, 0x2A}, text("payload")), 0, 0x60),
		frame(3, "TIT2", concat({0x2A}, text("\x00Title")), 0, 0x20),
		frame(3, "PRIV", concat({0, 0, 0, 100, 0x07}, text("secret")), 0, 0xC0),
	)
	v24 := concat(
		frame(4, "PRIV", concat({0x2A, 0x07, 0, 0, 0, 7}, text("payload")), 0, 0x45),
		frame(4, "PRIV", unsynchronise({0x07, 0xFF, 0xE0, 0x01}), 0, 0x06),
		frame(4, "PRIV", concat({0x07, 0, 0, 0, 100}, text("secret")), 0, 0x0D),
	)
	for c in ([]struct {
			major:  u8,
			frames: []u8,
		}{{3, v23}, {4, v24}}) {
		tags := read(t, tag_file(c.major, 0, c.frames))
		defer odid3.destroy(&tags)
		testing.expect_value(t, tags.warnings, odid3.Warnings{})
		testing.expect_value(t, tags.v2.frames[0].problem, odid3.Frame_Problem.Encrypted)
		rendered := render_alone(t, &tags.v2)
		want := concat(v2_header(c.major, 0, len(c.frames)), c.frames)
		testing.expectf(t, bytes.equal(rendered, want), "ID3v2.%d: %x", c.major, rendered)
	}
}

@(test)
encrypted_and_grouped_flags_follow_the_version :: proc(t: ^testing.T) {
	v23 := concat(
		frame(3, "PRIV", concat({0, 0, 0, 100, 0x07, 0x2A}, text("payload")), 0, 0xE0),
		frame(3, "TIT2", concat({0x2A}, text("\x00Title")), 0, 0x20),
	)
	v24 := concat(
		frame(4, "PRIV", concat({0x2A, 0x07, 0, 0, 0, 100}, text("payload")), 0, 0x4D),
		frame(4, "TIT2", concat({0x2A}, text("\x00Title")), 0, 0x40),
	)
	tags := read(t, tag_file(3, 0, v23))
	defer odid3.destroy(&tags)
	testing.expect_value(t, len(convert(t, &tags.v2, .V2_4)), 0)
	rendered := render_alone(t, &tags.v2)
	testing.expectf(
		t,
		bytes.equal(rendered, concat(v2_header(4, 0, len(v24)), v24)),
		"%x",
		rendered,
	)

	testing.expect_value(t, len(convert(t, &tags.v2, .V2_3)), 0)
	rendered = render_alone(t, &tags.v2)
	testing.expectf(
		t,
		bytes.equal(rendered, concat(v2_header(3, 0, len(v23)), v23)),
		"%x",
		rendered,
	)
}

@(test)
grouped_frames_are_dropped_for_v22 :: proc(t: ^testing.T) {
	frames := concat(
		frame(3, "TIT2", concat({0x2A}, text("\x00Title")), 0, 0x20),
		frame(3, "TPE1", text("\x00Kite")),
	)
	tags := read(t, tag_file(3, 0, frames))
	defer odid3.destroy(&tags)
	dropped := convert(t, &tags.v2, .V2_2)
	testing.expect_value(t, len(dropped), 1)
	testing.expect_value(t, dropped[0], odid3.Dropped_Frame{"TIT2", .Grouped})
	testing.expect_value(t, len(tags.v2.frames), 1)
	testing.expect_value(t, tags.v2.frames[0].id, "TP1")
}

@(test)
seek_is_not_written :: proc(t: ^testing.T) {
	tags := read(
		t,
		tag_file(4, 0, frame(4, "SEEK", {0, 0, 0, 10}), frame(4, "TIT2", text("\x03Title"))),
	)
	defer odid3.destroy(&tags)
	again := read(t, render_alone(t, &tags.v2))
	defer odid3.destroy(&again)
	testing.expect_value(t, len(again.v2.frames), 1)
	testing.expect_value(t, again.v2.frames[0].id, "TIT2")
}
