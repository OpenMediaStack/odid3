package odid3_tests

import "core:bytes"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import odid3 "../"

// The interoperability tests need ffprobe and mutagen, so they only run when asked:
// odin test tests -define:ODID3_INTEROP=true [-define:ODID3_PYTHON=path/to/python3]
ODID3_INTEROP :: #config(ODID3_INTEROP, false)
ODID3_PYTHON :: #config(ODID3_PYTHON, "python3")

Interop_Case :: struct {
	name:     string,
	version:  odid3.V2_Version,
	options:  odid3.Write_Options,
	encoding: Maybe(odid3.Encoding),
	v1:       odid3.V1_Version,
	// false where ffmpeg misreads the file: it reads ID3v2.2 and 2.3 frame sizes against the
	// unsynchronised bytes, and reads compressed ID3v2.3 frames as if they were not compressed.
	ffprobe:  bool,
}

INTEROP_CASES := []Interop_Case {
	{"v22", .V2_2, {}, nil, .None, true},
	{"v22_unsync", .V2_2, {unsynchronisation = true}, nil, .None, false},
	{"v23", .V2_3, {}, nil, .None, true},
	{"v23_latin1", .V2_3, {}, .Latin1, .None, true},
	{"v23_utf16", .V2_3, {}, .UTF16, .None, true},
	{"v23_utf16_option", .V2_3, {encoding = .UTF16}, nil, .None, true},
	{"v23_unsync", .V2_3, {unsynchronisation = true}, nil, .None, false},
	{"v23_compressed", .V2_3, {compression = true}, nil, .None, false},
	{"v23_no_padding", .V2_3, {padding = 0}, nil, .None, true},
	{"v23_v1_0", .V2_3, {}, nil, .V1_0, true},
	{"v24", .V2_4, {}, nil, .None, true},
	{"v24_latin1", .V2_4, {}, .Latin1, .None, true},
	{"v24_utf16", .V2_4, {}, .UTF16, .None, true},
	{"v24_utf16be", .V2_4, {}, .UTF16BE, .None, true},
	{"v24_utf16be_option", .V2_4, {encoding = .UTF16BE}, nil, .None, true},
	{"v24_unsync", .V2_4, {unsynchronisation = true}, nil, .None, true},
	{"v24_compressed", .V2_4, {compression = true}, nil, .None, true},
	{
		"v24_compressed_unsync",
		.V2_4,
		{compression = true, unsynchronisation = true},
		nil,
		.None,
		true,
	},
	{"v24_footer", .V2_4, {footer = true}, nil, .None, true},
	{
		"v24_footer_compressed_unsync",
		.V2_4,
		{footer = true, compression = true, unsynchronisation = true},
		nil,
		.None,
		true,
	},
	{"v24_v1_1", .V2_4, {}, nil, .V1_1, true},
	{"v1_0", .None, {}, nil, .V1_0, true},
	{"v1_1", .None, {}, nil, .V1_1, true},
	{"v1_1_utf8", .None, {v1_encoding = .UTF8}, nil, .V1_1, true},
}

INTEROP_ARTIST :: "Marlowe Kite"
INTEROP_ALBUM :: "Small Hours"
INTEROP_DATE :: "2019-05-04T12:30"
INTEROP_COMMENT :: "Recorded in one take."
INTEROP_CHAPTER :: "Chapter one"

// A title Latin-1 can hold where the case needs one, else one it cannot.
interop_title :: proc(c: Interop_Case) -> string {
	latin1 := c.encoding == .Latin1 || c.v1 != .None && !interop_v1_utf8(c)
	return "Café Noir" if latin1 else "Café 坂本"
}

interop_v1_utf8 :: proc(c: Interop_Case) -> bool {
	encoding, asked := c.options.v1_encoding.?
	return asked && encoding == .UTF8
}

// UTF-8 read as Latin-1, as mutagen reads ID3v1.
as_latin1 :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		strings.write_rune(&b, rune(c))
	}
	return strings.to_string(b)
}

// A picture whose bytes hold false MPEG syncs and a 0xFF 0x00 pair, which unsynchronisation must
// escape, and a block repeated 30000 bytes later, which a compressed frame can only shrink with
// back-references.
interop_picture :: proc() -> []u8 {
	block := make([]u8, 30000, context.temp_allocator)
	state: u32 = 1
	for &b in block {
		state = state * 1103515245 + 12345
		b = u8(state >> 16)
	}
	return concat({0x89, 'P', 'N', 'G', 0xFF, 0xE0, 0xFF, 0xFF, 0xFB, 0xFF, 0x00}, block, block)
}

// The text encoding odid3 gives a frame: the one the case asks for, else the picture's own
// (Latin-1), else UTF-8 in ID3v2.4, else Latin-1 when the text fits.
interop_encoding :: proc(c: Interop_Case, id: string) -> odid3.Encoding {
	if encoding, ok := c.encoding.?; ok {
		return encoding
	}
	if encoding, ok := c.options.encoding.?; ok {
		return encoding
	}
	if id == "APIC" || id == "PIC" {
		return .Latin1
	}
	if c.version == .V2_4 {
		return .UTF8
	}
	if id == "TIT2" || id == "TT2" {
		for r in interop_title(c) {
			if r > 0xFF {
				return .UTF16
			}
		}
	}
	return .Latin1
}

@(test)
files_written_are_read_by_ffprobe_and_mutagen :: proc(t: ^testing.T) {
	if !ODID3_INTEROP {
		log.info("skipped: run with -define:ODID3_INTEROP=true")
		return
	}
	dir := make_temp_dir(t)
	for c in INTEROP_CASES {
		path := join(dir, strings.concatenate({c.name, ".mp3"}, context.temp_allocator))
		if !write_interop_file(t, path, c) {
			continue
		}
		check_with_odid3(t, path, c)
		if c.ffprobe {
			check_with_ffprobe(t, path, c)
		}
		check_with_mutagen(t, path, c)
	}
}

write_interop_file :: proc(t: ^testing.T, path: string, c: Interop_Case) -> bool {
	audio := fixture(t, "no_tag.mp3")
	if os.write_entire_file(path, audio) != nil {
		testing.fail_now(t, "cannot write the audio")
	}
	tags := read(t, audio)
	defer odid3.destroy(&tags)
	tag := &tags.v2
	// ID3v1 takes its values from the ID3v2 tag, which a case without one removes afterwards.
	tag.version = c.version if c.version != .None else .V2_4
	picture := odid3.Picture {
		mime = "image/png",
		type = .Front_Cover,
		data = interop_picture(),
	}
	errors := [?]odid3.Error {
		odid3.set(tag, .Title, interop_title(c)),
		odid3.set(tag, .Artist, INTEROP_ARTIST),
		odid3.set(tag, .Album, INTEROP_ALBUM),
		odid3.set(tag, .Date, INTEROP_DATE),
		odid3.set_track(tag, 3, 12),
		odid3.set_disc(tag, 1, 2),
		odid3.set_genres(tag, {"Rock"}),
		odid3.set_comment(tag, INTEROP_COMMENT),
		odid3.set_user_text(tag, "mood", "Calm"),
		odid3.set_picture(tag, picture),
	}
	for err, i in errors {
		testing.expectf(t, err == nil, "%s: setting value %d: %v", c.name, i, err)
	}
	if c.version == .V2_3 || c.version == .V2_4 {
		add_interop_chapter(t, tag)
	}
	if encoding, ok := c.encoding.?; ok {
		err := odid3.set_encoding(tag, encoding)
		testing.expectf(t, err == nil, "%s: set_encoding: %v", c.name, err)
	}
	if c.v1 != .None {
		// ID3v1 holds the year of the date, and ID3v1.0 no track.
		cut := odid3.Fields{.Date} if c.v1 == .V1_1 else {.Date, .Track}
		overflow, err := odid3.sync_v1(&tags, .Always, c.v1, nil, c.options.v1_encoding)
		testing.expectf(
			t,
			overflow == cut && err == nil,
			"%s: sync_v1: %v %v",
			c.name,
			overflow,
			err,
		)
	}
	tag.version = c.version
	err := odid3.write_file(path, &tags, c.options)
	testing.expectf(t, err == nil, "%s: write_file: %v", c.name, err)
	return err == nil
}

// A table of contents and one chapter, with its own title.
add_interop_chapter :: proc(t: ^testing.T, tag: ^odid3.Tag) {
	title, title_err := odid3.encode_frame(
		odid3.Text{.Latin1, {INTEROP_CHAPTER}},
		"TIT2",
		tag.version,
		context.temp_allocator,
	)
	frames := make([dynamic]odid3.Frame, context.temp_allocator)
	append(&frames, title)
	chapter := odid3.Chapter {
		element_id   = "ch0",
		end_ms       = 1000,
		start_offset = max(u32),
		end_offset   = max(u32),
		frames       = frames,
	}
	toc := odid3.Table_Of_Contents {
		element_id = "toc",
		top_level  = true,
		ordered    = true,
		children   = {"ch0"},
	}
	toc_frame, toc_err := odid3.encode_frame(toc, "CTOC", tag.version)
	chapter_frame, chapter_err := odid3.encode_frame(chapter, "CHAP", tag.version)
	testing.expectf(t, title_err == nil && toc_err == nil && chapter_err == nil, "chapter")
	odid3.add_frame(tag, toc_frame)
	odid3.add_frame(tag, chapter_frame)
}

check_with_odid3 :: proc(t: ^testing.T, path: string, c: Interop_Case) {
	tags, err := odid3.read_file(path, {}, context.allocator)
	defer odid3.destroy(&tags)
	testing.expectf(t, err == nil && tags.warnings == {}, "%s: %v %v", c.name, err, tags.warnings)
	testing.expect_value(t, tags.v2.version, c.version)
	testing.expect_value(t, tags.v1.version, c.v1)

	title := interop_title(c)
	want := #partial [odid3.Field]string {
		.Title       = title,
		.Artist      = INTEROP_ARTIST,
		.Album       = INTEROP_ALBUM,
		.Date        = INTEROP_DATE,
		.Track       = "3",
		.Track_Total = "12",
		.Disc        = "1",
		.Disc_Total  = "2",
		.Genre       = "Rock",
		.Comment     = INTEROP_COMMENT,
	}
	if c.version == .None {
		want[.Date] = "2019"
		want[.Track] = "3" if c.v1 == .V1_1 else ""
		want[.Track_Total], want[.Disc], want[.Disc_Total] = "", "", ""
	}
	for f in odid3.Field {
		got := field(&tags, f)
		testing.expectf(t, got == want[f], "%s: %v %q, want %q", c.name, f, got, want[f])
	}
	if c.v1 != .None {
		v1 := tags.v1
		testing.expectf(
			t,
			v1.title == title && v1.artist == INTEROP_ARTIST && v1.album == INTEROP_ALBUM,
			"%s: ID3v1 %v",
			c.name,
			v1,
		)
		testing.expectf(
			t,
			v1.year == "2019" && v1.comment == INTEROP_COMMENT && v1.genre == 17,
			"%s: ID3v1 %v",
			c.name,
			v1,
		)
		testing.expect_value(t, v1.track, u8(3) if c.v1 == .V1_1 else 0)
		testing.expect_value(t, v1.encoding, c.options.v1_encoding.? or_else .Latin1)
	}
	if c.version != .None {
		check_v2_with_odid3(t, &tags.v2, c)
	}
}

// The options and the encoding of the case show in the tag read back.
check_v2_with_odid3 :: proc(t: ^testing.T, tag: ^odid3.Tag, c: Interop_Case) {
	unsync := c.options.unsynchronisation
	testing.expectf(t, (.Unsynchronisation in tag.flags) == unsync, "%s: %v", c.name, tag.flags)
	testing.expectf(t, (.Footer in tag.flags) == c.options.footer, "%s: %v", c.name, tag.flags)
	padding := 0 if c.options.footer else c.options.padding.? or_else odid3.DEFAULT_PADDING
	testing.expectf(t, tag.padding == padding, "%s: padding %d", c.name, tag.padding)

	mood, has_mood, _ := odid3.user_text(tag, "mood", context.temp_allocator)
	testing.expectf(t, has_mood && mood == "Calm", "%s: mood %q", c.name, mood)
	cover, has_cover, _ := odid3.front_cover(tag, context.temp_allocator)
	testing.expectf(
		t,
		has_cover && cover.mime == "image/png" && bytes.equal(cover.data, interop_picture()),
		"%s: the picture changed",
		c.name,
	)

	for &f in tag.frames {
		compressed := c.options.compression && f.id != "CHAP" && f.id != "CTOC"
		testing.expectf(t, (.Compression in f.format) == compressed, "%s: %s", c.name, f.id)
		if c.version == .V2_4 {
			testing.expectf(t, (.Unsynchronisation in f.format) == unsync, "%s: %s", c.name, f.id)
		}
		content, err := odid3.decode_frame(&f, tag.version, context.temp_allocator)
		testing.expectf(t, err == nil, "%s: %s: %v", c.name, f.id, err)
		encoding: Maybe(odid3.Encoding)
		#partial switch v in content {
		case odid3.Text:
			encoding = v.encoding
		case odid3.User_Text:
			encoding = v.encoding
		case odid3.Comment:
			encoding = v.encoding
		case odid3.Picture:
			encoding = v.encoding
		}
		if got, ok := encoding.?; ok {
			want := interop_encoding(c, f.id)
			testing.expectf(t, got == want, "%s: %s in %v, want %v", c.name, f.id, got, want)
		}
	}
}

check_with_ffprobe :: proc(t: ^testing.T, path: string, c: Interop_Case) {
	out, ok := run(
		t,
		"ffprobe",
		"-v",
		"error",
		"-show_entries",
		"format_tags:chapter=start_time,end_time:chapter_tags",
		"-of",
		"flat",
		path,
	)
	if !ok {
		return
	}
	// ffmpeg joins ID3v2.2 and 2.3 dates into one, and keeps TPA under its own name.
	date := "2019-05-04T12:30" if c.version == .V2_4 else "2019-05-04 12:30"
	track, disc, mood := "3/12", ("1/2" if c.version != .V2_2 else ""), "Calm"
	if c.version == .None {
		date, disc, mood = "2019", "", ""
		track = "3" if c.v1 == .V1_1 else ""
	}
	chaptered := c.version == .V2_3 || c.version == .V2_4
	want := [?][2]string {
		{"format.tags.title", interop_title(c)},
		{"format.tags.artist", INTEROP_ARTIST},
		{"format.tags.album", INTEROP_ALBUM},
		{"format.tags.date", date},
		{"format.tags.track", track},
		{"format.tags.disc", disc},
		{"format.tags.genre", "Rock"},
		{"format.tags.comment", INTEROP_COMMENT},
		{"format.tags.mood", mood},
		{"chapters.chapter.0.start_time", "0.000000" if chaptered else ""},
		{"chapters.chapter.0.end_time", "1.000000" if chaptered else ""},
		{"chapters.chapter.0.tags.title", INTEROP_CHAPTER if chaptered else ""},
	}
	probed := ffprobe_flat(out)
	for w in want {
		// ffmpeg takes ID3v1 text for UTF-8, so a Latin-1 title does not come out as written.
		if c.version == .None && w[0] == "format.tags.title" && !interop_v1_utf8(c) {
			continue
		}
		got := probed[w[0]] or_else ""
		testing.expectf(t, got == w[1], "%s: ffprobe %s %q, want %q", c.name, w[0], got, w[1])
	}
}

check_with_mutagen :: proc(t: ^testing.T, path: string, c: Interop_Case) {
	script := strings.concatenate({#directory, "/mutagen_dump.py"}, context.temp_allocator)
	out, ok := run(t, ODID3_PYTHON, script, path)
	if !ok {
		return
	}
	// The value of each key, after its text encoding ("-" for none).
	printed := make(map[string][2]string, context.temp_allocator)
	for line in strings.split_lines_iterator(&out) {
		parts := strings.split_n(line, "\t", 3, context.temp_allocator)
		testing.expectf(t, len(parts) == 3, "%s: mutagen printed %q", c.name, line)
		if len(parts) == 3 {
			printed[parts[0]] = {parts[1], parts[2]}
		}
	}
	want := mutagen_frames(c)
	for key, w in want {
		got := printed[key] or_else [2]string{"", "missing"}
		testing.expectf(t, got == w, "%s: mutagen %s %q, want %q", c.name, key, got, w)
	}
	for key in printed {
		testing.expectf(t, key in want, "%s: mutagen also reads %s", c.name, key)
	}
}

// What mutagen_dump.py prints for the file of a case: its encoding and value by key.
mutagen_frames :: proc(c: Interop_Case) -> (want: map[string][2]string) {
	want = make(map[string][2]string, context.temp_allocator)
	title := interop_title(c)
	if c.version == .None {
		want["version"] = {"-", "1.1"}
		want["unsynchronisation"] = {"-", "False"}
		texts := [?][2]string {
			{"TIT2", as_latin1(title) if interop_v1_utf8(c) else title},
			{"TPE1", INTEROP_ARTIST},
			{"TALB", INTEROP_ALBUM},
			{"TDRC", "2019"},
			{"TCON", "17"}, // mutagen gives ID3v1's genre as its number
			{"COMM:ID3v1 Comment:eng", INTEROP_COMMENT},
		}
		for text in texts {
			want[text[0]] = {"0", text[1]}
		}
		if c.v1 == .V1_1 {
			want["TRCK"] = {"0", "3"}
		}
		return
	}
	encoding :: proc(c: Interop_Case, id: string) -> string {
		return fmt.tprint(int(interop_encoding(c, id)))
	}
	switch c.version {
	case .V2_2:
		want["version"] = {"-", "2.2.0"}
	case .V2_3:
		want["version"] = {"-", "2.3.0"}
	case .V2_4, .None:
		want["version"] = {"-", "2.4.0"}
	}
	want["unsynchronisation"] = {"-", "True" if c.options.unsynchronisation else "False"}
	texts := [?][2]string {
		{"TIT2", title},
		{"TPE1", INTEROP_ARTIST},
		{"TALB", INTEROP_ALBUM},
		{"TRCK", "3/12"},
		{"TPOS", "1/2"},
		{"TCON", "Rock"},
		{"COMM::eng", INTEROP_COMMENT},
		{"TXXX:mood", "Calm"},
	}
	for text in texts {
		want[text[0]] = {encoding(c, text[0]), text[1]}
	}
	if c.version == .V2_4 {
		want["TDRC"] = {encoding(c, "TDRC"), "2019-05-04 12:30"}
	} else {
		want["TYER"] = {encoding(c, "TYER"), "2019"}
		want["TDAT"] = {encoding(c, "TDAT"), "0405"}
		want["TIME"] = {encoding(c, "TIME"), "1230"}
	}
	picture := interop_picture()
	want["APIC:"] = {
		encoding(c, "APIC"),
		fmt.tprintf(
			"%s 3 %d %08x",
			"PNG" if c.version == .V2_2 else "image/png",
			len(picture),
			hash.crc32(picture),
		),
	}
	if c.version != .V2_2 {
		want["CHAP:ch0"] = {
			"-",
			"CHAP=ch0 time=0..1000 offset=4294967295..4294967295 TIT2=" + INTEROP_CHAPTER,
		}
		want["CTOC:toc"] = {"-", "CTOC=toc flags=3 child_element_ids=ch0"}
	}
	if c.v1 != .None {
		// mutagen adds the ID3v1 comment, under its own description, to the ID3v2 frames.
		want["COMM:ID3v1 Comment:eng"] = {"0", INTEROP_COMMENT}
	}
	return
}

// Runs a command and returns what it printed, or fails the test.
run :: proc(t: ^testing.T, command: ..string) -> (stdout: string, ok: bool) {
	state, out, errors, err := os.process_exec({command = command}, context.temp_allocator)
	if err != nil || !state.exited || state.exit_code != 0 {
		testing.expectf(
			t,
			false,
			"%v: %v, exit code %d: %s",
			command,
			err,
			state.exit_code,
			errors,
		)
		return "", false
	}
	return string(out), true
}
