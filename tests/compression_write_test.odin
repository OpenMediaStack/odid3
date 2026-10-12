package odid3_tests

import "core:bytes"
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
