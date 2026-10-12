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

// An ID3v1 tag: the last 128 bytes of a file, its text decoded to UTF-8. Free it with destroy. A
// tag built by hand sets genre to 255 for none: 0 is Blues. The limits below count characters in
// Latin-1, bytes in UTF-8.
V1_Tag :: struct {
	version:   V1_Version,
	title:     string, // 30, 90 with the Enhanced TAG
	artist:    string, // the same
	album:     string, // the same
	year:      string, // 4
	comment:   string, // 30, 28 in ID3v1.1
	track:     u8, // ID3v1.1 only, 0 when absent
	genre:     u8, // see genre_name; 255 when absent
	enhanced:  Maybe(V1_Enhanced),
	encoding:  V1_Encoding, // how render_v1 writes it; see V1_Encoding
	allocator: runtime.Allocator,
}

// The text encoding of an ID3v1 tag. The spec gives Latin-1; some taggers, ffmpeg among them, write
// UTF-8. A tag read is UTF8 when its text was read as UTF-8, unless other fields were read as
// Latin-1 and every field fits Latin-1.
V1_Encoding :: enum u8 {
	Latin1,
	UTF8,
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
	seen: bit_set[V1_Encoding]
	v1.title = decode_v1_long_text(tag[3:33], more_title, &seen, allocator) or_return
	v1.artist = decode_v1_long_text(tag[33:63], more_artist, &seen, allocator) or_return
	v1.album = decode_v1_long_text(tag[63:93], more_album, &seen, allocator) or_return
	v1.year = decode_v1_text(tag[93:97], &seen, allocator) or_return
	if v1.version == .V1_1 {
		v1.comment = decode_v1_text(tag[97:125], &seen, allocator) or_return
		v1.track = tag[126]
	} else {
		v1.comment = decode_v1_text(tag[97:127], &seen, allocator) or_return
	}
	v1.genre = tag[127]
	if has_enhanced {
		v1.enhanced = decode_v1_enhanced(enhanced, &seen, allocator) or_return
	}
	if .UTF8 in seen {
		v1.encoding = .UTF8
		// Taggers of both kinds edited this tag: Latin-1 keeps every field when they all fit it.
		if .Latin1 in seen && v1_fits_latin1(&v1) {
			v1.encoding = .Latin1
		}
	}
	return
}

@(private)
decode_v1_enhanced :: proc(
	enhanced: []u8,
	seen: ^bit_set[V1_Encoding],
	allocator: runtime.Allocator,
) -> (
	e: V1_Enhanced,
	err: Error,
) {
	defer if err != nil {
		destroy_v1_enhanced(&e, allocator)
	}
	e.speed = enhanced[184]
	e.genre = decode_v1_text(enhanced[185:215], seen, allocator) or_return
	e.start_time = decode_v1_text(enhanced[215:221], seen, allocator) or_return
	e.end_time = decode_v1_text(enhanced[221:227], seen, allocator) or_return
	return
}

// A field of ID3v1 continued by the Enhanced TAG: the continuation only counts when the ID3v1
// field is full.
@(private)
decode_v1_long_text :: proc(
	field, continuation: []u8,
	seen: ^bit_set[V1_Encoding],
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
	return decode_v1_text(buf[:n], seen, allocator)
}

// ID3v1 text is Latin-1 by the spec, but some taggers (ffmpeg among them) write UTF-8: valid UTF-8
// with bytes above 0x7F is read as UTF-8, anything else as Latin-1. Those taggers cut at 30 bytes,
// sometimes inside a character: when only that last character is broken and what comes before is
// UTF-8 with bytes above 0x7F, the broken character is dropped. seen gets the encoding text beyond
// ASCII was read in.
@(private)
decode_v1_text :: proc(
	field: []u8,
	seen: ^bit_set[V1_Encoding],
	allocator: runtime.Allocator,
) -> (
	s: string,
	err: Error,
) {
	text := strings.trim_right(string(cut_at_nul(field)), " ")
	if !is_ascii(text) {
		read := text if utf8.valid_string(text) else without_cut_character(text)
		if !is_ascii(read) && utf8.valid_string(read) {
			seen^ += {.UTF8}
			return strings.clone(read, allocator)
		}
		seen^ += {.Latin1}
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
clone_v1 :: proc(v1: ^V1_Tag, allocator: runtime.Allocator) -> (duplicate: V1_Tag, err: Error) {
	duplicate = {
		version   = v1.version,
		track     = v1.track,
		genre     = v1.genre,
		encoding  = v1.encoding,
		allocator = allocator,
	}
	defer if err != nil {
		destroy_v1(&duplicate)
	}
	duplicate.title = strings.clone(v1.title, allocator) or_return
	duplicate.artist = strings.clone(v1.artist, allocator) or_return
	duplicate.album = strings.clone(v1.album, allocator) or_return
	duplicate.year = strings.clone(v1.year, allocator) or_return
	duplicate.comment = strings.clone(v1.comment, allocator) or_return
	if e, ok := v1.enhanced.?; ok {
		duplicate.enhanced = V1_Enhanced {
			speed = e.speed,
		}
		d := &duplicate.enhanced.?
		d.genre = strings.clone(e.genre, allocator) or_return
		d.start_time = strings.clone(e.start_time, allocator) or_return
		d.end_time = strings.clone(e.end_time, allocator) or_return
	}
	return
}

@(private)
destroy_v1_enhanced :: proc(e: ^V1_Enhanced, allocator: runtime.Allocator) {
	delete(e.genre, allocator)
	delete(e.start_time, allocator)
	delete(e.end_time, allocator)
}

// What sync_v1 does with ID3v1: Keep rewrites it where the file has one and never adds one,
// Always writes one, Never removes it.
V1_Policy :: enum u8 {
	Keep,
	Always,
	Never,
}

@(private)
same_v1 :: proc(a, b: ^V1_Tag) -> bool {
	a_version, a_track := written_version(a)
	b_version, b_track := written_version(b)
	if a_version != b_version || a_track != b_track {
		return false
	}
	// ASCII text is the same bytes in both encodings.
	if a.encoding != b.encoding && !v1_ascii(a) {
		return false
	}
	if a.genre != b.genre {
		return false
	}
	if a.title != b.title || a.artist != b.artist || a.album != b.album {
		return false
	}
	if a.year != b.year || a.comment != b.comment {
		return false
	}
	ea, a_enhanced := a.enhanced.?
	eb, b_enhanced := b.enhanced.?
	if a_enhanced != b_enhanced {
		return false
	}
	if !a_enhanced {
		return true
	}
	same_times := ea.start_time == eb.start_time && ea.end_time == eb.end_time
	return ea.speed == eb.speed && ea.genre == eb.genre && same_times
}

@(private)
v1_ascii :: proc(v1: ^V1_Tag) -> bool {
	texts := [?]string{v1.title, v1.artist, v1.album, v1.year, v1.comment}
	for text in texts {
		if !is_ascii(text) {
			return false
		}
	}
	e, has_enhanced := v1.enhanced.?
	return !has_enhanced || is_ascii(e.genre) && is_ascii(e.start_time) && is_ascii(e.end_time)
}

@(private)
v1_fits_latin1 :: proc(v1: ^V1_Tag) -> bool {
	texts := [?]string{v1.title, v1.artist, v1.album, v1.year, v1.comment}
	for text in texts {
		if !fits_latin1(text, max(int)) {
			return false
		}
	}
	e, has_enhanced := v1.enhanced.?
	return(
		!has_enhanced ||
		fits_latin1(e.genre, max(int)) &&
			fits_latin1(e.start_time, max(int)) &&
			fits_latin1(e.end_time, max(int)) \
	)
}

// The version and track a tag is written with: ID3v1.1 without a track is ID3v1.0, and ID3v1.0
// has no track.
@(private)
written_version :: proc(v1: ^V1_Tag) -> (version: V1_Version, track: u8) {
	switch {
	case v1.version == .V1_1 && v1.track != 0:
		return .V1_1, v1.track
	case v1.version == .None:
		return .None, 0
	}
	return .V1_0, 0
}

// The ID3v1 bytes of a tag: 128 bytes, or 355 when it holds an Enhanced TAG, which comes first;
// nil when its version is .None. Text is written in the tag's encoding, cut to its field: in
// Latin-1 a character outside it as '?', in UTF-8 without a character cut in two, except where the
// Enhanced TAG continues a field: its first 30 bytes may then end inside a character, which
// readers of the Enhanced TAG join to the rest, and others show broken. An ID3v1.1 tag without a
// track is the same bytes as ID3v1.0 and is written as such.
render_v1 :: proc(
	v1: ^V1_Tag,
	allocator := context.allocator,
) -> (
	bytes: []u8,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	if v1.version == .None {
		return nil, nil
	}
	enhanced, has_enhanced := v1.enhanced.?
	size := V1_SIZE + (V1_ENHANCED_SIZE if has_enhanced else 0)
	bytes = make([]u8, size, allocator) or_return
	tag := bytes[size - V1_SIZE:]
	copy(tag, "TAG")
	encoding := v1.encoding
	title := put_v1_text(tag[3:33], v1.title, encoding, has_enhanced)
	artist := put_v1_text(tag[33:63], v1.artist, encoding, has_enhanced)
	album := put_v1_text(tag[63:93], v1.album, encoding, has_enhanced)
	put_v1_text(tag[93:97], v1.year, encoding)
	if v1.version == .V1_1 && v1.track != 0 {
		put_v1_text(tag[97:125], v1.comment, encoding)
		tag[126] = v1.track
	} else {
		put_v1_text(tag[97:127], v1.comment, encoding)
	}
	tag[127] = v1.genre
	if has_enhanced {
		e := bytes[:V1_ENHANCED_SIZE]
		copy(e, "TAG+")
		put_v1_text(e[4:64], title, encoding)
		put_v1_text(e[64:124], artist, encoding)
		put_v1_text(e[124:184], album, encoding)
		e[184] = enhanced.speed
		put_v1_text(e[185:215], enhanced.genre, encoding)
		put_v1_text(e[215:221], enhanced.start_time, encoding)
		put_v1_text(e[221:227], enhanced.end_time, encoding)
	}
	return bytes, nil
}

// An ID3v1 tag holding the values of an ID3v2 tag in encoding, and the fields that do not fit:
// text longer than its field (30 characters in Latin-1 or bytes in UTF-8, 28 for the comment of
// ID3v1.1, 90 with the Enhanced TAG), characters outside Latin-1 when it is the encoding, a date
// that is more than a year, a track in ID3v1.0 or one that is not a number from 1 to 255, more
// than one genre, a genre missing from the ID3v1 table (unless the Enhanced TAG holds it). Fields
// ID3v1 has no room for at all (album artist, totals, disc) are not reported. ID3v1.1 without a
// track becomes ID3v1.0, the same bytes. Free the tag with destroy.
v1_from_tag :: proc(
	tag: ^Tag,
	version: V1_Version,
	enhanced := false,
	encoding := V1_Encoding.Latin1,
	allocator := context.allocator,
) -> (
	v1: V1_Tag,
	overflow: Fields,
	err: runtime.Allocator_Error,
) {
	tags := Tags {
		v2 = tag^,
	}
	return v1_from_tags(&tags, version, enhanced, encoding, allocator)
}

// Like v1_from_tag, from the fields of a file as get shows them: those of its ID3v2 tag, else those
// of its ID3v1 tag, whose year, genre number and Enhanced TAG details are kept.
@(private)
v1_from_tags :: proc(
	tags: ^Tags,
	version: V1_Version,
	enhanced: bool,
	encoding: V1_Encoding,
	allocator: runtime.Allocator,
) -> (
	v1: V1_Tag,
	overflow: Fields,
	err: runtime.Allocator_Error,
) {
	v1 = {
		version   = version,
		genre     = 255,
		encoding  = encoding,
		allocator = allocator,
	}
	if version == .None {
		return
	}
	defer if err != nil {
		destroy_v1(&v1)
	}
	track_text := get_file_field(tags, .Track, allocator) or_return
	defer delete(track_text, allocator)
	number, _ := parse_number(track_text)
	if version == .V1_1 && number >= 1 && number <= 255 {
		v1.track = u8(number)
	} else if track_text != "" {
		overflow += {.Track}
	}
	if v1.track == 0 {
		v1.version = .V1_0
	}

	long := 90 if enhanced else 30
	v1.title = get_file_field(tags, .Title, allocator) or_return
	v1.artist = get_file_field(tags, .Artist, allocator) or_return
	v1.album = get_file_field(tags, .Album, allocator) or_return
	v1.comment = get_file_field(tags, .Comment, allocator) or_return
	comment_limit := 28 if v1.version == .V1_1 else 30
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
		if !fits_v1(text.value, text.limit, encoding) {
			overflow += {text.field}
		}
	}

	date := get_tag_field(&tags.v2, .Date, allocator) or_return
	defer delete(date, allocator)
	switch {
	case date == "" && tags.v1.version != .None:
		v1.year = strings.clone(tags.v1.year, allocator) or_return
	case len(date) >= 4 && is_number(date[:4]):
		v1.year = strings.clone(date[:4], allocator) or_return
	}
	if date != "" && date != v1.year {
		overflow += {.Date}
	}

	e: V1_Enhanced
	if old, ok := tags.v1.enhanced.?; ok && tags.v1.version != .None {
		e.speed = old.speed
		e.start_time = strings.clone(old.start_time, allocator) or_return
		v1.enhanced = e
		e.end_time = strings.clone(old.end_time, allocator) or_return
		v1.enhanced = e
	}
	// The genre text: ID3v2's first genre, else the Enhanced TAG's, which refines ID3v1's number.
	names := genres(&tags.v2, allocator) or_return
	defer destroy_strings(&names, allocator)
	genre_text := ""
	if len(names) > 0 {
		genre_text = names[0]
		if len(names) > 1 {
			overflow += {.Genre}
		}
	} else if tags.v1.version != .None {
		v1.genre = tags.v1.genre
		if old, ok := tags.v1.enhanced.?; ok {
			genre_text = old.genre
		}
	}
	if genre_text != "" {
		index, known := genre_index(genre_text)
		if known && (len(names) > 0 || v1.genre == 255) {
			v1.genre = index
		}
		switch {
		case v1.genre != 255 && strings.equal_fold(genre_name(v1.genre), genre_text):
		case enhanced && fits_v1(genre_text, 30, encoding):
			e.genre = strings.clone(genre_text, allocator) or_return
			v1.enhanced = e
		case:
			overflow += {.Genre}
		}
	}
	needs_enhanced :=
		v1_length(v1.title, encoding) > 30 ||
		v1_length(v1.artist, encoding) > 30 ||
		v1_length(v1.album, encoding) > 30
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

// Rebuilds tags.v1 following the policy from the file's fields as get shows them (ID3v2, else
// ID3v1), and returns the fields that do not fit (see v1_from_tag). A field the ID3v2 tag lacks
// keeps its ID3v1 value: to clear a field from both, clear it in tags.v1 too. A nil version means
// ID3v1.1 when the track is a number from 1 to 255, else ID3v1.0; a nil enhanced keeps the Enhanced
// TAG when the file has one; a nil encoding keeps that of the file's ID3v1 tag, Latin-1 for a new
// one. The new tag uses the allocator the tags were read with.
sync_v1 :: proc(
	tags: ^Tags,
	policy: V1_Policy,
	version: Maybe(V1_Version) = nil,
	enhanced: Maybe(bool) = nil,
	encoding: Maybe(V1_Encoding) = nil,
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
	kept_encoding := tags.v1.encoding if tags.v1.version != .None else .Latin1
	v1: V1_Tag
	v1, overflow = v1_from_tags(
		tags,
		chosen,
		with_enhanced,
		encoding.? or_else kept_encoding,
		allocator,
	) or_return
	destroy_v1(&tags.v1)
	tags.v1 = v1
	return
}

// Writes what of s fits in field and returns the rest. A UTF-8 character that does not fit whole
// is left for the rest, unless the field is continued (by the Enhanced TAG): readers join the two
// before decoding.
@(private)
put_v1_text :: proc(
	field: []u8,
	s: string,
	encoding: V1_Encoding,
	continued := false,
) -> (
	rest: string,
) {
	if encoding == .UTF8 {
		n := min(len(s), len(field))
		for !continued && n < len(s) && n > 0 && !utf8.rune_start(s[n]) {
			n -= 1
		}
		copy(field, s[:n])
		return s[n:]
	}
	i := 0
	for r, at in s {
		if i >= len(field) {
			return s[at:]
		}
		field[i] = '?' if r > 0xFF || r == utf8.RUNE_ERROR else u8(r)
		i += 1
	}
	return ""
}

// Whether s fits in limit characters of Latin-1, or limit bytes of UTF-8.
@(private)
fits_v1 :: proc(s: string, limit: int, encoding: V1_Encoding) -> bool {
	if encoding == .UTF8 {
		return len(s) <= limit
	}
	return fits_latin1(s, limit)
}

// The room s takes in an ID3v1 field: its characters in Latin-1, its bytes in UTF-8.
@(private)
v1_length :: proc(s: string, encoding: V1_Encoding) -> int {
	return len(s) if encoding == .UTF8 else utf8.rune_count_in_string(s)
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
