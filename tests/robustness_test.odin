package odid3_tests

import "core:hash"
import "core:math/rand"
import "core:mem"
import "core:os"
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

// A hash of everything a read gives: layout, warnings, every frame with its flags, offset,
// problem and data, and ID3v1. Two reads that differ in any byte give different hashes.
summarise :: proc(tags: ^odid3.Tags) -> u64 {
	mix :: proc(h: u64, value: $T) -> u64 {
		value := value
		return hash.fnv64a(mem.ptr_to_bytes(&value), h)
	}
	mix_bytes :: proc(h: u64, data: []u8) -> u64 {
		return hash.fnv64a(data, mix(h, len(data)))
	}
	h := hash.fnv64a(nil)
	h = mix(h, tags.layout)
	h = mix(h, tags.warnings)
	h = mix(h, tags.v2.version)
	h = mix(h, tags.v2.padding)
	for f in tags.v2.frames {
		h = mix_bytes(h, transmute([]u8)f.id)
		h = mix(h, f.status)
		h = mix(h, f.format)
		h = mix(h, f.group)
		h = mix(h, f.method)
		h = mix(h, f.offset)
		h = mix(h, f.size)
		h = mix(h, f.problem)
		h = mix(h, f.data_length)
		h = mix_bytes(h, f.data)
	}
	v1 := &tags.v1
	h = mix(h, v1.version)
	for text in ([]string{v1.title, v1.artist, v1.album, v1.year, v1.comment}) {
		h = mix_bytes(h, transmute([]u8)text)
	}
	h = mix(h, v1.track)
	h = mix(h, v1.genre)
	return h
}

Thread_Work :: struct {
	paths:      []string,
	expected:   []u64,
	mismatches: int,
	first:      string, // the first path read otherwise
}

@(test)
concurrent_reads_give_the_same_tags :: proc(t: ^testing.T) {
	names := fixture_names(t)
	paths := make([]string, len(names), context.temp_allocator)
	expected := make([]u64, len(names), context.temp_allocator)
	for name, i in names {
		paths[i] = fixture_path(name)
		tags, err := odid3.read_file(paths[i])
		testing.expect_value(t, err, nil)
		expected[i] = summarise(&tags)
		odid3.destroy(&tags)
	}
	THREADS :: 8
	work: [THREADS]Thread_Work
	threads: [THREADS]^thread.Thread
	for i in 0 ..< THREADS {
		work[i] = {paths, expected, 0, ""}
		// The workers share the test's allocator, which tracks leaks across threads; they never
		// touch the temporary allocator.
		threads[i] = thread.create_and_start_with_poly_data(&work[i], proc(w: ^Thread_Work) {
				for _ in 0 ..< 3 {
					for path, i in w.paths {
						tags, err := odid3.read_file(path)
						if err != nil || summarise(&tags) != w.expected[i] {
							w.mismatches += 1
							if w.first == "" {
								w.first = path
							}
						}
						odid3.destroy(&tags)
					}
				}
			}, context)
	}
	thread.join_multiple(..threads[:])
	for i in 0 ..< THREADS {
		thread.destroy(threads[i])
		testing.expectf(
			t,
			work[i].mismatches == 0,
			"thread %d: %d reads differ, first %s",
			i,
			work[i].mismatches,
			work[i].first,
		)
	}
}

// Every accessor and decoder on every frame of a damaged file, frames inside chapters included:
// nothing may panic or leak.
read_everything :: proc(
	data: []u8,
	options := odid3.Read_Options{},
	allocator := context.allocator,
) {
	tags, err := odid3.read_bytes(data, options, allocator)
	if err != nil {
		return
	}
	defer odid3.destroy(&tags)
	decode_all(tags.v2.frames[:], tags.v2.version, allocator)
	for field in odid3.Field {
		delete(odid3.get(&tags, field, allocator), allocator)
	}
	all := odid3.pictures(&tags.v2, allocator)
	odid3.destroy(&all, allocator)
	notes := odid3.comments(&tags.v2, allocator)
	odid3.destroy(&notes, allocator)
	names := odid3.genres(&tags.v2, allocator)
	odid3.destroy(&names, allocator)
	cover, _, _ := odid3.front_cover(&tags.v2, allocator)
	odid3.destroy(&cover, allocator)
	mood, _, _ := odid3.user_text(&tags.v2, "mood", allocator)
	delete(mood, allocator)
	_, _ = odid3.year(&tags)
	_, _ = odid3.track(&tags)
	_, _ = odid3.disc(&tags)
}

decode_all :: proc(frames: []odid3.Frame, version: odid3.V2_Version, allocator: mem.Allocator) {
	for &f in frames {
		content, err := odid3.decode_frame(&f, version, allocator)
		if err == nil {
			#partial switch c in content {
			case odid3.Chapter:
				decode_all(c.frames[:], version, allocator)
			case odid3.Table_Of_Contents:
				decode_all(c.frames[:], version, allocator)
			}
		}
		odid3.destroy(&content, allocator)
	}
}

// Where a fixture's tags are: mutations aimed there find more than in the audio.
tag_bytes :: proc(data: []u8) -> (head, tail: int) {
	tags := read_quietly(data)
	defer odid3.destroy(&tags)
	head = int(tags.layout.v2.offset + tags.layout.v2.size) + 16
	tail = len(data) - int(tags.layout.audio.offset + tags.layout.audio.size) + 16
	return min(head, len(data)), min(tail, len(data))
}

read_quietly :: proc(data: []u8) -> odid3.Tags {
	tags, _ := odid3.read_bytes(data)
	return tags
}

mutate :: proc(data, original: []u8, head, tail: int) {
	copy(data, original)
	for _ in 0 ..< 1 + rand.int_max(8) {
		at: int
		switch rand.int_max(4) {
		case 0:
			at = rand.int_max(len(data))
		case 1:
			at = len(data) - 1 - rand.int_max(max(tail, 1))
		case:
			at = rand.int_max(max(head, 1))
		}
		data[at] = u8(rand.uint32())
	}
}

@(test)
damaged_files_decode_without_panic :: proc(t: ^testing.T) {
	for name in fixture_names(t) {
		original := fixture(t, name)
		head, tail := tag_bytes(original)
		for n in 0 ..= len(original) {
			if n <= head || n >= len(original) - tail || n % 37 == 0 {
				read_everything(original[:n])
			}
		}
		data := concat(original)
		for i in 0 ..< 300 {
			mutate(data, original, head, tail)
			read_everything(data, {skip_picture_data = i % 3 == 0})
		}
	}
}

@(test)
sizes_that_lie :: proc(t: ^testing.T) {
	sizes := []u32 {
		0,
		1,
		2,
		9,
		10,
		11,
		0x7F,
		0x80,
		0xFF,
		0x100,
		0x7FFF,
		0xFFFF,
		0x0FFF_FFFF,
		0x7FFF_FFFF,
		0xFFFF_FFFF,
	}
	for name in fixture_names(t) {
		original := fixture(t, name)
		tags := read_quietly(original)
		defer odid3.destroy(&tags)
		if tags.v2.version == .None || tags.layout.v2.offset != 0 {
			continue
		}
		data := concat(original)
		for size in sizes {
			// The tag size, syncsafe or not.
			copy(data, original)
			data[6], data[7], data[8], data[9] =
				u8(size >> 24), u8(size >> 16), u8(size >> 8), u8(size)
			read_everything(data)
			for f in tags.v2.frames {
				if f.offset < 0 || f.offset + 10 > i64(len(data)) {
					continue
				}
				copy(data, original)
				at := int(f.offset)
				if tags.v2.version == .V2_2 {
					data[at + 3], data[at + 4], data[at + 5] =
						u8(size >> 16), u8(size >> 8), u8(size)
				} else {
					data[at + 4], data[at + 5] = u8(size >> 24), u8(size >> 16)
					data[at + 6], data[at + 7] = u8(size >> 8), u8(size)
				}
				read_everything(data)
			}
		}
	}
}

@(test)
reading_a_file_gives_what_reading_its_bytes_gives :: proc(t: ^testing.T) {
	dir := make_temp_dir(t)
	path := join(dir, "damaged.mp3")
	for name in fixture_names(t) {
		original := fixture(t, name)
		head, tail := tag_bytes(original)
		data := concat(original)
		for _ in 0 ..< 10 {
			mutate(data, original, head, tail)
			n := rand.int_max(len(data) + 1)
			if os.write_entire_file(path, data[:n]) != nil {
				testing.fail_now(t, "cannot write the damaged file")
			}
			from_file, file_err := odid3.read_file(path)
			from_bytes := read_quietly(data[:n])
			testing.expectf(
				t,
				file_err == nil && summarise(&from_file) == summarise(&from_bytes),
				"%s cut at %d: %v",
				name,
				n,
				file_err,
			)
			odid3.destroy(&from_file)
			odid3.destroy(&from_bytes)
		}
	}
}

// What reading and every accessor may allocate: 40 times the input (a tag of empty ID3v2.2 frames
// takes about 33), plus what each compressed frame may inflate to.
allowed_memory :: proc(data: []u8) -> i64 {
	tags := read_quietly(data)
	defer odid3.destroy(&tags)
	bound := 40 * i64(len(data)) + 64 * 1024
	for f in tags.v2.frames {
		if .Compression in f.format {
			inflated := 1032 * i64(f.size) + 1024
			if f.data_length >= 0 {
				inflated = min(inflated, i64(f.data_length) + 64 * 1024)
			}
			bound += inflated
		}
	}
	return bound
}

expect_bounded_memory :: proc(t: ^testing.T, name: string, data: []u8, loc := #caller_location) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	read_everything(data, {}, mem.tracking_allocator(&track))
	bound := allowed_memory(data)
	testing.expectf(
		t,
		track.peak_memory_allocated <= bound,
		"%s: %v bytes for %v, at most %v",
		name,
		track.peak_memory_allocated,
		len(data),
		bound,
		loc = loc,
	)
}

@(test)
allocations_are_bounded_by_the_input :: proc(t: ^testing.T) {
	for name in fixture_names(t) {
		original := fixture(t, name)
		head, tail := tag_bytes(original)
		expect_bounded_memory(t, name, original)
		data := concat(original)
		for _ in 0 ..< 50 {
			mutate(data, original, head, tail)
			expect_bounded_memory(t, name, data)
		}
	}
	many :: proc(part: []u8, count: int) -> []u8 {
		parts := make([]([]u8), count, context.temp_allocator)
		for &p in parts {
			p = part
		}
		return concat(..parts)
	}
	expect_bounded_memory(
		t,
		"empty ID3v2.2 frames",
		tag_file(2, 0, many(frame22("TT2", nil), 40_000)),
	)
	expect_bounded_memory(
		t,
		"empty ID3v2.3 frames",
		tag_file(3, 0, many(frame(3, "TIT2", nil), 70_000)),
	)
	expect_bounded_memory(
		t,
		"genre references",
		tag_file(4, 0, frame(4, "TCON", concat({3}, many(text("1\x00"), 100_000)))),
	)
	expect_bounded_memory(
		t,
		"frames in a chapter",
		tag_file(4, 0, chapter_frame(4, "ch0", 0, 1, many(frame(4, "TIT2", nil), 70_000))),
	)
}

@(test)
too_many_frames :: proc(t: ^testing.T) {
	empty := frame(3, "TIT2", nil)
	parts := make([dynamic][]u8, context.temp_allocator)
	for _ in 0 ..< 1 << 16 {
		append(&parts, empty)
	}
	exactly := read(t, tag_file(3, 0, concat(..parts[:]), zeros(10)))
	defer odid3.destroy(&exactly)
	testing.expect_value(t, exactly.warnings, odid3.Warnings{})
	testing.expect_value(t, len(exactly.v2.frames), 1 << 16)
	testing.expect_value(t, exactly.v2.padding, 10)

	append(&parts, empty)
	one_more := read(t, tag_file(3, 0, ..parts[:]))
	defer odid3.destroy(&one_more)
	testing.expect_value(t, one_more.warnings, odid3.Warnings{.Too_Many_Frames})
	testing.expect_value(t, len(one_more.v2.frames), 1 << 16)

	content, err := decode_one(t, 4, chapter_frame(4, "ch0", 0, 1, ..parts[:]))
	testing.expect_value(t, err, nil)
	chapter := expect_content(t, content, odid3.Chapter)
	testing.expect_value(t, chapter.warnings, odid3.Warnings{.Too_Many_Frames})
	testing.expect_value(t, len(chapter.frames), 1 << 16)
}
