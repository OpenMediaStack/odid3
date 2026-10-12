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

@(test)
v1_values_kept_and_cleared :: proc(t: ^testing.T) {
	// A field the ID3v2 tag lacks keeps its ID3v1 value, as get shows it; clearing it in tags.v1
	// clears it for good.
	v1 := v1_tag()
	copy(v1[3:], "Old title")
	copy(v1[93:], "97")
	file := concat(tag_file(3, 0, frame(3, "TPE1", text("\x00Kite"))), v1)
	tags := read(t, file)
	defer odid3.destroy(&tags)
	overflow := odid3.sync_v1(&tags, .Keep)
	testing.expect_value(t, overflow, odid3.Fields{})
	testing.expect_value(t, tags.v1.title, "Old title")
	testing.expect_value(t, tags.v1.artist, "Kite")
	testing.expect_value(t, tags.v1.year, "97")
	delete(tags.v1.title, tags.v1.allocator)
	tags.v1.title = ""
	odid3.sync_v1(&tags, .Keep)
	testing.expect_value(t, tags.v1.title, "")
}

@(test)
v1_corner_cases :: proc(t: ^testing.T) {
	none: odid3.V1_Tag
	testing.expect(t, odid3.render_v1(&none) == nil)

	// ID3v1.1 without a track is ID3v1.0: the same bytes, with the whole comment.
	comment := "A comment of thirty characters"
	tags := read(t, tag_file(3, 0, frame(3, "COMM", concat(text("\x00eng\x00"), text(comment)))))
	defer odid3.destroy(&tags)
	v1, overflow, _ := odid3.v1_from_tag(&tags.v2, .V1_1, false, context.temp_allocator)
	testing.expect_value(t, overflow, odid3.Fields{})
	testing.expect_value(t, v1.version, odid3.V1_Version.V1_0)
	hand_made := odid3.V1_Tag {
		version = .V1_1,
		comment = comment,
		genre   = 255,
	}
	rendered := odid3.render_v1(&hand_made, context.temp_allocator)
	testing.expect_value(t, string(rendered[97:127]), comment)

	// Short text outside Latin-1 needs no Enhanced TAG.
	cjk := read(t, tag_file(4, 0, frame(4, "TPE1", text("\x03坂本龍一"))))
	defer odid3.destroy(&cjk)
	short, short_overflow, _ := odid3.v1_from_tag(&cjk.v2, .V1_0, true, context.temp_allocator)
	testing.expect_value(t, short_overflow, odid3.Fields{.Artist})
	testing.expect(t, short.enhanced == nil)

	for c in ([]struct {
			name:  string,
			index: u8,
		}{{"Alt. Rock", 40}, {"Alternative Rock", 40}, {"Hip Hop", 7}, {"Jazz-Funk", 29}, {"Afro-Punk", 133}, {"hardcore", 129}}) {
		index, known := odid3.genre_index(c.name)
		testing.expectf(t, known && index == c.index, "%s gave %d", c.name, index)
	}
}

@(test)
enhanced_genre_without_the_enhanced_tag :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v1_enhanced.mp3"))
	defer odid3.destroy(&tags)
	overflow := odid3.sync_v1(&tags, .Keep, nil, false)
	testing.expect(t, .Genre in overflow)
	testing.expect(t, tags.v1.enhanced == nil)
}

@(test)
sync_v1_uses_the_allocator_of_the_read :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	tags, err := odid3.read_bytes(fixture(t, "no_tag.mp3"), {}, allocator)
	testing.expect_value(t, err, nil)
	odid3.sync_v1(&tags, .Always)
	testing.expect_value(t, tags.v1.version, odid3.V1_Version.V1_0)
	testing.expect(t, tags.v1.allocator.data == allocator.data)
	testing.expect(t, tags.v2.allocator.data == allocator.data)
	odid3.destroy(&tags)
	testing.expect_value(t, track.current_memory_allocated, 0)
}

@(test)
sync_v1_allocation_failures_leak_nothing :: proc(t: ^testing.T) {
	for name in ([]string{"v1_enhanced.mp3", "v23_v1_long_title.mp3", "v23_full.mp3"}) {
		succeeded := false
		for budget in 0 ..< 64 {
			failing := Failing{context.allocator, 1 << 30}
			tags, read_err := odid3.read_bytes(fixture(t, name), {}, failing_allocator(&failing))
			testing.expect_value(t, read_err, nil)
			failing.left = budget
			_, err := odid3.sync_v1(&tags, .Always, nil, true)
			odid3.destroy(&tags)
			if err == nil {
				succeeded = true
				break
			}
			testing.expect_value(t, err, mem.Allocator_Error.Out_Of_Memory)
		}
		testing.expectf(t, succeeded, "%s never succeeded", name)
	}
}
