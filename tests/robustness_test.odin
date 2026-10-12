package odid3_tests

import "core:math/rand"
import "core:mem"
import "core:slice"
import "core:testing"
import "core:thread"

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

// What a read gives, in a form two reads can be compared with.
Read_Summary :: struct {
	layout:   odid3.Layout,
	warnings: odid3.Warnings,
	frames:   int,
	data:     int,
	title:    string,
}

summarise :: proc(tags: ^odid3.Tags, allocator := context.allocator) -> (s: Read_Summary) {
	s.layout = tags.layout
	s.warnings = tags.warnings
	s.frames = len(tags.v2.frames)
	for f in tags.v2.frames {
		s.data += len(f.data)
	}
	s.title = odid3.get(tags, .Title, allocator)
	return
}

Thread_Work :: struct {
	names:      []string,
	expected:   []Read_Summary,
	mismatches: int,
}

@(test)
concurrent_reads_give_the_same_tags :: proc(t: ^testing.T) {
	names := fixture_names(t)
	expected := make([]Read_Summary, len(names), context.temp_allocator)
	for name, i in names {
		tags, err := odid3.read_file(fixture_path(name))
		testing.expect_value(t, err, nil)
		expected[i] = summarise(&tags, context.temp_allocator)
		odid3.destroy(&tags)
	}
	THREADS :: 8
	work: [THREADS]Thread_Work
	threads: [THREADS]^thread.Thread
	for i in 0 ..< THREADS {
		work[i] = {names, expected, 0}
		threads[i] = thread.create_and_start_with_poly_data(&work[i], proc(w: ^Thread_Work) {
				for _ in 0 ..< 3 {
					for name, i in w.names {
						tags, err := odid3.read_file(fixture_path(name))
						got := summarise(&tags)
						if err != nil || got != w.expected[i] {
							w.mismatches += 1
						}
						delete(got.title)
						odid3.destroy(&tags)
					}
					free_all(context.temp_allocator)
				}
			}, context)
	}
	thread.join_multiple(..threads[:])
	for i in 0 ..< THREADS {
		thread.destroy(threads[i])
		testing.expectf(
			t,
			work[i].mismatches == 0,
			"thread %d: %d reads differ",
			i,
			work[i].mismatches,
		)
	}
}

// Every accessor and decoder on every frame of a damaged file: nothing may panic or leak.
read_everything :: proc(data: []u8) {
	tags, err := odid3.read_bytes(data)
	if err != nil {
		return
	}
	defer odid3.destroy(&tags)
	for &f in tags.v2.frames {
		content, _ := odid3.decode_frame(&f, tags.v2.version)
		odid3.destroy(&content)
	}
	for field in odid3.Field {
		delete(odid3.get(&tags, field))
	}
	all := odid3.pictures(&tags.v2)
	odid3.destroy(&all)
	notes := odid3.comments(&tags.v2)
	odid3.destroy(&notes)
	names := odid3.genres(&tags.v2)
	odid3.destroy(&names)
	cover, _, _ := odid3.front_cover(&tags.v2)
	odid3.destroy(&cover)
	mood, _, _ := odid3.user_text(&tags.v2, "mood")
	delete(mood)
	_, _ = odid3.year(&tags)
	_, _ = odid3.track(&tags)
	_, _ = odid3.disc(&tags)
}

@(test)
damaged_files_decode_without_panic :: proc(t: ^testing.T) {
	for name in fixture_names(t) {
		original := fixture(t, name)
		data := concat(original)
		for n := 0; n <= len(original); n += max(1, len(original) / 200) {
			read_everything(original[:n])
		}
		for _ in 0 ..< 200 {
			copy(data, original)
			for _ in 0 ..< 1 + rand.int_max(8) {
				data[rand.int_max(len(data))] = u8(rand.uint32())
			}
			read_everything(data)
		}
	}
}

@(test)
allocations_are_bounded_by_the_input :: proc(t: ^testing.T) {
	for name in fixture_names(t) {
		if name == "v24_compression_bomb.mp3" {
			continue
		}
		original := fixture(t, name)
		data := concat(original)
		for attempt in 0 ..< 50 {
			copy(data, original)
			if attempt > 0 {
				for _ in 0 ..< 1 + rand.int_max(8) {
					data[rand.int_max(len(data))] = u8(rand.uint32())
				}
			}
			track: mem.Tracking_Allocator
			mem.tracking_allocator_init(&track, context.allocator)
			tags, _ := odid3.read_bytes(data, {}, mem.tracking_allocator(&track))
			odid3.destroy(&tags)
			bound := 32 * len(data) + 2 * mem.Megabyte
			testing.expectf(
				t,
				track.peak_memory_allocated <= i64(bound),
				"%s: %v bytes for %v",
				name,
				track.peak_memory_allocated,
				len(data),
			)
			mem.tracking_allocator_destroy(&track)
		}
	}
}

@(test)
too_many_frames :: proc(t: ^testing.T) {
	empty := frame(3, "TIT2", nil)
	parts := make([dynamic][]u8, context.temp_allocator)
	for _ in 0 ..< 70_000 {
		append(&parts, empty)
	}
	tags := read(t, tag_file(3, 0, ..parts[:]))
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.warnings, odid3.Warnings{.Too_Many_Frames})
	testing.expect_value(t, len(tags.v2.frames), 1 << 16)
}
