package odid3_tests

import "core:bytes"
import "core:mem"
import "core:testing"

import odid3 "../"

@(test)
v1_tags_render_to_the_bytes_they_were_read_from :: proc(t: ^testing.T) {
	for name in ([]string{"v1_0_ascii.mp3", "v1_1_ascii.mp3", "v1_latin1.mp3", "v1_genre_out_of_range.mp3", "v1_enhanced.mp3"}) {
		file := fixture(t, name)
		tags := read(t, file)
		defer odid3.destroy(&tags)
		rendered := odid3.render_v1(&tags.v1, context.temp_allocator)
		start :=
			tags.layout.v1_enhanced.size > 0 ? tags.layout.v1_enhanced.offset : tags.layout.v1.offset
		testing.expectf(t, bytes.equal(rendered, file[start:]), "%s renders otherwise", name)
	}
	// ffmpeg wrote UTF-8, which the spec does not allow: odid3 writes Latin-1.
	tags := read(t, fixture(t, "v1_utf8.mp3"))
	defer odid3.destroy(&tags)
	latin1 := fixture(t, "v1_latin1.mp3")
	rendered := odid3.render_v1(&tags.v1, context.temp_allocator)
	testing.expect(t, bytes.equal(rendered[3:93], latin1[len(latin1) - 125:][:90]))
}

@(test)
v1_from_an_id3v2_tag :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&tags)
	v1, overflow, err := odid3.v1_from_tag(&tags.v2, .V1_1, false, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, overflow, odid3.Fields{})
	testing.expect_value(t, v1.title, "Paper Satellites")
	testing.expect_value(t, v1.year, "2019")
	testing.expect_value(t, v1.comment, "Recorded in one take.")
	testing.expect_value(t, v1.track, 3)
	testing.expect_value(t, odid3.genre_name(v1.genre), "Folk")

	v10, overflow10, _ := odid3.v1_from_tag(&tags.v2, .V1_0, false, context.temp_allocator)
	testing.expect_value(t, overflow10, odid3.Fields{.Track})
	testing.expect_value(t, v10.track, 0)
}

@(test)
values_that_do_not_fit_v1 :: proc(t: ^testing.T) {
	long := "A title longer than thirty characters, by far"
	frames := concat(
		frame(4, "TIT2", concat(text("\x03"), text(long))),
		frame(4, "TPE1", text("\x03坂本龍一")),
		frame(4, "TDRC", text("\x032019-05-03")),
		frame(4, "TRCK", text("\x03300")),
		frame(4, "TCON", text("\x03Chamber Folk")),
		frame(4, "COMM", text("\x03eng\x00A comment of more than twenty eight bytes")),
	)
	tags := read(t, tag_file(4, 0, frames))
	defer odid3.destroy(&tags)
	v1, overflow, _ := odid3.v1_from_tag(&tags.v2, .V1_1, false, context.temp_allocator)
	testing.expect_value(
		t,
		overflow,
		odid3.Fields{.Title, .Artist, .Date, .Track, .Genre, .Comment},
	)
	testing.expect_value(t, v1.genre, 255)
	rendered := odid3.render_v1(&v1, context.temp_allocator)
	testing.expect_value(t, string(rendered[3:33]), "A title longer than thirty cha")
	testing.expect_value(t, string(rendered[33:37]), "????")
	testing.expect_value(t, string(rendered[93:97]), "2019")

	enhanced, enhanced_overflow, _ := odid3.v1_from_tag(
		&tags.v2,
		.V1_1,
		true,
		context.temp_allocator,
	)
	testing.expect_value(t, enhanced_overflow, odid3.Fields{.Artist, .Date, .Track, .Comment})
	e, ok := enhanced.enhanced.?
	testing.expect(t, ok)
	testing.expect_value(t, e.genre, "Chamber Folk")
	with_enhanced := odid3.render_v1(&enhanced, context.temp_allocator)
	testing.expect_value(t, len(with_enhanced), 355)
	testing.expect_value(t, string(with_enhanced[:4]), "TAG+")
	testing.expect_value(t, string(with_enhanced[4:19]), "racters, by far")

	again := read(t, concat(zeros(100), with_enhanced))
	defer odid3.destroy(&again)
	testing.expect_value(t, again.v1.title, long)
}

@(test)
v1_policies :: proc(t: ^testing.T) {
	with_v1 := read(t, fixture(t, "v23_v1_long_title.mp3"))
	defer odid3.destroy(&with_v1)
	overflow := odid3.sync_v1(&with_v1, .Keep)
	testing.expect_value(t, overflow, odid3.Fields{.Title})
	testing.expect_value(t, with_v1.v1.version, odid3.V1_Version.V1_1)
	testing.expect_value(t, with_v1.v1.title, "A title longer than thirty characters")

	without := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&without)
	odid3.sync_v1(&without, .Keep)
	testing.expect_value(t, without.v1.version, odid3.V1_Version.None)
	odid3.sync_v1(&without, .Always, odid3.V1_Version.V1_0)
	testing.expect_value(t, without.v1.version, odid3.V1_Version.V1_0)
	testing.expect_value(t, without.v1.album, "Small Hours")
	odid3.sync_v1(&without, .Never)
	testing.expect_value(t, without.v1.version, odid3.V1_Version.None)

	enhanced := read(t, fixture(t, "v1_enhanced.mp3"))
	defer odid3.destroy(&enhanced)
	odid3.sync_v1(&enhanced, .Keep)
	e, kept := enhanced.v1.enhanced.?
	testing.expect(t, kept)
	testing.expect_value(t, enhanced.v1.title, "A title that needs the Enhanced TAG to fit")
	testing.expect_value(t, e.start_time, "000:05")

	// Without an ID3v2 tag, ID3v1 is rebuilt from itself: every value stays.
	for name in ([]string{"v1_1_ascii.mp3", "v1_genre_out_of_range.mp3", "v1_enhanced.mp3"}) {
		file := fixture(t, name)
		only_v1 := read(t, file)
		defer odid3.destroy(&only_v1)
		odid3.sync_v1(&only_v1, .Keep)
		rendered := odid3.render_v1(&only_v1.v1, context.temp_allocator)
		testing.expectf(
			t,
			bytes.equal(rendered, file[len(file) - len(rendered):]),
			"%s changed",
			name,
		)
	}
}

@(test)
v1_allocation_failures_leak_nothing :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&tags)
	succeeded := false
	for budget in 0 ..< 64 {
		failing := Failing{context.allocator, budget}
		allocator := failing_allocator(&failing)
		v1, _, err := odid3.v1_from_tag(&tags.v2, .V1_1, true, allocator)
		if err == nil {
			odid3.destroy(&v1)
			succeeded = true
			break
		}
		testing.expect_value(t, err, mem.Allocator_Error.Out_Of_Memory)
	}
	testing.expect(t, succeeded)
}
