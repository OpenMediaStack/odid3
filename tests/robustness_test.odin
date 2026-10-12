package odid3_tests

import "core:math/rand"
import "core:slice"
import "core:testing"

import odid3 "../"

expect_layout_inside :: proc(t: ^testing.T, name: string, data: []u8, layout: odid3.Layout) {
	ranges := [?]odid3.Range {
		layout.v2,
		layout.v2_stacked,
		layout.audio,
		layout.v2_appended,
		layout.ape,
		layout.lyrics3,
		layout.v1_enhanced,
		layout.v1,
	}
	// APE, Lyrics3 and an appended tag come in any order between the audio and the Enhanced TAG.
	slice.sort_by(ranges[3:6], proc(a, b: odid3.Range) -> bool {
		return a.offset < b.offset
	})
	end: i64 = 0
	for r in ranges {
		if r.size == 0 {
			continue
		}
		ok := r.offset >= end && r.size > 0 && r.offset + r.size <= i64(len(data))
		testing.expectf(t, ok, "%s: range %v overlaps or leaves the file in %v", name, r, layout)
		end = r.offset + r.size
	}
}

@(test)
every_fixture_cut_at_every_length :: proc(t: ^testing.T) {
	for name in fixture_names(t) {
		data := fixture(t, name)
		for n in 0 ..= len(data) {
			tags := read(t, data[:n])
			expect_layout_inside(t, name, data[:n], tags.layout)
			odid3.destroy(&tags)
		}
	}
}

@(test)
every_fixture_with_mutated_bytes :: proc(t: ^testing.T) {
	for name in fixture_names(t) {
		original := fixture(t, name)
		data := concat(original)
		for _ in 0 ..< 500 {
			copy(data, original)
			for _ in 0 ..< 1 + rand.int_max(8) {
				data[rand.int_max(len(data))] = u8(rand.uint32())
			}
			tags := read(t, data)
			expect_layout_inside(t, name, data, tags.layout)
			odid3.destroy(&tags)
		}
	}
}
