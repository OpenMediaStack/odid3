package odid3

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

// The version of an ID3v1 tag. None means there is no tag.
V1_Version :: enum u8 {
	None,
	V1_0,
	V1_1,
}

// An ID3v1 tag: the last 128 bytes of a file, its text decoded to UTF-8. Free it with destroy.
V1_Tag :: struct {
	version:   V1_Version,
	title:     string, // 30 characters, 90 with the Enhanced TAG
	artist:    string, // the same
	album:     string, // the same
	year:      string, // 4 characters
	comment:   string, // 30 characters, 28 in ID3v1.1
	track:     u8, // ID3v1.1 only, 0 when absent
	genre:     u8, // see genre_name; 255 when absent
	enhanced:  Maybe(V1_Enhanced),
	allocator: runtime.Allocator,
}

// The Enhanced TAG ("TAG+"), which some players write before ID3v1. Its title, artist and album
// continue those of ID3v1; its strings are freed with the V1_Tag that holds it.
V1_Enhanced :: struct {
	speed:      u8, // 0 unset, 1 slow, 2 medium, 3 fast, 4 hardcore
	genre:      string, // free text
	start_time: string, // "mmm:ss"
	end_time:   string, // "mmm:ss"
}

@(private)
V1_SIZE :: 128
@(private)
V1_ENHANCED_SIZE :: 227

// ID3v1.1 takes the last two bytes of the comment for a zero and the track number.
@(private)
v1_version :: proc(tag: []u8) -> V1_Version {
	if len(tag) < V1_SIZE {
		return .None
	}
	if tag[125] == 0 && tag[126] != 0 {
		return .V1_1
	}
	return .V1_0
}

@(private)
decode_v1 :: proc(tag, enhanced: []u8, allocator: runtime.Allocator) -> (v1: V1_Tag, err: Error) {
	v1.version = v1_version(tag)
	if v1.version == .None {
		return
	}
	v1.allocator = allocator
	defer if err != nil {
		destroy_v1(&v1)
	}
	more_title, more_artist, more_album: []u8
	has_enhanced := len(enhanced) == V1_ENHANCED_SIZE
	if has_enhanced {
		more_title, more_artist, more_album = enhanced[4:64], enhanced[64:124], enhanced[124:184]
	}
	v1.title = decode_v1_long_text(tag[3:33], more_title, allocator) or_return
	v1.artist = decode_v1_long_text(tag[33:63], more_artist, allocator) or_return
	v1.album = decode_v1_long_text(tag[63:93], more_album, allocator) or_return
	v1.year = decode_v1_text(tag[93:97], allocator) or_return
	if v1.version == .V1_1 {
		v1.comment = decode_v1_text(tag[97:125], allocator) or_return
		v1.track = tag[126]
	} else {
		v1.comment = decode_v1_text(tag[97:127], allocator) or_return
	}
	v1.genre = tag[127]
	if has_enhanced {
		v1.enhanced = decode_v1_enhanced(enhanced, allocator) or_return
	}
	return
}

@(private)
decode_v1_enhanced :: proc(
	enhanced: []u8,
	allocator: runtime.Allocator,
) -> (
	e: V1_Enhanced,
	err: Error,
) {
	defer if err != nil {
		destroy_v1_enhanced(&e, allocator)
	}
	e.speed = enhanced[184]
	e.genre = decode_v1_text(enhanced[185:215], allocator) or_return
	e.start_time = decode_v1_text(enhanced[215:221], allocator) or_return
	e.end_time = decode_v1_text(enhanced[221:227], allocator) or_return
	return
}

// A field of ID3v1 continued by the Enhanced TAG: the continuation only counts when the ID3v1
// field is full.
@(private)
decode_v1_long_text :: proc(
	field, continuation: []u8,
	allocator: runtime.Allocator,
) -> (
	s: string,
	err: Error,
) {
	buf: [90]u8
	text := cut_at_nul(field)
	n := copy(buf[:], text)
	if len(text) == len(field) {
		n += copy(buf[n:], cut_at_nul(continuation))
	}
	return decode_v1_text(buf[:n], allocator)
}

// ID3v1 text is Latin-1 by the spec, but some taggers (ffmpeg among them) write UTF-8: valid UTF-8
// with bytes above 0x7F is read as UTF-8, anything else as Latin-1. Those taggers cut at 30 bytes,
// sometimes inside a character: when only that last character is broken and what comes before is
// UTF-8 with bytes above 0x7F, the broken character is dropped.
@(private)
decode_v1_text :: proc(field: []u8, allocator: runtime.Allocator) -> (s: string, err: Error) {
	text := strings.trim_right(string(cut_at_nul(field)), " ")
	if !is_ascii(text) {
		if utf8.valid_string(text) {
			return strings.clone(text, allocator)
		}
		before_cut := without_cut_character(text)
		if !is_ascii(before_cut) && utf8.valid_string(before_cut) {
			return strings.clone(before_cut, allocator)
		}
	}
	return decode_latin1(transmute([]u8)text, allocator)
}

// text without the start of a UTF-8 character it ends with, if it ends with one.
@(private)
without_cut_character :: proc(text: string) -> string {
	for back in 1 ..= min(3, len(text)) {
		start := len(text) - back
		if utf8.rune_start(text[start]) {
			if text[start] >= 0xC0 && !utf8.full_rune_in_string(text[start:]) {
				return text[:start]
			}
			break
		}
	}
	return text
}

@(private)
cut_at_nul :: proc(b: []u8) -> []u8 {
	for c, i in b {
		if c == 0 {
			return b[:i]
		}
	}
	return b
}

// Frees the text of an ID3v1 tag and resets it.
destroy_v1 :: proc(v1: ^V1_Tag) {
	delete(v1.title, v1.allocator)
	delete(v1.artist, v1.allocator)
	delete(v1.album, v1.allocator)
	delete(v1.year, v1.allocator)
	delete(v1.comment, v1.allocator)
	if e, ok := &v1.enhanced.?; ok {
		destroy_v1_enhanced(e, v1.allocator)
	}
	v1^ = {}
}

@(private)
destroy_v1_enhanced :: proc(e: ^V1_Enhanced, allocator: runtime.Allocator) {
	delete(e.genre, allocator)
	delete(e.start_time, allocator)
	delete(e.end_time, allocator)
}
