package odid3_tests

import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import odid3 "../"

field :: proc(tags: ^odid3.Tags, f: odid3.Field) -> string {
	return odid3.get(tags, f, context.temp_allocator)
}

tag_field :: proc(tag: ^odid3.Tag, f: odid3.Field) -> string {
	return odid3.get(tag, f, context.temp_allocator)
}

@(test)
fields_of_ffmpeg_tags :: proc(t: ^testing.T) {
	for name in ([]string{"v23_full.mp3", "v24_full.mp3"}) {
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		want := [odid3.Field]string {
			.Title        = "Paper Satellites",
			.Artist       = "Marlowe Kite",
			.Album_Artist = "Various Artists",
			.Album        = "Small Hours",
			.Date         = "2019",
			.Track        = "3",
			.Track_Total  = "12",
			.Disc         = "1",
			.Disc_Total   = "2",
			.Genre        = "Folk",
			.Comment      = "Recorded in one take.",
		}
		for value, f in want {
			testing.expectf(t, field(&tags, f) == value, "%s %v: %q", name, f, field(&tags, f))
		}
		y, ok := odid3.year(&tags.v2)
		testing.expect(t, ok && y == 2019)
		number, total := odid3.track(&tags.v2)
		testing.expect(t, number == 3 && total == 12)
		number, total = odid3.disc(&tags.v2)
		testing.expect(t, number == 1 && total == 2)
	}
	tags := read(t, fixture(t, "v24_full.mp3"))
	defer odid3.destroy(&tags)
	mood, found, err := odid3.user_text(&tags.v2, "MOOD", context.temp_allocator)
	testing.expect(t, found && err == nil && mood == "Calm")
	_, found, err = odid3.user_text(&tags.v2, "tempo", context.temp_allocator)
	testing.expect(t, !found && err == nil)
}

@(test)
fields_of_v22_and_v1 :: proc(t: ^testing.T) {
	v22 := read(t, fixture(t, "v22.mp3"))
	defer odid3.destroy(&v22)
	testing.expect_value(t, field(&v22, .Genre), "Rock")
	testing.expect_value(t, field(&v22, .Comment), "Recorded in one take.")
	testing.expect_value(t, field(&v22, .Date), "2019")
	testing.expect_value(t, field(&v22, .Track_Total), "12")

	v1 := read(t, fixture(t, "v1_1_ascii.mp3"))
	defer odid3.destroy(&v1)
	testing.expect_value(t, field(&v1, .Title), "Track seven")
	testing.expect_value(t, field(&v1, .Date), "2004")
	testing.expect_value(t, field(&v1, .Track), "7")
	testing.expect_value(t, field(&v1, .Genre), "Folk-Rock")
	testing.expect_value(t, field(&v1, .Comment), "Short comment")
	testing.expect_value(t, field(&v1, .Album_Artist), "")
	testing.expect_value(t, tag_field(&v1.v2, .Title), "")
	y, ok := odid3.year(&v1)
	testing.expect(t, ok && y == 2004)
	number, total := odid3.track(&v1)
	testing.expect(t, number == 7 && total == 0)
	number, _ = odid3.track(&v1.v2)
	testing.expect_value(t, number, 0)

	v22_text := read(
		t,
		tag_file(
			2,
			0,
			frame22("TXX", text("\x00mood\x00Calm")),
			frame22("COM", text("\x00eng\x00Plain")),
		),
	)
	defer odid3.destroy(&v22_text)
	mood, found, _ := odid3.user_text(&v22_text.v2, "mood", context.temp_allocator)
	testing.expect(t, found && mood == "Calm")
	testing.expect_value(t, field(&v22_text, .Comment), "Plain")

	both := read(t, fixture(t, "v23_v1_long_title.mp3"))
	defer odid3.destroy(&both)
	testing.expect_value(t, field(&both, .Title), "A title longer than thirty characters")

	enhanced := read(t, fixture(t, "v1_enhanced.mp3"))
	defer odid3.destroy(&enhanced)
	testing.expect_value(t, field(&enhanced, .Genre), "Chamber Folk")
	testing.expect_value(t, field(&enhanced, .Title), "A title that needs the Enhanced TAG to fit")
}

@(test)
dates_in_each_version :: proc(t: ^testing.T) {
	v23 := read(
		t,
		tag_file(
			3,
			0,
			frame(3, "TYER", text("\x002019")),
			frame(3, "TDAT", text("\x000305")),
			frame(3, "TIME", text("\x001020")),
		),
	)
	defer odid3.destroy(&v23)
	testing.expect_value(t, field(&v23, .Date), "2019-05-03T10:20")
	v22 := read(
		t,
		tag_file(2, 0, frame22("TYE", text("\x002019")), frame22("TDA", text("\x000305"))),
	)
	defer odid3.destroy(&v22)
	testing.expect_value(t, field(&v22, .Date), "2019-05-03")
	v24 := read(t, tag_file(4, 0, frame(4, "TDRC", text("\x032019-05-03T10:20:30"))))
	defer odid3.destroy(&v24)
	testing.expect_value(t, field(&v24, .Date), "2019-05-03T10:20:30")
	y, ok := odid3.year(&v24.v2)
	testing.expect(t, ok && y == 2019)
	bad := read(t, tag_file(3, 0, frame(3, "TYER", text("\x00around 2019"))))
	defer odid3.destroy(&bad)
	_, ok = odid3.year(&bad.v2)
	testing.expect(t, !ok)

	// The day and the time only count after a year of 4 digits, when they can be a date and a time.
	malformed := []struct {
		year, day_month, time, want: string,
	} {
		{"19", "0305", "", "19"},
		{"around 2019", "0305", "", "around 2019"},
		{"2019", "9999", "", "2019"},
		{"2019", "0013", "", "2019"},
		{"2019", "305", "", "2019"},
		{"2019", "", "1020", "2019"},
		{"2019", "0305", "2560", "2019-05-03"},
		{"2019", "3112", "2359", "2019-12-31T23:59"},
	}
	for c in malformed {
		frames := make([dynamic][]u8, context.temp_allocator)
		append(&frames, frame(3, "TYER", concat({0}, text(c.year))))
		if c.day_month != "" {
			append(&frames, frame(3, "TDAT", concat({0}, text(c.day_month))))
		}
		if c.time != "" {
			append(&frames, frame(3, "TIME", concat({0}, text(c.time))))
		}
		tags := read(t, tag_file(3, 0, ..frames[:]))
		defer odid3.destroy(&tags)
		testing.expectf(t, field(&tags, .Date) == c.want, "%v gave %q", c, field(&tags, .Date))
	}
}

@(test)
track_and_disc_numbers :: proc(t: ^testing.T) {
	cases := []struct {
		value:         string,
		number, total: int,
	} {
		{"3/12", 3, 12},
		{" 3 ", 3, 0},
		{"03", 3, 0},
		{"3/", 3, 0},
		{"/12", 0, 12},
		{"-3", 0, 0},
		{"99999999999", 0, 0},
		{"three", 0, 0},
	}
	for c in cases {
		tags := read(
			t,
			tag_file(
				3,
				0,
				frame(3, "TRCK", concat({0}, text(c.value))),
				frame(3, "TPOS", concat({0}, text(c.value))),
			),
		)
		defer odid3.destroy(&tags)
		number, total := odid3.track(&tags)
		testing.expectf(
			t,
			number == c.number && total == c.total,
			"track %q: %d/%d",
			c.value,
			number,
			total,
		)
		number, total = odid3.disc(&tags)
		testing.expectf(
			t,
			number == c.number && total == c.total,
			"disc %q: %d/%d",
			c.value,
			number,
			total,
		)
	}
	// A value too long for the stack is no number, and costs no allocation.
	long := read(t, tag_file(3, 0, frame(3, "TRCK", concat({0}, letters(5000)))))
	defer odid3.destroy(&long)
	number, total := odid3.track(&long.v2)
	testing.expect(t, number == 0 && total == 0)
}

@(test)
genre_references :: proc(t: ^testing.T) {
	cases := []struct {
		major: u8,
		data:  string,
		want:  []string,
	} {
		{3, "\x00(17)", {"Rock"}},
		{3, "\x0017", {"Rock"}},
		{3, "\x00(17)(18)", {"Rock", "Techno"}},
		{3, "\x00(4)Eurodisco", {"Disco", "Eurodisco"}},
		{3, "\x00(17)(18)Eurodisco", {"Rock", "Techno", "Eurodisco"}},
		{3, "\x00(4)Disco", {"Disco"}},
		{3, "\x00(17)(abc)", {"Rock", "(abc)"}},
		{3, "\x00(255)", {"(255)"}},
		{3, "\x00((", {"("}},
		{3, "\x00((Parenthesis)", {"(Parenthesis)"}},
		{3, "\x00(RX)", {"Remix"}},
		{3, "\x00(CR)", {"Cover"}},
		{3, "\x00(999)", {"(999)"}},
		{3, "\x00Indie", {"Indie"}},
		{4, "\x0317\x00Indie", {"Rock", "Indie"}},
		{4, "\x03RX", {"Remix"}},
	}
	for c in cases {
		tags := read(t, tag_file(c.major, 0, frame(c.major, "TCON", text(c.data))))
		defer odid3.destroy(&tags)
		names := odid3.genres(&tags.v2, context.temp_allocator)
		testing.expectf(t, slice.equal(names, c.want), "%q gave %q", c.data, names)
	}
	tags := read(t, tag_file(4, 0, frame(4, "TCON", text("\x0317\x00Indie"))))
	defer odid3.destroy(&tags)
	testing.expect_value(t, field(&tags, .Genre), "Rock; Indie")
}

@(test)
comment_choice :: proc(t: ^testing.T) {
	itunes := frame(3, "COMM", text("\x00engiTunNORM\x00 000001"))
	other := frame(3, "COMM", text("\x00engOther\x00Described"))
	plain := frame(3, "COMM", text("\x00eng\x00Plain"))
	txxx := frame(3, "TXXX", text("\x00comment\x00From ffmpeg"))
	cases := []struct {
		frames: [][]u8,
		want:   string,
	} {
		{{itunes, plain, other}, "Plain"},
		{{itunes, other}, "Described"},
		{{itunes, txxx}, "From ffmpeg"},
		{{itunes}, ""},
	}
	for c in cases {
		tags := read(t, tag_file(3, 0, ..c.frames))
		defer odid3.destroy(&tags)
		testing.expect_value(t, field(&tags, .Comment), c.want)
	}
	tags := read(t, tag_file(3, 0, itunes, plain))
	defer odid3.destroy(&tags)
	all := odid3.comments(&tags.v2, context.temp_allocator)
	testing.expect_value(t, len(all), 2)
}

@(test)
pictures_and_the_front_cover :: proc(t: ^testing.T) {
	tags := read(t, fixture(t, "v23_cover.mp3"))
	defer odid3.destroy(&tags)
	cover, found, err := odid3.front_cover(&tags.v2)
	defer odid3.destroy(&cover)
	testing.expect(t, found && err == nil)
	testing.expect_value(t, cover.mime, "image/png")

	back := frame(4, "APIC", text("\x03image/jpeg\x00\x04\x00back"))
	front := frame(4, "APIC", text("\x03image/png\x00\x03\x00front"))
	two := read(t, tag_file(4, 0, back, front))
	defer odid3.destroy(&two)
	all := odid3.pictures(&two.v2)
	defer odid3.destroy(&all)
	testing.expect_value(t, len(all), 2)
	chosen, chosen_found, _ := odid3.front_cover(&two.v2)
	defer odid3.destroy(&chosen)
	testing.expect(t, chosen_found)
	testing.expect_value(t, string(chosen.data), "front")

	only_back := read(t, tag_file(4, 0, back))
	defer odid3.destroy(&only_back)
	first, first_found, _ := odid3.front_cover(&only_back.v2)
	defer odid3.destroy(&first)
	testing.expect(t, first_found)
	testing.expect_value(t, string(first.data), "back")

	none := read(t, fixture(t, "v23_full.mp3"))
	defer odid3.destroy(&none)
	_, none_found, _ := odid3.front_cover(&none.v2)
	testing.expect(t, !none_found)

	// Only the cover returned stays in memory, not every picture.
	big := make([]u8, 256 * 1024, context.temp_allocator)
	many := read(
		t,
		tag_file(
			4,
			0,
			frame(4, "APIC", concat(text("\x03image/png\x00\x04\x00"), big)),
			frame(4, "APIC", concat(text("\x03image/png\x00\x05\x00"), big)),
			frame(4, "APIC", concat(text("\x03image/png\x00\x03\x00"), big)),
			frame(4, "APIC", concat(text("\x03image/png\x00\x06\x00"), big)),
		),
	)
	defer odid3.destroy(&many)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	tracked := mem.tracking_allocator(&track)
	big_cover, big_found, _ := odid3.front_cover(&many.v2, tracked)
	testing.expect(t, big_found && big_cover.type == .Front_Cover)
	odid3.destroy(&big_cover, tracked)
	testing.expectf(
		t,
		track.peak_memory_allocated < i64(3 * len(big)),
		"peak %d",
		track.peak_memory_allocated,
	)
}

@(test)
accessor_allocation_failures_leak_nothing :: proc(t: ^testing.T) {
	composed := tag_file(
		3,
		0,
		frame(3, "TYER", text("\x002019")),
		frame(3, "TDAT", text("\x000305")),
		frame(3, "TIME", text("\x001020")),
		frame(3, "TCON", text("\x00(17)(18)Eurodisco")),
		frame(3, "TXXX", text("\x00comment\x00From ffmpeg")),
		frame(3, "APIC", text("\x00image/png\x00\x04\x00back")),
		frame(3, "APIC", text("\x00image/png\x00\x03\x00front")),
	)
	// Every value given despite a failing allocator is the value an unconstrained one gives.
	for data in ([][]u8{fixture(t, "v24_full.mp3"), fixture(t, "v23_full.mp3"), fixture(t, "v22.mp3"), composed}) {
		tags := read(t, data)
		defer odid3.destroy(&tags)
		for f in odid3.Field {
			want := field(&tags, f)
			succeeded := false
			for budget in 0 ..< 32 {
				failing := Failing{context.allocator, budget}
				allocator := failing_allocator(&failing)
				value, err := odid3.get(&tags, f, allocator)
				if err == nil {
					testing.expectf(
						t,
						value == want,
						"%v at budget %d: %q, want %q",
						f,
						budget,
						value,
						want,
					)
					delete(value, allocator)
					succeeded = true
					break
				}
				testing.expect_value(t, err, mem.Allocator_Error.Out_Of_Memory)
			}
			testing.expectf(t, succeeded, "%v never succeeded", f)
		}
		for budget in 0 ..< 32 {
			failing := Failing{context.allocator, budget}
			allocator := failing_allocator(&failing)
			cover, found, err := odid3.front_cover(&tags.v2, allocator)
			if err == nil {
				odid3.destroy(&cover, allocator)
				break
			}
			testing.expect(t, !found)
		}
		for budget in 0 ..< 32 {
			failing := Failing{context.allocator, budget}
			allocator := failing_allocator(&failing)
			value, found, err := odid3.user_text(&tags.v2, "comment", allocator)
			if err == nil {
				delete(value, allocator)
				break
			}
			testing.expect(t, !found)
		}
		for budget in 0 ..< 32 {
			failing := Failing{context.allocator, budget}
			allocator := failing_allocator(&failing)
			all, err := odid3.pictures(&tags.v2, allocator)
			if err == nil {
				odid3.destroy(&all, allocator)
				break
			}
		}
		for budget in 0 ..< 32 {
			failing := Failing{context.allocator, budget}
			allocator := failing_allocator(&failing)
			all, err := odid3.comments(&tags.v2, allocator)
			if err == nil {
				odid3.destroy(&all, allocator)
				break
			}
		}
	}
}

// Fixtures where ffprobe reads otherwise, and why.
PARITY_EXCEPTIONS :: []struct {
	name, reason: string,
} {
	{"v1_latin1.mp3", "ffmpeg shows ID3v1's Latin-1 bytes as they are, not as UTF-8"},
	{"v1_utf8_cut.mp3", "ffmpeg shows the cut character as U+FFFD"},
	{"v1_utf8_cut_accents.mp3", "ffmpeg shows the cut character as U+FFFD; odid3 drops it"},
	{"v1_enhanced.mp3", "ffmpeg ignores the Enhanced TAG"},
	{"v24_appended.mp3", "ffmpeg ignores appended ID3v2 tags"},
	{"v23_unsync.mp3", "ffmpeg reads ID3v2.3 frame sizes against the unsynchronised bytes"},
	{"v23_compressed.mp3", "ffmpeg skips compressed ID3v2.3 frames"},
	{"v24_itunes.mp3", "ffmpeg reads iTunes' plain frame sizes as syncsafe"},
}

is_parity_exception :: proc(name: string) -> bool {
	for e in PARITY_EXCEPTIONS {
		if e.name == name {
			return true
		}
	}
	return false
}

ffprobe_tags :: proc(t: ^testing.T, name: string) -> (tags: map[string]string, ok: bool) {
	path := strings.concatenate(
		{TESTDATA, "ffprobe/", strings.trim_suffix(name, ".mp3"), ".txt"},
		context.temp_allocator,
	)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return nil, false
	}
	return ffprobe_flat_tags(string(data)), true
}

// The format tags in ffprobe's flat output.
ffprobe_flat_tags :: proc(output: string) -> (tags: map[string]string) {
	tags = make(map[string]string, context.temp_allocator)
	text := output
	for line in strings.split_lines_iterator(&text) {
		prefix :: "format.tags."
		if !strings.has_prefix(line, prefix) {
			continue
		}
		equal := strings.index_byte(line, '=')
		value := strings.trim_prefix(strings.trim_suffix(line[equal + 1:], "\""), "\"")
		tags[line[len(prefix):equal]] = value
	}
	return
}

@(test)
fields_match_ffprobe :: proc(t: ^testing.T) {
	checked := 0
	for name in fixture_names(t) {
		probed, ok := ffprobe_tags(t, name)
		if !ok || is_parity_exception(name) {
			continue
		}
		tags := read(t, fixture(t, name))
		defer odid3.destroy(&tags)
		pair :: proc(tags: ^odid3.Tags, number, total: odid3.Field) -> string {
			n, of := field(tags, number), field(tags, total)
			return of == "" ? n : strings.concatenate({n, "/", of}, context.temp_allocator)
		}
		ours := [?]struct {
			key, value: string,
		} {
			{"title", field(&tags, .Title)},
			{"artist", field(&tags, .Artist)},
			{"album_artist", field(&tags, .Album_Artist)},
			{"album", field(&tags, .Album)},
			{"date", field(&tags, .Date)},
			{"genre", field(&tags, .Genre)},
			{"comment", field(&tags, .Comment)},
			{"track", pair(&tags, .Track, .Track_Total)},
			{"disc", pair(&tags, .Disc, .Disc_Total)},
		}
		for entry in ours {
			key, value := entry.key, entry.value
			theirs := probed[key] or_else ""
			testing.expectf(
				t,
				value == theirs,
				"%s %s: odid3 %q, ffprobe %q",
				name,
				key,
				value,
				theirs,
			)
		}
		checked += 1
	}
	testing.expectf(t, checked >= 20, "only %d fixtures compared", checked)
}
