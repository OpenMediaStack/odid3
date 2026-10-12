package odid3_tests

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
	// false where ffmpeg misreads the file: it reads ID3v2.2 and 2.3 frame sizes against the
	// unsynchronised bytes, and skips compressed ID3v2.3 frames.
	ffprobe:  bool,
}

INTEROP_CASES := []Interop_Case {
	{"v22", .V2_2, {}, nil, true},
	{"v22_unsync", .V2_2, {unsynchronisation = true}, nil, false},
	{"v23", .V2_3, {}, nil, true},
	{"v23_latin1", .V2_3, {}, .Latin1, true},
	{"v23_utf16", .V2_3, {}, .UTF16, true},
	{"v23_unsync", .V2_3, {unsynchronisation = true}, nil, false},
	{"v23_compressed", .V2_3, {compression = true}, nil, false},
	{"v23_no_padding", .V2_3, {padding = 0}, nil, true},
	{"v24", .V2_4, {}, nil, true},
	{"v24_latin1", .V2_4, {}, .Latin1, true},
	{"v24_utf16", .V2_4, {}, .UTF16, true},
	{"v24_utf16be", .V2_4, {}, .UTF16BE, true},
	{"v24_unsync", .V2_4, {unsynchronisation = true}, nil, true},
	{"v24_compressed", .V2_4, {compression = true}, nil, true},
	{"v24_compressed_unsync", .V2_4, {compression = true, unsynchronisation = true}, nil, true},
	{"v24_footer", .V2_4, {footer = true}, nil, true},
}

INTEROP_ARTIST :: "Marlowe Kite"
INTEROP_ALBUM :: "Small Hours"
INTEROP_COMMENT :: "Recorded in one take."

// A title Latin-1 can hold where the encoding asks for it, else one it cannot.
interop_title :: proc(c: Interop_Case) -> string {
	return "Café Noir" if c.encoding == .Latin1 else "Café 坂本"
}

// A picture whose bytes hold false MPEG syncs, for unsynchronisation to protect.
INTEROP_PICTURE := []u8{0x89, 'P', 'N', 'G', 0xFF, 0xE0, 0xFF, 0xFF, 0xFB, 0x00, 0xFF}

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
	tags.v2.version = c.version
	tag := &tags.v2
	errors := [?]odid3.Error {
		odid3.set(tag, .Title, interop_title(c)),
		odid3.set(tag, .Artist, INTEROP_ARTIST),
		odid3.set(tag, .Album, INTEROP_ALBUM),
		odid3.set(tag, .Date, "2019"),
		odid3.set_track(tag, 3, 12),
		odid3.set_disc(tag, 1, 2),
		odid3.set_genres(tag, {"Rock"}),
		odid3.set_comment(tag, INTEROP_COMMENT),
		odid3.set_user_text(tag, "mood", "Calm"),
		odid3.set_picture(tag, {mime = "image/png", type = .Front_Cover, data = INTEROP_PICTURE}),
	}
	for err, i in errors {
		testing.expectf(t, err == nil, "%s: setting value %d: %v", c.name, i, err)
	}
	if encoding, ok := c.encoding.?; ok {
		err := odid3.set_encoding(tag, encoding)
		testing.expectf(t, err == nil, "%s: set_encoding: %v", c.name, err)
	}
	err := odid3.write_file(path, &tags, c.options)
	testing.expectf(t, err == nil, "%s: write_file: %v", c.name, err)
	return err == nil
}

check_with_odid3 :: proc(t: ^testing.T, path: string, c: Interop_Case) {
	tags, err := odid3.read_file(path, {}, context.allocator)
	defer odid3.destroy(&tags)
	testing.expectf(t, err == nil && tags.warnings == {}, "%s: %v %v", c.name, err, tags.warnings)
	testing.expect_value(t, tags.v2.version, c.version)
	testing.expect_value(t, field(&tags, .Title), interop_title(c))
	testing.expect_value(t, field(&tags, .Comment), INTEROP_COMMENT)
}

check_with_ffprobe :: proc(t: ^testing.T, path: string, c: Interop_Case) {
	out, ok := run(
		t,
		"ffprobe",
		"-v",
		"error",
		"-show_entries",
		"format_tags",
		"-of",
		"flat",
		path,
	)
	if !ok {
		return
	}
	probed := ffprobe_flat_tags(out)
	want := [?][2]string {
		{"title", interop_title(c)},
		{"artist", INTEROP_ARTIST},
		{"album", INTEROP_ALBUM},
		{"date", "2019"},
		{"track", "3/12"},
		{"genre", "Rock"},
		{"comment", INTEROP_COMMENT},
	}
	for w in want {
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
	frames := make(map[string]string, context.temp_allocator)
	for line in strings.split_lines_iterator(&out) {
		tab := strings.index_byte(line, '\t')
		if tab >= 0 {
			frames[line[:tab]] = line[tab + 1:]
		}
	}
	version := "2.4.0"
	date := "TDRC"
	switch c.version {
	case .V2_2:
		version, date = "2.2.0", "TYER"
	case .V2_3:
		version, date = "2.3.0", "TYER"
	case .V2_4, .None:
	}
	picture := "PNG 11" if c.version == .V2_2 else "image/png 11"
	want := [?][2]string {
		{"version", version},
		{"TIT2", interop_title(c)},
		{"TPE1", INTEROP_ARTIST},
		{"TALB", INTEROP_ALBUM},
		{date, "2019"},
		{"TRCK", "3/12"},
		{"TPOS", "1/2"},
		{"TCON", "Rock"},
		{"COMM::eng", INTEROP_COMMENT},
		{"TXXX:mood", "Calm"},
		{"APIC:", picture},
	}
	for w in want {
		got := frames[w[0]] or_else ""
		testing.expectf(t, got == w[1], "%s: mutagen %s %q, want %q", c.name, w[0], got, w[1])
	}
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
