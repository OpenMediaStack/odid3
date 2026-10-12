package odid3

import "core:os"
import "core:testing"

@(test)
a_file_changed_during_a_write_is_noticed :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("", "odid3-*", context.allocator)
	testing.expect_value(t, dir_err, nil)
	defer {
		os.remove_all(dir)
		delete(dir)
	}
	path, _ := os.join_path({dir, "song.mp3"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(path, []u8{1, 2, 3}), nil)

	original, open_err := os.open(path)
	testing.expect_value(t, open_err, nil)
	defer os.close(original)
	before, _ := os.fstat(original, context.allocator)
	os.file_info_delete(before, context.allocator)
	testing.expect_value(t, check_unchanged(original, path, before, context.allocator), nil)

	// Another program appends to it.
	appender, _ := os.open(path, {.Write, .Append})
	_, _ = os.write(appender, []u8{4})
	os.close(appender)
	testing.expect_value(
		t,
		check_unchanged(original, path, before, context.allocator),
		Error(.File_Changed),
	)

	// Another program replaces it.
	other, _ := os.join_path({dir, "other.mp3"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(other, []u8{1, 2, 3, 4}), nil)
	now, _ := os.fstat(original, context.allocator)
	os.file_info_delete(now, context.allocator)
	testing.expect_value(t, os.rename(other, path), nil)
	testing.expect_value(
		t,
		check_unchanged(original, path, now, context.allocator),
		Error(.File_Changed),
	)
}
