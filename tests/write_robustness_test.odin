package odid3_tests

import "core:bytes"
import "core:math/rand"
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
		testing.expectf(
			t,
			bytes.equal(
				slice_of(written, again.layout.audio),
				slice_of(original, tags.layout.audio),
			),
			"%s: the audio changed",
			name,
		)
		testing.expect_value(t, len(again.v2.frames), len(tags.v2.frames))
	}
}

@(test)
writing_damaged_bytes :: proc(t: ^testing.T) {
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
			out, err := odid3.write_bytes(
				damaged,
				&tags,
				{replace_damaged = true},
				context.temp_allocator,
			)
			if err != nil {
				continue
			}
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
