package odid3_tests

import "core:bytes"
import "core:math/rand"
import "core:os"
import "core:testing"

import odid3 "../"

@(test)
writing_over_every_fixture :: proc(t: ^testing.T) {
	dir := make_temp_dir(t)
	for name in fixture_names(t) {
		original := fixture(t, name)
		path := copy_fixture(t, dir, name)
		tags, err := odid3.read_file(path, {}, context.allocator)
		defer odid3.destroy(&tags)
		testing.expectf(t, err == nil, "%s: %v", name, err)

		write_err := odid3.write_file(path, &tags, {})
		if write_err != nil {
			testing.expectf(
				t,
				write_err == odid3.Error(odid3.Format_Error.Damaged_Tag),
				"%s: %v",
				name,
				write_err,
			)
			testing.expectf(t, bytes.equal(read_bytes_of(t, path), original), "%s changed", name)
			write_err = odid3.write_file(path, &tags, {replace_damaged = true})
			testing.expectf(t, write_err == nil, "%s, damage replaced: %v", name, write_err)
		}

		written := read_bytes_of(t, path)
		again := read(t, written)
		defer odid3.destroy(&again)
		// Frames kept as stored (a compression bomb) still have their problem.
		kept := tags.warnings & {.Frame_Problems}
		testing.expectf(t, again.warnings <= kept, "%s written: %v", name, again.warnings)
		parts := [?][2]odid3.Range {
			{tags.layout.audio, again.layout.audio},
			{tags.layout.ape, again.layout.ape},
			{tags.layout.lyrics3, again.layout.lyrics3},
		}
		for part in parts {
			testing.expectf(
				t,
				bytes.equal(slice_of(written, part[1]), slice_of(original, part[0])),
				"%s: kept bytes changed",
				name,
			)
		}
		testing.expect_value(t, len(again.v2.frames), len(tags.v2.frames))
	}
}

@(test)
writing_damaged_files :: proc(t: ^testing.T) {
	dir := make_temp_dir(t)
	path := join(dir, "damaged.mp3")
	for name in fixture_names(t) {
		original := fixture(t, name)
		data := concat(original)
		for _ in 0 ..< 50 {
			copy(data, original)
			n := len(data)
			if rand.int_max(2) == 0 {
				n = rand.int_max(n + 1)
			} else {
				for _ in 0 ..< 1 + rand.int_max(8) {
					data[rand.int_max(min(n, 2048))] = u8(rand.uint32())
				}
			}
			damaged := data[:n]
			tags := read(t, damaged)
			defer odid3.destroy(&tags)
			put_file(t, path, damaged)
			if err := odid3.write_file(path, &tags, {}); err != nil {
				expect_untouched(t, dir, path, damaged, name)
			}

			out, err := odid3.write_bytes(
				damaged,
				&tags,
				{replace_damaged = true},
				context.allocator,
			)
			defer delete(out)
			put_file(t, path, damaged)
			file_err := odid3.write_file(path, &tags, {replace_damaged = true})
			testing.expectf(
				t,
				file_err == err,
				"%s: write_file %v, write_bytes %v",
				name,
				file_err,
				err,
			)
			if err != nil {
				expect_untouched(t, dir, path, damaged, name)
				continue
			}
			testing.expectf(t, bytes.equal(read_bytes_of(t, path), out), "%s: files differ", name)
			again := read(t, out)
			defer odid3.destroy(&again)
			testing.expectf(
				t,
				bytes.equal(
					slice_of(out, again.layout.audio),
					slice_of(damaged, tags.layout.audio),
				),
				"%s: the audio changed",
				name,
			)
		}
	}
}

put_file :: proc(t: ^testing.T, path: string, data: []u8) {
	if os.write_entire_file(path, data) != nil {
		testing.fail_now(t, "cannot write the file")
	}
}

// A write that failed left the file as it was, and no temporary file next to it.
expect_untouched :: proc(t: ^testing.T, dir, path: string, want: []u8, name: string) {
	testing.expectf(t, bytes.equal(read_bytes_of(t, path), want), "%s: changed on failure", name)
	entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	testing.expectf(t, len(entries) == 1, "%s: %d files left behind", name, len(entries))
}
