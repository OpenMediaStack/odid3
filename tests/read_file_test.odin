package odid3_tests

import "core:mem"
import "core:os"
import "core:testing"

import odid3 "../"

@(test)
read_file_finds_what_read_bytes_finds :: proc(t: ^testing.T) {
	names := fixture_names(t)
	testing.expect(t, len(names) > 20)
	for name in names {
		from_file, err := odid3.read_file(fixture_path(name))
		testing.expectf(t, err == nil, "%s: %v", name, err)
		from_bytes := read(t, fixture(t, name))
		testing.expectf(t, from_file.layout == from_bytes.layout, "%s: layouts differ", name)
		testing.expectf(t, from_file.warnings == from_bytes.warnings, "%s: warnings differ", name)
		testing.expectf(t, from_file.v2.version == from_bytes.v2.version, "%s: v2 differs", name)
		testing.expectf(t, from_file.v2.flags == from_bytes.v2.flags, "%s: flags differ", name)
		testing.expectf(t, from_file.v1 == from_bytes.v1, "%s: v1 differs", name)
		odid3.destroy(&from_file)
		odid3.destroy(&from_bytes)
	}
}

@(test)
read_file_never_loads_the_audio :: proc(t: ^testing.T) {
	AUDIO_SIZE :: 64 * mem.Megabyte
	head := fixture(t, "v23_full.mp3")
	v1 := fixture(t, "v1_1_ascii.mp3")
	v1 = v1[len(v1) - 128:]

	path := join(make_temp_dir(t), "large.mp3")
	f, err := os.open(path, {.Write, .Create, .Trunc})
	testing.expect_value(t, err, nil)
	_, err = os.write_at(f, head, 0)
	testing.expect_value(t, err, nil)
	_, err = os.write_at(f, v1, AUDIO_SIZE)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, os.close(f), nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	tags: odid3.Tags
	read_err: odid3.Error
	{
		context.allocator = allocator
		tags, read_err = odid3.read_file(path, allocator)
	}
	defer odid3.destroy(&tags)
	testing.expect_value(t, read_err, nil)
	testing.expect_value(t, tags.v2.version, odid3.V2_Version.V2_3)
	testing.expect_value(t, tags.v1.version, odid3.V1_Version.V1_1)
	expect_range(t, "v1", tags.layout.v1, AUDIO_SIZE, 128)
	testing.expectf(
		t,
		track.peak_memory_allocated < mem.Megabyte,
		"reading allocated up to %v bytes",
		track.peak_memory_allocated,
	)
}

@(test)
read_file_errors :: proc(t: ^testing.T) {
	_, err := odid3.read_file(fixture_path("missing.mp3"))
	testing.expectf(t, err != nil, "a missing file gives %v", err)

	_, err = odid3.read_file(TESTDATA)
	testing.expectf(t, err != nil, "a directory gives %v", err)
}
