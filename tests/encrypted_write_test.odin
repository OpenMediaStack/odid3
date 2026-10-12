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

@(test)
seek_is_kept_before_v24 :: proc(t: ^testing.T) {
	tags := read(
		t,
		tag_file(
			4,
			0,
			frame(4, "SEEK", {0, 0, 0, 10}),
			frame(4, "TIT2", unsynchronise(text("\x03\xFF\xFETitle")), 0, 0x02),
		),
	)
	defer odid3.destroy(&tags)
	rendered := render_alone(t, &tags.v2)
	testing.expect_value(t, rendered[5], 0x80)

	v23 := read(
		t,
		tag_file(3, 0, frame(3, "SEEK", {0, 0, 0, 10}), frame(3, "TIT2", text("\x00T"))),
	)
	defer odid3.destroy(&v23)
	again := read(t, render_alone(t, &v23.v2))
	defer odid3.destroy(&again)
	testing.expect_value(t, len(again.v2.frames), 2)
}

@(test)
encrypted_frames_lose_what_v23_cannot_hold :: proc(t: ^testing.T) {
	with_indicator := read(
		t,
		tag_file(4, 0, frame(4, "PRIV", concat({0x07, 0, 0, 0, 100}, text("secret")), 0, 0x05)),
	)
	defer odid3.destroy(&with_indicator)
	dropped := convert(t, &with_indicator.v2, .V2_3)
	testing.expect_value(t, len(dropped), 1)
	testing.expect_value(t, dropped[0], odid3.Dropped_Frame{"PRIV", .Encrypted})
	testing.expect_value(t, len(with_indicator.v2.frames), 0)

	unsynchronised := read(
		t,
		tag_file(4, 0, frame(4, "PRIV", unsynchronise({0x07, 0xFF, 0xE0, 0x01}), 0, 0x06)),
	)
	defer odid3.destroy(&unsynchronised)
	testing.expect_value(t, len(convert(t, &unsynchronised.v2, .V2_3)), 0)
	plain := frame(3, "PRIV", {0x07, 0xFF, 0xE0, 0x01}, 0, 0x40)
	rendered := render_alone(t, &unsynchronised.v2)
	testing.expectf(
		t,
		bytes.equal(rendered, concat(v2_header(3, 0, len(plain)), plain)),
		"%x",
		rendered,
	)
	rendered, _ = odid3.render(
		&unsynchronised.v2,
		{padding = 0, unsynchronisation = true},
		context.temp_allocator,
	)
	whole := unsynchronise(plain)
	testing.expectf(
		t,
		bytes.equal(rendered, concat(v2_header(3, 0x80, len(whole)), whole)),
		"%x",
		rendered,
	)
}

@(test)
decompressed_sizes_v24_cannot_hold_are_dropped :: proc(t: ^testing.T) {
	tags := read(
		t,
		tag_file(3, 0, frame(3, "PRIV", concat({0x10, 0, 0, 0, 0x07}, text("secret")), 0, 0xC0)),
	)
	defer odid3.destroy(&tags)
	dropped := convert(t, &tags.v2, .V2_4)
	testing.expect_value(t, len(dropped), 1)
	testing.expect_value(t, dropped[0], odid3.Dropped_Frame{"PRIV", .Encrypted})
}

@(test)
frames_too_short_for_their_flags_are_dropped :: proc(t: ^testing.T) {
	for c in ([]struct {
			major:  u8,
			frame:  []u8,
			target: odid3.V2_Version,
		}{{3, frame(3, "PRIV", {0x07, 0x2A, 0x00, 0x01}, 0, 0xC0), .V2_4}, {3, frame(3, "PRIV", {0x2A, 0x78, 0x9C}, 0, 0xA0), .V2_4}, {4, frame(4, "PRIV", {0x2A, 0x07}, 0, 0x45), .V2_3}}) {
		tags := read(t, tag_file(c.major, 0, c.frame))
		defer odid3.destroy(&tags)
		testing.expect_value(t, tags.v2.frames[0].problem, odid3.Frame_Problem.Too_Short)
		dropped := convert(t, &tags.v2, c.target)
		testing.expect_value(t, len(dropped), 1)
		testing.expect_value(t, dropped[0], odid3.Dropped_Frame{"PRIV", .No_Equivalent})
	}
}

@(test)
rebuilt_frames_keep_their_group :: proc(t: ^testing.T) {
	v23 := concat(
		frame(3, "TYER", concat({0x2A}, text("\x002019")), 0, 0x20),
		frame(3, "TDAT", concat({0x2B}, text("\x000305")), 0, 0x20),
		frame(3, "TORY", concat({0x2C}, text("\x001999")), 0, 0x20),
		frame(3, "IPLS", concat({0x2D}, text("\x00producer\x00Ada\x00")), 0, 0x20),
		frame(3, "TIT2", text("\x00Title")),
	)
	tags := read(t, tag_file(3, 0, v23))
	defer odid3.destroy(&tags)
	dropped := convert(t, &tags.v2, .V2_4)
	testing.expect_value(t, len(dropped), 1)
	testing.expect_value(t, dropped[0], odid3.Dropped_Frame{"TDAT", .Partly_Converted})
	testing.expect_value(t, len(tags.v2.frames), 4)
	for f in tags.v2.frames {
		group: u8
		switch f.id {
		case "TDRC":
			group = 0x2A
		case "TDOR":
			group = 0x2C
		case "TIPL":
			group = 0x2D
		}
		testing.expectf(t, (.Grouping in f.format) == (group != 0), "%s: %v", f.id, f.format)
		testing.expect_value(t, f.group, group)
	}

	date := read(
		t,
		tag_file(
			4,
			0,
			frame(4, "TDRC", concat({0x2A}, text("\x032019-05-03")), 0, 0x40),
			frame(4, "TIT2", text("\x03Title")),
		),
	)
	defer odid3.destroy(&date)
	dropped = convert(t, &date.v2, .V2_2)
	testing.expect_value(t, len(dropped), 2)
	testing.expect_value(t, dropped[0], odid3.Dropped_Frame{"TYER", .Grouped})
	testing.expect_value(t, dropped[1], odid3.Dropped_Frame{"TDAT", .Grouped})
	testing.expect_value(t, len(date.v2.frames), 1)
}

@(test)
rebuilt_frames_stay_compressed :: proc(t: ^testing.T) {
	tags := read(t, tag_file(4, 0, frame(4, "TIT2", text("\x03Title"))))
	defer odid3.destroy(&tags)
	tags.v2.frames[0].format += {.Compression}
	testing.expect_value(t, len(convert(t, &tags.v2, .V2_3)), 0)
	title := tags.v2.frames[0]
	testing.expect_value(t, string(title.data), "\x00Title")
	testing.expect_value(t, title.format, odid3.Frame_Format{.Compression})
}
