package odid3_tests

import "core:bytes"
import "core:hash"
import "core:math/rand"
import "core:mem"
import "core:slice"
import "core:testing"

import odid3 "../"

be32 :: proc(n: u32) -> []u8 {
	return concat({u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)})
}

chapter_data :: proc(id: string, start_ms, end_ms: u32, frames: ..[]u8) -> []u8 {
	header := concat(text(id), {0}, be32(start_ms), be32(end_ms), be32(max(u32)), be32(max(u32)))
	return concat(header, concat(..frames))
}

chapter_frame :: proc(major: u8, id: string, start_ms, end_ms: u32, frames: ..[]u8) -> []u8 {
	return frame(major, "CHAP", chapter_data(id, start_ms, end_ms, ..frames))
}

// A zlib stream holding data in one stored block, which every inflater reads.
zlib_stored :: proc(data: []u8) -> []u8 {
	n := len(data)
	block := []u8{0x01, u8(n), u8(n >> 8), ~u8(n), ~u8(n >> 8)}
	return concat({0x78, 0x01}, block, data, be32(hash.adler32(data)))
}

// An ID3v2.4 frame compressed as zlib_stored, with its data length indicator.
compressed_frame :: proc(id: string, data: []u8) -> []u8 {
	n := len(data)
	length := []u8{u8(n >> 21) & 0x7F, u8(n >> 14) & 0x7F, u8(n >> 7) & 0x7F, u8(n) & 0x7F}
	return frame(4, id, concat(length, zlib_stored(data)), 0, 0x09)
}

@(test)
chapters_written_by_ffmpeg :: proc(t: ^testing.T) {
	for name in ([]string{"v23_chapters.mp3", "v24_chapters.mp3"}) {
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		testing.expect_value(t, tags.warnings, odid3.Warnings{})
		ids := []string{"TIT2", "CTOC", "CHAP", "CHAP"}
		testing.expect_value(t, len(tags.v2.frames), len(ids))

		toc := expect_content(
			t,
			decode(t, &tags.v2.frames[1], tags.v2.version),
			odid3.Table_Of_Contents,
		)
		testing.expect_value(t, toc.element_id, "toc")
		testing.expect(t, toc.top_level && toc.ordered)
		testing.expectf(
			t,
			slice.equal(toc.children, []string{"ch0", "ch1"}),
			"%s: %v",
			name,
			toc.children,
		)
		testing.expect_value(t, len(toc.frames), 0)

		titles := []string{"Intro", "Outro"}
		for i in 0 ..< 2 {
			chapter := expect_content(
				t,
				decode(t, &tags.v2.frames[2 + i], tags.v2.version),
				odid3.Chapter,
			)
			testing.expect_value(t, chapter.element_id, toc.children[i])
			testing.expect_value(t, chapter.start_ms, u32(50 * i))
			testing.expect_value(t, chapter.end_ms, u32(50 * (i + 1)))
			testing.expect_value(t, chapter.start_offset, max(u32))
			testing.expect_value(t, chapter.end_offset, max(u32))
			testing.expect_value(t, len(chapter.frames), 1)
			title := &chapter.frames[0]
			testing.expect_value(t, title.id, "TIT2")
			testing.expect_value(t, title.offset, -1)
			expect_text(
				t,
				decode(t, title, tags.v2.version),
				title.data[0] == 3 ? .UTF8 : .Latin1,
				titles[i],
			)
		}
	}
}

@(test)
damaged_chapters :: proc(t: ^testing.T) {
	_, err := decode_one(t, 4, frame(4, "CHAP", text("ch0\x00\x00\x00")))
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Bad_Content))
	_, err = decode_one(t, 4, frame(4, "CTOC", text("toc\x00\x03\x02ch0\x00")))
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Bad_Content))

	cut_frames := concat(frame(4, "TIT2", text("\x03Intro")), text("TPE1\x00\x00\x01"))
	content, chapter_err := decode_one(t, 4, chapter_frame(4, "ch0", 0, 10, cut_frames))
	testing.expect_value(t, chapter_err, nil)
	testing.expect_value(t, len(expect_content(t, content, odid3.Chapter).frames), 1)
}

@(test)
chapter_allocation_failures_leak_nothing :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v24_chapters.mp3"))
	defer odid3.destroy(&tags)
	for &f in tags.v2.frames[1:] {
		for budget in 0 ..< 32 {
			failing := Failing{context.allocator, budget}
			allocator := failing_allocator(&failing)
			content, err := odid3.decode_frame(&f, .V2_4, allocator)
			if err == nil {
				odid3.destroy(&content, allocator)
				break
			}
			testing.expect_value(t, err, odid3.Error(mem.Allocator_Error.Out_Of_Memory))
			testing.expectf(t, budget < 31, "%s never decoded", f.id)
		}
	}
}

@(test)
frames_inside_chapters_follow_the_version :: proc(t: ^testing.T) {
	long := concat(text("\x00"), letters(200))
	for major in ([]u8{3, 4}) {
		content, err := decode_one(
			t,
			major,
			chapter_frame(major, "ch0", 0, 10, frame(major, "TIT2", long)),
		)
		testing.expect_value(t, err, nil)
		chapter := expect_content(t, content, odid3.Chapter)
		testing.expect_value(t, chapter.warnings, odid3.Warnings{})
		testing.expect_value(t, len(chapter.frames), 1)
		testing.expect(t, len(chapter.frames) == 1 && bytes.equal(chapter.frames[0].data, long))
	}

	// iTunes' plain frame sizes, inside a chapter too.
	plain := concat(text("TIT2"), be32(u32(len(long))), {0, 0}, long)
	content, _ := decode_one(
		t,
		4,
		chapter_frame(4, "ch0", 0, 10, plain, frame(4, "TPE1", text("\x03Kite"))),
	)
	chapter := expect_content(t, content, odid3.Chapter)
	testing.expect_value(t, len(chapter.frames), 2)
	testing.expect_value(t, chapter.warnings, odid3.Warnings{.Plain_Frame_Sizes})

	unsynchronised := frame(4, "TIT2", unsynchronise(text("\x01\xFF\xFEA\x00")), 0, 0x02)
	content, _ = decode_one(t, 4, chapter_frame(4, "ch0", 0, 10, unsynchronised))
	title := expect_content(t, content, odid3.Chapter).frames[0]
	testing.expect_value(t, string(title.data), "\x01\xFF\xFEA\x00")

	compressed := compressed_frame("TIT2", text("\x03Intro"))
	content, _ = decode_one(t, 4, chapter_frame(4, "ch0", 0, 10, compressed))
	inflated := expect_content(t, content, odid3.Chapter).frames[0]
	testing.expect_value(t, inflated.problem, odid3.Frame_Problem.None)
	testing.expect_value(t, string(inflated.data), "\x03Intro")
}

@(test)
nested_compression_is_not_inflated :: proc(t: ^testing.T) {
	bomb := read(t, fixture(t, "v24_compression_bomb.mp3"))
	defer odid3.destroy(&bomb)
	stream := bomb.v2.frames[0].data // the zlib stream of 16 MiB of zeros, kept as stored
	inner := frame(4, "TIT2", concat({0x08, 0, 0, 0}, stream), 0, 0x09)
	chapter := chapter_data("ch0", 0, 10, inner)
	n := len(chapter)
	length := []u8{u8(n >> 21) & 0x7F, u8(n >> 14) & 0x7F, u8(n >> 7) & 0x7F, u8(n) & 0x7F}
	tags := read(
		t,
		tag_file(4, 0, frame(4, "CHAP", concat(length, zlib_stored(chapter)), 0, 0x09)),
	)
	defer odid3.destroy(&tags)
	testing.expect_value(t, tags.v2.frames[0].problem, odid3.Frame_Problem.None)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	content, err := odid3.decode_frame(&tags.v2.frames[0], .V2_4, allocator)
	defer odid3.destroy(&content, allocator)
	testing.expect_value(t, err, nil)
	decoded := expect_content(t, content, odid3.Chapter)
	testing.expect_value(t, decoded.frames[0].problem, odid3.Frame_Problem.Bad_Compression)
	testing.expect_value(t, decoded.warnings, odid3.Warnings{.Frame_Problems})
	testing.expectf(
		t,
		track.peak_memory_allocated < 64 * 1024,
		"peak %d bytes",
		track.peak_memory_allocated,
	)
}

@(test)
what_chapters_hold_that_cannot_be_right :: proc(t: ^testing.T) {
	garbage := concat(
		frame(4, "TIT2", text("\x03Intro")),
		text("garbage!"),
		frame(4, "TPE1", text("\x03Kite")),
	)
	content, err := decode_one(t, 4, chapter_frame(4, "ch0", 0, 10, garbage))
	testing.expect_value(t, err, nil)
	chapter := expect_content(t, content, odid3.Chapter)
	testing.expect_value(t, len(chapter.frames), 1)
	testing.expect_value(t, chapter.warnings, odid3.Warnings{.Damaged_Frames})

	unterminated := frame(4, "CTOC", text("toc\x00\x03\x02ch0\x00ch1"))
	_, err = decode_one(t, 4, unterminated)
	testing.expect_value(t, err, odid3.Error(odid3.Format_Error.Bad_Content))

	one_too_many := frame(
		4,
		"CTOC",
		concat(text("toc\x00\x03\x01ch0\x00ch1\x00"), frame(4, "TIT2", text("\x03All"))),
	)
	content, err = decode_one(t, 4, one_too_many)
	testing.expect_value(t, err, nil)
	toc := expect_content(t, content, odid3.Table_Of_Contents)
	testing.expect(t, slice.equal(toc.children, []string{"ch0"}))
	testing.expect_value(t, toc.warnings, odid3.Warnings{.Damaged_Frames})

	with_title := frame(
		4,
		"CTOC",
		concat(text("toc\x00\x03\x01ch0\x00"), frame(4, "TIT2", text("\x03All"))),
	)
	content, err = decode_one(t, 4, with_title)
	testing.expect_value(t, err, nil)
	titled := expect_content(t, content, odid3.Table_Of_Contents)
	testing.expect_value(t, len(titled.frames), 1)
	testing.expect_value(t, titled.warnings, odid3.Warnings{})
}

@(test)
chapter_inside_a_chapter :: proc(t: ^testing.T) {
	inner := chapter_frame(4, "ch1", 0, 5, frame(4, "TIT2", text("\x03Inner")))
	content, err := decode_one(t, 4, chapter_frame(4, "ch0", 0, 10, inner))
	testing.expect_value(t, err, nil)
	outer := expect_content(t, content, odid3.Chapter)
	testing.expect_value(t, outer.frames[0].id, "CHAP")
	testing.expect_value(t, outer.frames[0].problem, odid3.Frame_Problem.Nested_Chapter)
	_, nested_err := odid3.decode_frame(&outer.frames[0], .V2_4, context.temp_allocator)
	testing.expect_value(t, nested_err, odid3.Error(odid3.Format_Error.Not_Decodable))
}

@(test)
damaged_chapter_fixtures_decode_without_panic :: proc(t: ^testing.T) {
	decode_all :: proc(frames: []odid3.Frame, version: odid3.V2_Version, depth: int) {
		for &f in frames {
			content, err := odid3.decode_frame(&f, version)
			if err == nil && depth < 3 {
				#partial switch c in content {
				case odid3.Chapter:
					decode_all(c.frames[:], version, depth + 1)
				case odid3.Table_Of_Contents:
					decode_all(c.frames[:], version, depth + 1)
				}
			}
			odid3.destroy(&content)
		}
	}
	for name in ([]string{"v23_chapters.mp3", "v24_chapters.mp3"}) {
		original := fixture(t, name)
		data := concat(original)
		for _ in 0 ..< 2000 {
			copy(data, original)
			for _ in 0 ..< 1 + rand.int_max(4) {
				data[rand.int_max(min(len(data), 400))] = u8(rand.uint32())
			}
			tags := read(t, data)
			decode_all(tags.v2.frames[:], tags.v2.version, 0)
			odid3.destroy(&tags)
		}
	}
}
