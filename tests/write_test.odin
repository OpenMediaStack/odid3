package odid3_tests

import "core:bytes"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

import odid3 "../"

write :: proc(
	t: ^testing.T,
	file: []u8,
	tags: ^odid3.Tags,
	options := odid3.Write_Options{},
	loc := #caller_location,
) -> []u8 {
	out, err := odid3.write_bytes(file, tags, options, context.temp_allocator)
	testing.expectf(t, err == nil, "write_bytes: %v", err, loc = loc)
	return out
}

@(test)
written_files_keep_their_audio :: proc(t: ^testing.T) {
	for name in fixture_names(t) {
		file := fixture(t, name)
		tags := read(t, file)
		defer odid3.destroy(&tags)
		if tags.warnings & odid3.DAMAGE_WARNINGS != {} {
			continue
		}
		out := write(t, file, &tags)
		again := read(t, out)
		defer odid3.destroy(&again)
		testing.expectf(
			t,
			bytes.equal(slice_of(out, again.layout.audio), slice_of(file, tags.layout.audio)),
			"%s: audio",
			name,
		)
		testing.expectf(
			t,
			bytes.equal(slice_of(out, again.layout.ape), slice_of(file, tags.layout.ape)),
			"%s: APE",
			name,
		)
		testing.expectf(
			t,
			bytes.equal(slice_of(out, again.layout.lyrics3), slice_of(file, tags.layout.lyrics3)),
			"%s: Lyrics3",
			name,
		)
		testing.expectf(
			t,
			again.v1 == tags.v1 ||
			(again.v1.title == tags.v1.title && again.v1.version == tags.v1.version),
			"%s: ID3v1",
			name,
		)
		testing.expectf(t, len(again.v2.frames) == len(tags.v2.frames), "%s: frames", name)
	}
}

@(test)
second_tags_are_replaced :: proc(t: ^testing.T) {
	file := fixture(t, "v24_appended.mp3")
	tags := read(t, file)
	defer odid3.destroy(&tags)
	out := write(t, file, &tags)
	again := read(t, out)
	defer odid3.destroy(&again)
	testing.expect_value(t, again.layout.v2.offset, 0)
	expect_range(t, "appended", again.layout.v2_appended, 0, 0)
	testing.expect_value(t, odid3.get(&again, .Title, context.temp_allocator), "Appended title")
	testing.expect(t, bytes.equal(slice_of(out, again.layout.audio), fixture(t, "no_tag.mp3")))

	stacked := concat(v2_header(3, 0, 0), tag_file(3, 0, frame(3, "TIT2", text("\x00Old"))))
	tags2 := read(t, stacked)
	defer odid3.destroy(&tags2)
	_, err := odid3.write_bytes(stacked, &tags2, {}, context.temp_allocator)
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Damaged_Tag))
	replaced := write(t, stacked, &tags2, {replace_damaged = true, padding = 0})
	testing.expect_value(t, len(replaced), 10 + 4)
}

@(test)
removing_every_tag :: proc(t: ^testing.T) {
	file := fixture(t, "ape_v1.mp3")
	tags := read(t, file)
	defer odid3.destroy(&tags)
	odid3.sync_v1(&tags, .Never)
	out := write(t, file, &tags)
	testing.expect(t, bytes.equal(out, file[:len(file) - 128]))
}

@(test)
damaged_tags_are_only_rewritten_on_request :: proc(t: ^testing.T) {
	file := fixture(t, "truncated_tag.mp3")
	tags := read(t, file)
	defer odid3.destroy(&tags)
	_, err := odid3.write_bytes(file, &tags, {}, context.temp_allocator)
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Damaged_Tag))
	out := write(t, file, &tags, {replace_damaged = true})
	again := read(t, out)
	defer odid3.destroy(&again)
	testing.expect_value(t, again.warnings, odid3.Warnings{})
	testing.expect_value(t, odid3.get(&again, .Title, context.temp_allocator), "With a cover")
}

@(test)
write_file_replaces_the_file :: proc(t: ^testing.T) {
	dir := make_temp_dir(t)
	path := copy_fixture(t, dir, "v23_full.mp3")
	when ODIN_OS != .Windows {
		testing.expect_value(t, os.chmod(path, {.Read_User, .Write_User, .Read_Group}), nil)
	}
	before := read_bytes_of(t, path)
	tags, err := odid3.read_file(path)
	defer odid3.destroy(&tags)
	testing.expect_value(t, err, nil)
	odid3.sync_v1(&tags, .Always)
	testing.expect_value(t, odid3.write_file(path, &tags, {padding = 0}), nil)

	after := read_bytes_of(t, path)
	again := read(t, after)
	defer odid3.destroy(&again)
	testing.expect_value(t, again.v1.version, odid3.V1_Version.V1_1)
	testing.expect_value(t, again.v2.padding, 0)
	testing.expect(
		t,
		bytes.equal(slice_of(after, again.layout.audio), slice_of(before, tags.layout.audio)),
	)

	entries, list_err := os.read_all_directory_by_path(dir, context.temp_allocator)
	testing.expect_value(t, list_err, nil)
	testing.expectf(t, len(entries) == 1, "files left behind: %v", len(entries))
	when ODIN_OS != .Windows {
		info, stat_err := os.stat(path, context.temp_allocator)
		testing.expect_value(t, stat_err, nil)
		testing.expect_value(
			t,
			info.mode & os.Permissions_Read_Write_All,
			os.Permissions{.Read_User, .Write_User, .Read_Group},
		)
	}
}

@(test)
failed_writes_leave_the_file_alone :: proc(t: ^testing.T) {
	dir := make_temp_dir(t)
	path := copy_fixture(t, dir, "v23_full.mp3")
	before := read_bytes_of(t, path)
	tags, _ := odid3.read_file(path)
	defer odid3.destroy(&tags)

	// UTF-8 in a new ID3v2.3 frame cannot be rendered.
	title := &tags.v2.frames[0]
	offset := title.offset
	title.data[0], title.offset = 3, -1
	testing.expect_value(
		t,
		odid3.write_file(path, &tags),
		odid3.Error(odid3.Format_Error.Encoding_Not_In_Version),
	)
	title.data[0], title.offset = 0, offset

	testing.expect_value(
		t,
		odid3.write_file(dir, &tags),
		odid3.Error(os.Error(os.General_Error.Invalid_File)),
	)
	testing.expect(t, odid3.write_file(join(dir, "missing.mp3"), &tags) != nil)

	when ODIN_OS != .Windows {
		testing.expect_value(t, os.chmod(dir, {.Read_User, .Execute_User}), nil)
		testing.expect(t, odid3.write_file(path, &tags) != nil)
		testing.expect_value(t, os.chmod(dir, {.Read_User, .Write_User, .Execute_User}), nil)
	}

	testing.expect(t, bytes.equal(read_bytes_of(t, path), before))
	entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	testing.expectf(t, len(entries) == 1, "files left behind: %v", len(entries))
}

@(test)
write_file_never_loads_the_audio :: proc(t: ^testing.T) {
	AUDIO_SIZE :: 8 * mem.Megabyte
	path := join(make_temp_dir(t), "large.mp3")
	f, err := os.open(path, {.Write, .Create, .Trunc})
	if err != nil {
		testing.fail_now(t, "cannot create the file")
	}
	os.write_at(f, fixture(t, "v23_full.mp3"), 0)
	os.write_at(f, {0xFF, 0xFB}, AUDIO_SIZE - 2)
	os.close(f)

	tags, read_err := odid3.read_file(path)
	defer odid3.destroy(&tags)
	testing.expect_value(t, read_err, nil)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	testing.expect_value(
		t,
		odid3.write_file(path, &tags, {padding = 0}, mem.tracking_allocator(&track)),
		nil,
	)
	testing.expectf(
		t,
		track.peak_memory_allocated < 2 * mem.Megabyte,
		"writing allocated %v bytes",
		track.peak_memory_allocated,
	)

	info, stat_err := os.stat(path, context.temp_allocator)
	testing.expect_value(t, stat_err, nil)
	testing.expect_value(t, info.size, AUDIO_SIZE - i64(tags.v2.padding))
}

@(test)
damage_in_the_file_as_it_is_now :: proc(t: ^testing.T) {
	clean := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&clean)
	truncated := fixture(t, "truncated_tag.mp3")
	_, err := odid3.write_bytes(truncated, &clean, {}, context.temp_allocator)
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Damaged_Tag))
}

@(test)
write_file_matches_write_bytes :: proc(t: ^testing.T) {
	dir := make_temp_dir(t)
	for name in fixture_names(t) {
		file := fixture(t, name)
		tags := read(t, file)
		defer odid3.destroy(&tags)
		in_memory, bytes_err := odid3.write_bytes(
			file,
			&tags,
			{replace_damaged = true},
			context.temp_allocator,
		)
		path := copy_fixture(t, dir, name)
		file_err := odid3.write_file(path, &tags, {replace_damaged = true})
		same :=
			bytes_err == nil && file_err == nil && bytes.equal(read_bytes_of(t, path), in_memory)
		testing.expectf(t, same, "%s: %v, %v", name, bytes_err, file_err)
	}
}

@(test)
write_file_allocation_failures_leave_nothing_behind :: proc(t: ^testing.T) {
	dir := make_temp_dir(t)
	path := copy_fixture(t, dir, "v23_full.mp3")
	before := read_bytes_of(t, path)
	tags := read(t, before)
	defer odid3.destroy(&tags)
	succeeded := false
	for budget in 0 ..< 64 {
		failing := Failing{context.allocator, budget}
		err := odid3.write_file(path, &tags, {}, failing_allocator(&failing))
		entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		testing.expectf(t, len(entries) == 1, "budget %d: %d files", budget, len(entries))
		if err == nil {
			succeeded = true
			break
		}
		testing.expect(t, bytes.equal(read_bytes_of(t, path), before))
	}
	testing.expect(t, succeeded)
}

@(test)
long_file_names :: proc(t: ^testing.T) {
	dir := make_temp_dir(t)
	name := strings.concatenate(
		{strings.repeat("é", 118, context.temp_allocator), ".mp3"},
		context.temp_allocator,
	)
	path := join(dir, name)
	if os.write_entire_file(path, fixture(t, "v23_full.mp3")) != nil {
		testing.fail_now(t, "cannot create a file with a long name")
	}
	tags := read(t, read_bytes_of(t, path))
	defer odid3.destroy(&tags)
	testing.expect_value(t, odid3.write_file(path, &tags), nil)
}

when ODIN_OS != .Windows {
	@(test)
	symbolic_links_stay :: proc(t: ^testing.T) {
		dir := make_temp_dir(t)
		os.make_directory(join(dir, "music"))
		os.make_directory(join(dir, "links"))
		target := join(dir, "music/song.mp3")
		if os.write_entire_file(target, fixture(t, "v23_full.mp3")) != nil {
			testing.fail_now(t, "cannot write the target")
		}
		link := join(dir, "links/song.mp3")
		testing.expect_value(t, os.symlink("../music/song.mp3", link), nil)

		tags := read(t, read_bytes_of(t, link))
		defer odid3.destroy(&tags)
		tags.v2.version = .None
		testing.expect_value(t, odid3.write_file(link, &tags), nil)
		info, _ := os.lstat(link, context.temp_allocator)
		testing.expect_value(t, info.type, os.File_Type.Symlink)
		written := read(t, read_bytes_of(t, target))
		defer odid3.destroy(&written)
		testing.expect_value(t, written.v2.version, odid3.V2_Version.None)
	}

	@(test)
	read_only_files_are_refused :: proc(t: ^testing.T) {
		dir := make_temp_dir(t)
		path := copy_fixture(t, dir, "v23_full.mp3")
		before := read_bytes_of(t, path)
		testing.expect_value(t, os.chmod(path, {.Read_User, .Read_Group, .Read_Other}), nil)
		tags := read(t, before)
		defer odid3.destroy(&tags)
		testing.expect(t, odid3.write_file(path, &tags) != nil)
		testing.expect(t, bytes.equal(read_bytes_of(t, path), before))
		entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		testing.expect_value(t, len(entries), 1)
	}
}
