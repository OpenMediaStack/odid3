package odid3_tests

import "core:mem"
import "core:slice"
import "core:testing"

import odid3 "../"

chapter_frame :: proc(major: u8, id: string, start_ms, end_ms: u32, frames: ..[]u8) -> []u8 {
	be :: proc(n: u32) -> []u8 {
		return concat({u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)})
	}
	header := concat(text(id), {0}, be(start_ms), be(end_ms), be(max(u32)), be(max(u32)))
	return frame(major, "CHAP", concat(header, concat(..frames)))
}

@(test)
chapters_written_by_ffmpeg :: proc(t: ^testing.T) {
	for name in ([]string{"v23_chapters.mp3", "v24_chapters.mp3"}) {
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		testing.expect_value(t, tags.warnings, odid3.Warnings{})
		ids := []string{"TIT2", "CTOC", "CHAP", "CHAP"}
		testing.expect_value(t, len(tags.v2.frames), len(ids))

		toc := decode(t, &tags.v2.frames[1], tags.v2.version).(odid3.Table_Of_Contents)
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
			chapter := decode(t, &tags.v2.frames[2 + i], tags.v2.version).(odid3.Chapter)
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
	testing.expect_value(t, len(content.(odid3.Chapter).frames), 1)
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
		}
	}
}
