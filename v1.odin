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

// What to do with ID3v1 when writing.
V1_Policy :: enum u8 {
	Keep, // rewrite ID3v1 where the file has one, never add one
	Always,
	Never,
}

// The ID3v1 bytes of a tag: 128 bytes, or 355 when it holds an Enhanced TAG, which comes first.
// Text is written in Latin-1, a character outside it as '?', cut to its field.
render_v1 :: proc(
	v1: ^V1_Tag,
	allocator := context.allocator,
) -> (
	bytes: []u8,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	enhanced, has_enhanced := v1.enhanced.?
	size := V1_SIZE + (V1_ENHANCED_SIZE if has_enhanced else 0)
	bytes = make([]u8, size, allocator) or_return
	tag := bytes[size - V1_SIZE:]
	copy(tag, "TAG")
	put_latin1(tag[3:33], v1.title)
	put_latin1(tag[33:63], v1.artist)
	put_latin1(tag[63:93], v1.album)
	put_latin1(tag[93:97], v1.year)
	if v1.version == .V1_1 {
		put_latin1(tag[97:125], v1.comment)
		tag[126] = v1.track
	} else {
		put_latin1(tag[97:127], v1.comment)
	}
	tag[127] = v1.genre
	if has_enhanced {
		e := bytes[:V1_ENHANCED_SIZE]
		copy(e, "TAG+")
		put_latin1(e[4:64], after_characters(v1.title, 30))
		put_latin1(e[64:124], after_characters(v1.artist, 30))
		put_latin1(e[124:184], after_characters(v1.album, 30))
		e[184] = enhanced.speed
		put_latin1(e[185:215], enhanced.genre)
		put_latin1(e[215:221], enhanced.start_time)
		put_latin1(e[221:227], enhanced.end_time)
	}
	return bytes, nil
}

// An ID3v1 tag holding the values of an ID3v2 tag, and the fields that do not fit: text longer than
// its field (30 characters, 28 for the comment of ID3v1.1, 90 with the Enhanced TAG), characters
// outside Latin-1, a date that is more than a year, a track that is not a number from 1 to 255, a
// genre missing from the ID3v1 table (unless the Enhanced TAG holds it). Fields ID3v1 has no room for
// at all (album artist, totals, disc) are not reported. Free the tag with destroy.
v1_from_tag :: proc(
	tag: ^Tag,
	version: V1_Version,
	enhanced := false,
	allocator := context.allocator,
) -> (
	v1: V1_Tag,
	overflow: Fields,
	err: runtime.Allocator_Error,
) {
	tags := Tags {
		v2 = tag^,
	}
	return v1_from_tags(&tags, version, enhanced, allocator)
}

// Like v1_from_tag, from the fields of a file: those of its ID3v2 tag, else those of its ID3v1 tag,
// whose genre number and Enhanced TAG details are kept.
@(private)
v1_from_tags :: proc(
	tags: ^Tags,
	version: V1_Version,
	enhanced: bool,
	allocator: runtime.Allocator,
) -> (
	v1: V1_Tag,
	overflow: Fields,
	err: runtime.Allocator_Error,
) {
	v1 = {
		version   = version,
		genre     = 255,
		allocator = allocator,
	}
	if version == .None {
		return
	}
	defer if err != nil {
		destroy_v1(&v1)
	}
	long := 90 if enhanced else 30
	v1.title = get_file_field(tags, .Title, allocator) or_return
	v1.artist = get_file_field(tags, .Artist, allocator) or_return
	v1.album = get_file_field(tags, .Album, allocator) or_return
	v1.comment = get_file_field(tags, .Comment, allocator) or_return
	comment_limit := 28 if version == .V1_1 else 30
	texts := [?]struct {
		field: Field,
		value: string,
		limit: int,
	} {
		{.Title, v1.title, long},
		{.Artist, v1.artist, long},
		{.Album, v1.album, long},
		{.Comment, v1.comment, comment_limit},
	}
	for text in texts {
		if !fits_latin1(text.value, text.limit) {
			overflow += {text.field}
		}
	}

	date := get_file_field(tags, .Date, allocator) or_return
	defer delete(date, allocator)
	if len(date) >= 4 && is_number(date[:4]) {
		v1.year = strings.clone(date[:4], allocator) or_return
	}
	if date != v1.year {
		overflow += {.Date}
	}

	track_text := get_file_field(tags, .Track, allocator) or_return
	defer delete(track_text, allocator)
	number, _ := parse_number(track_text)
	if version == .V1_1 && number >= 1 && number <= 255 {
		v1.track = u8(number)
	} else if track_text != "" {
		overflow += {.Track}
	}

	e: V1_Enhanced
	if old, ok := tags.v1.enhanced.?; ok && tags.v1.version != .None {
		e.speed = old.speed
		e.start_time = strings.clone(old.start_time, allocator) or_return
		v1.enhanced = e
		e.end_time = strings.clone(old.end_time, allocator) or_return
		v1.enhanced = e
	}
	names := genres(&tags.v2, allocator) or_return
	defer destroy_strings(&names, allocator)
	if len(names) > 0 {
		index, known := genre_index(names[0])
		if known {
			v1.genre = index
		} else if enhanced && fits_latin1(names[0], 30) {
			e.genre = strings.clone(names[0], allocator) or_return
			v1.enhanced = e
		} else {
			overflow += {.Genre}
		}
		if len(names) > 1 {
			overflow += {.Genre}
		}
	} else if tags.v1.version != .None {
		v1.genre = tags.v1.genre
		if old, ok := tags.v1.enhanced.?; ok && enhanced {
			e.genre = strings.clone(old.genre, allocator) or_return
			v1.enhanced = e
		}
	}
	needs_enhanced :=
		!fits_latin1(v1.title, 30) || !fits_latin1(v1.artist, 30) || !fits_latin1(v1.album, 30)
	if !enhanced {
		if e, ok := &v1.enhanced.?; ok {
			destroy_v1_enhanced(e, allocator)
		}
		v1.enhanced = nil
	} else if needs_enhanced && v1.enhanced == nil {
		v1.enhanced = e
	}
	return
}

// Rebuilds tags.v1 from the file's fields (ID3v2, else ID3v1) following the policy, and returns the
// fields that do not fit (see v1_from_tag). A nil version means ID3v1.1 when the track is a number from 1 to 255, else ID3v1.0.
// A nil enhanced keeps the Enhanced TAG when the file has one.
sync_v1 :: proc(
	tags: ^Tags,
	policy: V1_Policy,
	version: Maybe(V1_Version) = nil,
	enhanced: Maybe(bool) = nil,
) -> (
	overflow: Fields,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	allocator := tags.v1.allocator if tags.v1.version != .None else tags.v2.allocator
	if allocator.procedure == nil {
		allocator = context.allocator
	}
	switch policy {
	case .Never:
		destroy_v1(&tags.v1)
		return
	case .Keep:
		if tags.v1.version == .None {
			return
		}
	case .Always:
	}
	chosen, has_version := version.?
	if !has_version {
		track_text := get_file_field(tags, .Track, allocator) or_return
		number, _ := parse_number(track_text)
		delete(track_text, allocator)
		chosen = .V1_1 if number >= 1 && number <= 255 else .V1_0
	}
	with_enhanced := enhanced.? or_else (tags.v1.enhanced != nil)
	v1: V1_Tag
	v1, overflow = v1_from_tags(tags, chosen, with_enhanced, allocator) or_return
	destroy_v1(&tags.v1)
	tags.v1 = v1
	return
}

@(private)
put_latin1 :: proc(field: []u8, s: string) {
	i := 0
	for r in s {
		if i >= len(field) {
			break
		}
		field[i] = '?' if r > 0xFF || r == utf8.RUNE_ERROR else u8(r)
		i += 1
	}
}

// What follows the first n characters of s.
@(private)
after_characters :: proc(s: string, n: int) -> string {
	count := 0
	for _, i in s {
		if count == n {
			return s[i:]
		}
		count += 1
	}
	return ""
}

@(private)
fits_latin1 :: proc(s: string, limit: int) -> bool {
	count := 0
	for r in s {
		if r > 0xFF || r == utf8.RUNE_ERROR {
			return false
		}
		count += 1
	}
	return count <= limit
}
