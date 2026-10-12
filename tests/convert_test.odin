package odid3_tests

import "core:mem"
import "core:testing"

import odid3 "../"

convert :: proc(
	t: ^testing.T,
	tag: ^odid3.Tag,
	to: odid3.V2_Version,
	loc := #caller_location,
) -> odid3.Dropped_Frames {
	dropped, err := odid3.convert(tag, to, context.temp_allocator)
	testing.expectf(t, err == nil, "convert: %v", err, loc = loc)
	return dropped
}

all_fields :: proc(tag: ^odid3.Tag) -> (values: [odid3.Field]string) {
	for f in odid3.Field {
		values[f] = tag_field(tag, f)
	}
	return
}

@(test)
fields_survive_conversions :: proc(t: ^testing.T) {
	for name in fixture_names(t) {
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		from := tags.v2.version
		if from != .V2_3 && from != .V2_4 || tags.warnings & odid3.DAMAGE_WARNINGS != {} {
			continue
		}
		before := all_fields(&tags.v2)
		other: odid3.V2_Version = .V2_4 if from == .V2_3 else .V2_3
		dropped := convert(t, &tags.v2, other)
		testing.expectf(t, len(dropped) == 0, "%s: dropped %v", name, dropped)
		rendered, err := odid3.render(&tags.v2, {}, context.temp_allocator)
		testing.expectf(t, err == nil, "%s: %v", name, err)
		again := read(t, rendered)
		defer odid3.destroy(&again)
		testing.expect_value(t, again.v2.version, other)
		after := all_fields(&again.v2)
		for f in odid3.Field {
			if before[f] != after[f] && !(other == .V2_3 && f == .Genre) {
				testing.expectf(t, false, "%s %v: %q became %q", name, f, before[f], after[f])
			}
		}
		convert(t, &again.v2, from)
		testing.expect_value(t, all_fields(&again.v2), before)
	}
}

@(test)
dates_and_people :: proc(t: ^testing.T) {
	frames := concat(
		frame(4, "TDRC", text("\x032019-05-03T10:20")),
		frame(4, "TDOR", text("\x031987-01-01")),
		frame(4, "TIPL", text("\x03producer\x00Ada\x00")),
		frame(4, "TMCL", text("\x03piano\x00Bea\x00")),
	)
	tags := read(t, tag_file(4, 0, frames))
	defer odid3.destroy(&tags)
	convert(t, &tags.v2, .V2_3)
	for c in ([]struct {
			id, data: string,
		}{{"TYER", "\x002019"}, {"TDAT", "\x000305"}, {"TIME", "\x001020"}, {"TORY", "\x001987"}, {"IPLS", "\x00producer\x00Ada\x00piano\x00Bea\x00"}}) {
		index, ok := odid3.find_frame(&tags.v2, c.id)
		testing.expectf(t, ok && string(tags.v2.frames[index].data) == c.data, "%s: %v", c.id, ok)
	}
	convert(t, &tags.v2, .V2_4)
	testing.expect_value(t, tag_field(&tags.v2, .Date), "2019-05-03T10:20")
	index, ok := odid3.find_frame(&tags.v2, "TIPL")
	testing.expect(
		t,
		ok && string(tags.v2.frames[index].data[1:]) == "producer\x00Ada\x00piano\x00Bea\x00",
	)
}

@(test)
text_is_reencoded_for_v23 :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v24_unicode.mp3"))
	defer odid3.destroy(&tags)
	convert(t, &tags.v2, .V2_3)
	for &f in tags.v2.frames {
		testing.expectf(t, f.data[0] <= 1, "%s still in encoding %d", f.id, f.data[0])
	}
	testing.expect_value(t, tags.v2.frames[0].data[0], 0)
	testing.expect_value(t, tags.v2.frames[1].data[0], 1)
	testing.expect_value(t, tag_field(&tags.v2, .Artist), "坂本龍一")

	several := read(t, tag_file(4, 0, frame(4, "TPE1", text("\x03Ada\x00Bea"))))
	defer odid3.destroy(&several)
	convert(t, &several.v2, .V2_3)
	testing.expect_value(t, tag_field(&several.v2, .Artist), "Ada/Bea")
}

@(test)
frames_a_conversion_drops :: proc(t: ^testing.T) {
	v24 := read(
		t,
		tag_file(
			4,
			0,
			frame(4, "RVA2", text("track\x00\x01")),
			frame(4, "XYZW", text("data"), 0x40),
			frame(4, "ABCD", text("kept")),
			frame(4, "PRIV", concat({0x80}, text("secret")), 0, 0x0C),
		),
	)
	defer odid3.destroy(&v24)
	dropped := convert(t, &v24.v2, .V2_3)
	want := []odid3.Dropped_Frame {
		{"PRIV", .Encrypted},
		{"XYZW", .Discard_On_Tag_Alter},
		{"RVA2", .No_Equivalent},
	}
	testing.expect_value(t, len(dropped), len(want))
	for d, i in dropped {
		testing.expectf(
			t,
			d.id == want[i].id && d.reason == want[i].reason,
			"%v, want %v",
			d,
			want[i],
		)
	}
	testing.expect_value(t, len(v24.v2.frames), 1)
	testing.expect_value(t, v24.v2.frames[0].id, "ABCD")

	v23 := read(
		t,
		tag_file(
			3,
			0,
			frame(3, "RVAD", {0x03, 0x10, 0, 0, 0, 0}),
			frame(3, "TIT2", text("\x00Title")),
		),
	)
	defer odid3.destroy(&v23)
	dropped = convert(t, &v23.v2, .V2_4)
	testing.expect_value(t, len(dropped), 1)
	testing.expect_value(t, dropped[0].id, "RVAD")
}

@(test)
converting_from_and_to_none :: proc(t: ^testing.T) {
	tag: odid3.Tag
	defer odid3.destroy(&tag)
	convert(t, &tag, .V2_4)
	testing.expect_value(t, tag.version, odid3.V2_Version.V2_4)
	testing.expect_value(t, odid3.set(&tag, .Title, "From nothing"), nil)
	rendered := odid3.render(&tag, {}, context.temp_allocator) or_else nil
	tags := read(t, rendered)
	defer odid3.destroy(&tags)
	testing.expect_value(t, field(&tags, .Title), "From nothing")

	dropped := convert(t, &tags.v2, .None)
	testing.expect_value(t, len(dropped), 1)
	testing.expect_value(t, dropped[0].reason, odid3.Drop_Reason.Tag_Removed)
	testing.expect_value(t, tags.v2.version, odid3.V2_Version.None)
	testing.expect_value(t, len(tags.v2.frames), 0)
}

@(test)
conversion_allocation_failures_leak_nothing :: proc(t: ^testing.T) {
	data := fixture(t, "v24_unicode.mp3")
	succeeded := false
	for budget in 0 ..< 200 {
		failing := Failing{context.allocator, budget}
		allocator := failing_allocator(&failing)
		tags, err := odid3.read_bytes(data, {}, allocator)
		if err != nil {
			continue
		}
		dropped, convert_err := odid3.convert(&tags.v2, .V2_3, allocator)
		odid3.destroy(&dropped, allocator)
		odid3.destroy(&tags)
		if convert_err == nil {
			succeeded = true
			break
		}
		testing.expect_value(t, convert_err, odid3.Error(mem.Allocator_Error.Out_Of_Memory))
	}
	testing.expect(t, succeeded)
}

@(test)
a_clone_previews_a_conversion :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v24_full.mp3"))
	defer odid3.destroy(&tags)
	before := all_fields(&tags.v2)

	preview, err := odid3.clone(&tags.v2)
	testing.expect_value(t, err, nil)
	defer odid3.destroy(&preview)
	convert(t, &preview, .V2_3)
	testing.expect_value(t, preview.version, odid3.V2_Version.V2_3)
	testing.expect_value(t, tags.v2.version, odid3.V2_Version.V2_4)
	testing.expect_value(t, all_fields(&tags.v2), before)
	testing.expect_value(t, tag_field(&preview, .Title), before[.Title])

	enhanced := read(t, fixture(t, "v1_enhanced.mp3"))
	defer odid3.destroy(&enhanced)
	copy_of, clone_err := odid3.clone(&enhanced)
	testing.expect_value(t, clone_err, nil)
	defer odid3.destroy(&copy_of)
	testing.expect_value(t, copy_of.v1.title, enhanced.v1.title)
	testing.expect(t, raw_data(copy_of.v1.title) != raw_data(enhanced.v1.title))
	e, ok := copy_of.v1.enhanced.?
	testing.expect(t, ok)
	testing.expect_value(t, e.genre, enhanced.v1.enhanced.?.genre)
	testing.expect_value(t, copy_of.layout, enhanced.layout)
}

@(test)
clone_allocation_failures_leak_nothing :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v1_enhanced.mp3"))
	defer odid3.destroy(&tags)
	full := read(t, fixture(t, "v24_full.mp3"))
	defer odid3.destroy(&full)
	tags.v2, full.v2 = full.v2, tags.v2
	succeeded := false
	for budget in 0 ..< 64 {
		failing := Failing{context.allocator, budget}
		allocator := failing_allocator(&failing)
		duplicate, err := odid3.clone(&tags, allocator)
		if err == nil {
			odid3.destroy(&duplicate)
			succeeded = true
			break
		}
		testing.expect_value(t, err, odid3.Error(mem.Allocator_Error.Out_Of_Memory))
	}
	testing.expect(t, succeeded)
}
