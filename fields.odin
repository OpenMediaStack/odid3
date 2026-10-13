package odid3

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"

// The common fields that typed accessors read and write.
Field :: enum u8 {
	Title, // TIT2, TT2
	Artist, // TPE1, TP1
	Album_Artist, // TPE2, TP2
	Album, // TALB, TAL
	Date, // TDRC; TYER, TDAT, TIME; TYE, TDA, TIM: "2019", "2019-05-03", "2019-05-03T10:20"
	Track, // TRCK, TRK, before the slash
	Track_Total, // after the slash
	Disc, // TPOS, TPA, before the slash
	Disc_Total, // after the slash
	Genre, // TCON, TCO, ID3v1 genre references resolved
	Comment, // COMM, COM: see get
}

// A set of fields, such as those sync_v1 and v1_from_tag report as not fitting in ID3v1.
Fields :: bit_set[Field;u16]

// The value of a field, allocated with allocator (free it with delete); "" when absent or
// undecodable. Several values
// (ID3v2.4 allows them) are joined with "; ". On Tags, a field the ID3v2 tag lacks comes from
// ID3v1. The comment is the first COMM frame without a description, else the first one that is
// not one of iTunes' own (described "iTun..."), else a TXXX frame described "comment", as ffmpeg
// writes it.
get :: proc {
	get_tag_field,
	get_file_field,
}

// See get.
get_tag_field :: proc(
	tag: ^Tag,
	field: Field,
	allocator := context.allocator,
) -> (
	value: string,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	switch field {
	case .Date:
		return tag_date(tag, allocator)
	case .Track, .Track_Total, .Disc, .Disc_Total:
		ids := TRACK_IDS if field == .Track || field == .Track_Total else DISC_IDS
		pair := first_text(tag, ids, allocator) or_return
		defer delete(pair, allocator)
		number, total := split_pair(pair)
		return strings.clone(number if field == .Track || field == .Disc else total, allocator)
	case .Genre:
		names := genres(tag, allocator) or_return
		defer destroy_strings(&names, allocator)
		return strings.join(names, "; ", allocator)
	case .Comment:
		return tag_comment(tag, allocator)
	case .Title:
		return first_text(tag, TITLE_IDS, allocator)
	case .Artist:
		return first_text(tag, ARTIST_IDS, allocator)
	case .Album_Artist:
		return first_text(tag, ALBUM_ARTIST_IDS, allocator)
	case .Album:
		return first_text(tag, ALBUM_IDS, allocator)
	}
	return "", nil
}

// See get.
get_file_field :: proc(
	tags: ^Tags,
	field: Field,
	allocator := context.allocator,
) -> (
	value: string,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	value = get_tag_field(&tags.v2, field, allocator) or_return
	if value != "" || tags.v1.version == .None {
		return
	}
	v1 := &tags.v1
	#partial switch field {
	case .Title:
		return strings.clone(v1.title, allocator)
	case .Artist:
		return strings.clone(v1.artist, allocator)
	case .Album:
		return strings.clone(v1.album, allocator)
	case .Date:
		return strings.clone(v1.year, allocator)
	case .Comment:
		return strings.clone(v1.comment, allocator)
	case .Track:
		if v1.track == 0 {
			return
		}
		buf: [4]u8
		return strings.clone(strconv.write_int(buf[:], i64(v1.track), 10), allocator)
	case .Genre:
		if enhanced, ok := v1.enhanced.?; ok && enhanced.genre != "" {
			return strings.clone(enhanced.genre, allocator)
		}
		return strings.clone(genre_name(v1.genre), allocator)
	}
	return
}

// The year of the date, false when there is none. On Tags, ID3v1's year when the ID3v2 tag has
// none. Allocates nothing.
year :: proc {
	tag_year,
	file_year,
}

// See year.
tag_year :: proc(tag: ^Tag) -> (year: int, ok: bool) {
	buf: [SCRATCH_SIZE]u8
	scratch: mem.Arena
	mem.arena_init(&scratch, buf[:])
	date, _ := tag_date(tag, mem.arena_allocator(&scratch))
	return parse_year(date)
}

// See year.
file_year :: proc(tags: ^Tags) -> (year: int, ok: bool) {
	year, ok = tag_year(&tags.v2)
	if !ok && tags.v1.version != .None {
		return parse_year(tags.v1.year)
	}
	return
}

// The track number and total, 0 when absent or not a number. On Tags, ID3v1.1's track when the
// ID3v2 tag has none. Allocates nothing.
track :: proc {
	tag_track,
	file_track,
}

// See track.
tag_track :: proc(tag: ^Tag) -> (number, total: int) {
	return number_pair(tag, TRACK_IDS)
}

// See track.
file_track :: proc(tags: ^Tags) -> (number, total: int) {
	number, total = tag_track(&tags.v2)
	if number == 0 && total == 0 && tags.v1.version != .None {
		number = int(tags.v1.track)
	}
	return
}

// The disc number and total, 0 when absent or not a number. ID3v1 has no disc, so on Tags it is
// the ID3v2 tag's. Allocates nothing.
disc :: proc {
	tag_disc,
	file_disc,
}

// See disc.
tag_disc :: proc(tag: ^Tag) -> (number, total: int) {
	return number_pair(tag, DISC_IDS)
}

// See disc.
file_disc :: proc(tags: ^Tags) -> (number, total: int) {
	return tag_disc(&tags.v2)
}

// The genres, ID3v1 references ("(17)", "17", "(RX)", "(CR)") resolved to names, followed by the
// text that refines them unless it repeats one ("(4)Eurodisco" gives Disco and Eurodisco), as
// mutagen reads them. Free with destroy.
genres :: proc(
	tag: ^Tag,
	allocator := context.allocator,
) -> (
	names: []string,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	values := all_text_values(tag, GENRE_IDS, allocator) or_return
	defer destroy_strings(&values, allocator)
	out := make([dynamic]string, allocator)
	defer if err != nil {
		partial := out[:]
		destroy_strings(&partial, allocator)
	}
	for value in values {
		resolve_genre(value, &out, allocator) or_return
	}
	return out[:], nil
}

// Every picture (APIC, PIC). Free with destroy. Tags read with skip_picture_data have none.
pictures :: proc(
	tag: ^Tag,
	allocator := context.allocator,
) -> (
	found: []Picture,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	out := make([dynamic]Picture, allocator)
	defer if err != nil {
		partial := out[:]
		destroy_pictures(&partial, allocator)
	}
	for &f in tag.frames {
		if f.id != "APIC" && f.id != "PIC" {
			continue
		}
		content := decode_owned(&f, tag.version, allocator) or_return
		if picture, ok := content.(Picture); ok {
			if _, append_err := append(&out, picture); append_err != nil {
				destroy_content(&content, allocator)
				return nil, append_err
			}
		} else {
			destroy_content(&content, allocator)
		}
	}
	return out[:], nil
}

// The front cover, else the first picture; found is false when there is none. Only the picture
// returned stays in memory. Free it with destroy. Tags read with skip_picture_data have none.
front_cover :: proc(
	tag: ^Tag,
	allocator := context.allocator,
) -> (
	picture: Picture,
	found: bool,
	err: runtime.Allocator_Error,
) {
	for &f in tag.frames {
		if f.id != "APIC" && f.id != "PIC" {
			continue
		}
		content, decode_err := decode_owned(&f, tag.version, allocator)
		if decode_err != nil {
			destroy_picture(&picture, allocator)
			return {}, false, decode_err
		}
		p, is_picture := content.(Picture)
		switch {
		case !is_picture:
			destroy_content(&content, allocator)
		case p.type == .Front_Cover:
			destroy_picture(&picture, allocator)
			return p, true, nil
		case found:
			destroy_content(&content, allocator)
		case:
			picture, found = p, true
		}
	}
	return
}

// The values of the first TXXX frame with this description (ignoring case), joined with "; ";
// found is false when there is none. Free the value with delete.
user_text :: proc(
	tag: ^Tag,
	description: string,
	allocator := context.allocator,
) -> (
	value: string,
	found: bool,
	err: runtime.Allocator_Error,
) {
	for &f in tag.frames {
		if f.id != "TXXX" && f.id != "TXX" {
			continue
		}
		content := decode_owned(&f, tag.version, allocator) or_return
		defer destroy_content(&content, allocator)
		text, is_user_text := content.(User_Text)
		if is_user_text && strings.equal_fold(text.description, description) {
			value = strings.join(text.values, "; ", allocator) or_return
			return value, true, nil
		}
	}
	return "", false, nil
}

// Every comment frame (COMM, or COM in ID3v2.2); lyrics (USLT) are not comments. Free with
// destroy.
comments :: proc(
	tag: ^Tag,
	allocator := context.allocator,
) -> (
	found: []Comment,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	out := make([dynamic]Comment, allocator)
	defer if err != nil {
		partial := out[:]
		destroy_comments(&partial, allocator)
	}
	for &f in tag.frames {
		if f.id != "COMM" && f.id != "COM" {
			continue
		}
		content := decode_owned(&f, tag.version, allocator) or_return
		if comment, ok := content.(Comment); ok {
			if _, append_err := append(&out, comment); append_err != nil {
				destroy_content(&content, allocator)
				return nil, append_err
			}
		} else {
			destroy_content(&content, allocator)
		}
	}
	return out[:], nil
}

// Frees a picture's strings and data, allocated with allocator.
destroy_picture :: proc(picture: ^Picture, allocator := context.allocator) {
	content := Frame_Content(picture^)
	destroy_content(&content, allocator)
	picture^ = {}
}

// Frees pictures and the slice that holds them, allocated with allocator.
destroy_pictures :: proc(pictures: ^[]Picture, allocator := context.allocator) {
	for &p in pictures {
		destroy_picture(&p, allocator)
	}
	delete(pictures^, allocator)
	pictures^ = nil
}

// Frees comments and the slice that holds them, allocated with allocator.
destroy_comments :: proc(comments: ^[]Comment, allocator := context.allocator) {
	for c in comments {
		content := Frame_Content(c)
		destroy_content(&content, allocator)
	}
	delete(comments^, allocator)
	comments^ = nil
}

// Frees strings and the slice that holds them, allocated with allocator.
destroy_strings :: proc(values: ^[]string, allocator := context.allocator) {
	delete_strings(values^, allocator)
	values^ = nil
}

@(private, rodata)
TITLE_IDS := []string{"TIT2", "TT2"}
@(private, rodata)
ARTIST_IDS := []string{"TPE1", "TP1"}
@(private, rodata)
ALBUM_ARTIST_IDS := []string{"TPE2", "TP2"}
@(private, rodata)
ALBUM_IDS := []string{"TALB", "TAL"}
@(private, rodata)
TRACK_IDS := []string{"TRCK", "TRK"}
@(private, rodata)
DISC_IDS := []string{"TPOS", "TPA"}
@(private, rodata)
GENRE_IDS := []string{"TCON", "TCO"}

// Decodes a frame, turning every error but running out of memory into no content.
@(private)
decode_owned :: proc(
	f: ^Frame,
	version: V2_Version,
	allocator: runtime.Allocator,
) -> (
	content: Frame_Content,
	err: runtime.Allocator_Error,
) {
	decoded, decode_err := decode_frame(f, version, allocator)
	if alloc_err, is_alloc := decode_err.(runtime.Allocator_Error); is_alloc {
		return nil, alloc_err
	}
	return decoded, nil
}

// The values of the first text frame with one of these IDs that decodes.
@(private)
all_text_values :: proc(
	tag: ^Tag,
	ids: []string,
	allocator: runtime.Allocator,
) -> (
	values: []string,
	err: runtime.Allocator_Error,
) {
	for &f in tag.frames {
		if !contains(ids, f.id) {
			continue
		}
		content := decode_owned(&f, tag.version, allocator) or_return
		if text, ok := content.(Text); ok {
			return text.values, nil
		}
		destroy_content(&content, allocator)
	}
	return nil, nil
}

@(private)
first_text :: proc(
	tag: ^Tag,
	ids: []string,
	allocator: runtime.Allocator,
) -> (
	value: string,
	err: runtime.Allocator_Error,
) {
	values := all_text_values(tag, ids, allocator) or_return
	defer destroy_strings(&values, allocator)
	return strings.join(values, "; ", allocator)
}

@(private)
contains :: proc(list: []string, s: string) -> bool {
	for entry in list {
		if entry == s {
			return true
		}
	}
	return false
}

// ID3v2.4 has one timestamp, TDRC. Before it the date was split in TYER ("2019"), TDAT ("0305",
// day then month) and TIME ("1020"); ID3v2.2 calls them TYE, TDA and TIM. As ffmpeg does, the day
// and the time only count after a year of 4 digits, and only when they are 4 digits that can be a
// date or a time.
@(private)
tag_date :: proc(
	tag: ^Tag,
	allocator: runtime.Allocator,
) -> (
	date: string,
	err: runtime.Allocator_Error,
) {
	timestamp := first_text(tag, {"TDRC"}, allocator) or_return
	if timestamp != "" {
		return timestamp, nil
	}
	year := first_text(tag, {"TYER", "TYE"}, allocator) or_return
	if len(year) != 4 || !is_number(year) {
		return year, nil
	}
	defer delete(year, allocator)
	day_month := first_text(tag, {"TDAT", "TDA"}, allocator) or_return
	defer delete(day_month, allocator)
	hours := first_text(tag, {"TIME", "TIM"}, allocator) or_return
	defer delete(hours, allocator)
	if !is_pair_within(day_month, 31, 12, 1) {
		return strings.clone(year, allocator)
	}
	day, month := day_month[0:2], day_month[2:4]
	if !is_pair_within(hours, 23, 59, 0) {
		return strings.concatenate({year, "-", month, "-", day}, allocator)
	}
	return strings.concatenate(
		{year, "-", month, "-", day, "T", hours[0:2], ":", hours[2:4]},
		allocator,
	)
}

// Whether s is 4 digits, a first pair from lowest to first and a second from lowest to second.
@(private)
is_pair_within :: proc(s: string, first, second, lowest: int) -> bool {
	if len(s) != 4 || !is_number(s) {
		return false
	}
	a, _ := parse_number(s[0:2])
	b, _ := parse_number(s[2:4])
	return a >= lowest && a <= first && b >= lowest && b <= second
}

@(private)
parse_year :: proc(date: string) -> (year: int, ok: bool) {
	if len(date) < 4 {
		return 0, false
	}
	return parse_number(date[:4])
}

// What year, track and disc decode fits on the stack: a value too long for it is no number anyway.
@(private)
SCRATCH_SIZE :: 1024

@(private)
tag_comment :: proc(
	tag: ^Tag,
	allocator: runtime.Allocator,
) -> (
	value: string,
	err: runtime.Allocator_Error,
) {
	all := comments(tag, allocator) or_return
	defer destroy_comments(&all, allocator)
	chosen := -1
	for c, i in all {
		if c.description == "" {
			chosen = i
			break
		}
		if chosen < 0 && !strings.has_prefix(c.description, "iTun") {
			chosen = i
		}
	}
	if chosen >= 0 {
		return strings.clone(all[chosen].text, allocator)
	}
	value, _ = user_text(tag, "comment", allocator) or_return
	return value, nil
}

// "3/12" gives "3" and "12", "3" gives "3" and "".
@(private)
split_pair :: proc(s: string) -> (number, total: string) {
	slash := strings.index_byte(s, '/')
	if slash < 0 {
		return strings.trim_space(s), ""
	}
	return strings.trim_space(s[:slash]), strings.trim_space(s[slash + 1:])
}

@(private)
number_pair :: proc(tag: ^Tag, ids: []string) -> (number, total: int) {
	buf: [SCRATCH_SIZE]u8
	scratch: mem.Arena
	mem.arena_init(&scratch, buf[:])
	pair, _ := first_text(tag, ids, mem.arena_allocator(&scratch))
	a, b := split_pair(pair)
	number, _ = parse_number(a)
	total, _ = parse_number(b)
	return
}

@(private)
is_number :: proc(s: string) -> bool {
	_, ok := parse_number(s)
	return ok
}

// A decimal number of at most 9 digits, nothing else.
@(private)
parse_number :: proc(s: string) -> (n: int, ok: bool) {
	if len(s) == 0 || len(s) > 9 {
		return 0, false
	}
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + int(c - '0')
	}
	return n, true
}

// A TCON value in ID3v2.3 is free text, ID3v1 genre references in parentheses ("(17)", "(RX)" for
// Remix, "(CR)" for Cover) or both, the text refining the references; "((" starts text that begins
// with a parenthesis. ID3v2.4 puts each reference in a value of its own, without parentheses.
@(private)
resolve_genre :: proc(
	value: string,
	out: ^[dynamic]string,
	allocator: runtime.Allocator,
) -> runtime.Allocator_Error {
	s := strings.trim_space(value)
	if s == "" {
		return nil
	}
	if name := genre_reference(s); name != "" {
		return append_clone(out, name, allocator)
	}
	names: [dynamic]string
	names.allocator = allocator
	defer delete(names)
	rest := s
	for strings.has_prefix(rest, "(") && !strings.has_prefix(rest, "((") {
		close := strings.index_byte(rest, ')')
		if close < 0 {
			break
		}
		name := genre_reference(rest[1:close])
		if name == "" {
			break
		}
		append(&names, name) or_return
		rest = rest[close + 1:]
	}
	refinement := strings.trim_space(rest)
	if strings.has_prefix(refinement, "((") {
		refinement = refinement[1:]
	}
	for name in names {
		append_clone(out, name, allocator) or_return
		if strings.equal_fold(name, refinement) {
			refinement = ""
		}
	}
	if refinement != "" {
		append_clone(out, refinement, allocator) or_return
	}
	return nil
}

// The genre an ID3v1 reference names: a genre number, RX or CR. "" when s is not a reference.
@(private)
genre_reference :: proc(s: string) -> string {
	switch s {
	case "RX":
		return "Remix"
	case "CR":
		return "Cover"
	}
	if n, ok := parse_number(s); ok && n < 256 {
		return genre_name(u8(n))
	}
	return ""
}

@(private)
append_clone :: proc(
	out: ^[dynamic]string,
	s: string,
	allocator: runtime.Allocator,
) -> runtime.Allocator_Error {
	clone := strings.clone(s, allocator) or_return
	if _, err := append(out, clone); err != nil {
		delete(clone, allocator)
		return err
	}
	return nil
}

// Sets a field of a tag: the frames that hold it are replaced by one in the place of the first, or
// one is added; an empty value removes them. A value equal to the one get gives leaves the tag as
// it is. The new frame keeps the encoding and status flags of the one it replaces when that
// encoding can hold the value, else it takes the version's default (UTF-8 in ID3v2.4; before,
// Latin-1 when the text fits, else UTF-16). The value is written as one value, even in ID3v2.4.
//
// The date is ISO 8601, as get gives it ("2019", "2019-05-03", "2019-05-03T10:20"); before
// ID3v2.4 it is split into TYER, TDAT and TIME, which cannot hold a month without its day, an
// hour without its minutes, nor seconds (.Not_In_Version). The comment replaces the one get reads,
// in its language and under its description; an empty comment removes every comment get could
// read instead, ffmpeg's TXXX comment included, but iTunes' own. A value that is not one (a date
// or a number that does not parse, a NUL) gives .Bad_Value. On any error the tag is left as it was.
set :: proc(tag: ^Tag, field: Field, value: string) -> Error {
	adopt_context_allocator(tag)
	if tag.version == .None {
		return .No_Version
	}
	if strings.index_byte(value, 0) >= 0 {
		return .Bad_Value
	}
	current := get_tag_field(tag, field, tag.allocator) or_return
	defer delete(current, tag.allocator)
	if current == value {
		return nil
	}
	switch field {
	case .Title, .Artist, .Album_Artist, .Album:
		return set_text(tag, field_ids(field), value)
	case .Date:
		return set_date(tag, value)
	case .Track, .Track_Total, .Disc, .Disc_Total:
		if value != "" && !is_number(value) {
			return .Bad_Value
		}
		ids := TRACK_IDS if field == .Track || field == .Track_Total else DISC_IDS
		pair := first_text(tag, ids, tag.allocator) or_return
		defer delete(pair, tag.allocator)
		number, total := split_pair(pair)
		if field == .Track || field == .Disc {
			number = value
		} else {
			total = value
		}
		return set_pair(tag, ids, number, total)
	case .Genre:
		if value == "" {
			return set_genres(tag, nil)
		}
		return set_genres(tag, {value})
	case .Comment:
		return set_read_comment(tag, value)
	}
	return nil
}

// Sets the track number and total; 0 leaves a part out, and both 0 remove the frame. A number
// below 0 or past 999999999 gives .Bad_Value.
set_track :: proc(tag: ^Tag, number, total: int) -> Error {
	return set_number_pair(tag, TRACK_IDS, number, total)
}

// Sets the disc number and total, as set_track does.
set_disc :: proc(tag: ^Tag, number, total: int) -> Error {
	return set_number_pair(tag, DISC_IDS, number, total)
}

// Sets the genres: several values in ID3v2.4, joined with "/" before. No genre removes the frame.
set_genres :: proc(tag: ^Tag, genres: []string) -> Error {
	adopt_context_allocator(tag)
	if tag.version == .None {
		return .No_Version
	}
	for genre in genres {
		if strings.index_byte(genre, 0) >= 0 {
			return .Bad_Value
		}
	}
	return set_text_values(tag, GENRE_IDS, genres)
}

// Replaces the pictures of the same type with picture, in the place of the first, or adds it. Its
// data is copied. ID3v2.2 names the image format in 3 letters: a MIME type it has no name for
// gives .Not_In_Version.
set_picture :: proc(tag: ^Tag, picture: Picture) -> Error {
	adopt_context_allocator(tag)
	if tag.version == .None {
		return .No_Version
	}
	if strings.index_byte(picture.description, 0) >= 0 ||
	   strings.index_byte(picture.mime, 0) >= 0 {
		return .Bad_Value
	}
	id := "PIC" if tag.version == .V2_2 else "APIC"
	p := picture
	if !encoding_holds(p.encoding, tag.version, p.description) {
		p.encoding = default_encoding(tag.version, p.description)
	}
	frame := encode_frame(p, id, tag.version, tag.allocator) or_return
	remove := make([dynamic]int, tag.allocator)
	defer delete(remove)
	for &f, i in tag.frames {
		if type, ok := picture_type_of(&f, tag.version); ok && type == picture.type {
			if _, err := append(&remove, i); err != nil {
				destroy_frame(&frame)
				return err
			}
		}
	}
	return edit_frames(tag, remove[:], {frame})
}

// Removes the pictures of a type, or every picture when type is nil.
remove_pictures :: proc(tag: ^Tag, type: Maybe(Picture_Type) = nil) {
	wanted, only_one_type := type.?
	for i := len(tag.frames) - 1; i >= 0; i -= 1 {
		f := &tag.frames[i]
		if f.id != "APIC" && f.id != "PIC" {
			continue
		}
		if picture_type, ok := picture_type_of(f, tag.version);
		   only_one_type && (!ok || picture_type != wanted) {
			continue
		}
		remove_frame(tag, i)
	}
}

// Sets the value of the TXXX frames with this description (ignoring case), replaced by one in the
// place of the first, or adds one. An empty value removes them.
set_user_text :: proc(tag: ^Tag, description, value: string) -> Error {
	adopt_context_allocator(tag)
	if tag.version == .None {
		return .No_Version
	}
	if strings.index_byte(description, 0) >= 0 || strings.index_byte(value, 0) >= 0 {
		return .Bad_Value
	}
	remove := make([dynamic]int, tag.allocator)
	defer delete(remove)
	previous: Maybe(Text_Format)
	for &f, i in tag.frames {
		if f.id != "TXXX" && f.id != "TXX" {
			continue
		}
		content := decode_owned(&f, tag.version, tag.allocator) or_return
		text, ok := content.(User_Text)
		matches := ok && strings.equal_fold(text.description, description)
		destroy_content(&content, tag.allocator)
		if matches {
			if previous == nil {
				previous = text_format(text.encoding, &f)
			}
			append(&remove, i) or_return
		}
	}
	if value == "" {
		return edit_frames(tag, remove[:], nil)
	}
	format := keep_format(previous, tag.version, description, value)
	content := User_Text {
		encoding    = format.encoding,
		description = description,
		values      = {value},
	}
	id := "TXX" if tag.version == .V2_2 else "TXXX"
	frame := encode_frame_in(content, id, tag.version, format.order, tag.allocator) or_return
	frame.status = format.status
	return edit_frames(tag, remove[:], {frame})
}

// Sets the COMM frames with this description and language, replaced by one in the place of the
// first, or adds one; empty text removes them. The language is 3 ASCII letters, such as "eng" or
// "XXX" when unknown; anything else gives .Bad_Value.
set_comment :: proc(tag: ^Tag, text: string, description := "", language := "eng") -> Error {
	adopt_context_allocator(tag)
	if tag.version == .None {
		return .No_Version
	}
	lang, valid := comment_language(language)
	if !valid || strings.index_byte(description, 0) >= 0 || strings.index_byte(text, 0) >= 0 {
		return .Bad_Value
	}
	comments := comment_frames(tag) or_return
	defer delete_comment_frames(&comments, tag.allocator)
	remove := make([dynamic]int, tag.allocator)
	defer delete(remove)
	previous: Maybe(Text_Format)
	for c in comments {
		if c.description == description && c.language == lang {
			if previous == nil {
				previous = c.format
			}
			append(&remove, c.index) or_return
		}
	}
	if text == "" {
		return edit_frames(tag, remove[:], nil)
	}
	frame := comment_frame(tag, lang, description, text, previous) or_return
	return edit_frames(tag, remove[:], {frame})
}

// The format of a text frame to keep when it is rewritten: its encoding, status flags and UTF-16
// byte order.
@(private)
Text_Format :: struct {
	encoding: Encoding,
	status:   Frame_Status,
	order:    Byte_Order,
}

@(private)
text_format :: proc(encoding: Encoding, f: ^Frame) -> Text_Format {
	order: Byte_Order
	if encoding == .UTF16 {
		order, _, _ = utf16_order_of(f)
	}
	return {encoding, f.status, order}
}

// The format of the frame being replaced when its encoding can hold the new values; else its
// status flags with the version's default encoding.
@(private)
keep_format :: proc(
	previous: Maybe(Text_Format),
	version: V2_Version,
	values: ..string,
) -> Text_Format {
	p, ok := previous.?
	if ok && encoding_holds(p.encoding, version, ..values) {
		return p
	}
	return {default_encoding(version, ..values), p.status, p.order}
}

// The encoding byte of a frame that starts with one.
@(private)
frame_encoding :: proc(f: ^Frame) -> (encoding: Encoding, ok: bool) {
	if f.problem != .None && f.problem != .Bad_Data_Length || len(f.data) == 0 {
		return
	}
	return encoding_of(f.data[0])
}

// Removes the frames at the indices in remove, in increasing order, and puts frames where the
// first of them was, or at the end. Room is reserved before anything changes, so either the tag
// is edited or it is left as it was. The tag takes the frames; they are freed on an error.
@(private)
edit_frames :: proc(tag: ^Tag, remove: []int, frames: []Frame) -> Error {
	if err := reserve(&tag.frames, len(tag.frames) + len(frames)); err != nil {
		for &f in frames {
			destroy_frame(&f)
		}
		return err
	}
	#reverse for i in remove {
		remove_frame(tag, i)
	}
	at := remove[0] if len(remove) > 0 else len(tag.frames)
	for f, k in frames {
		_, _ = inject_at(&tag.frames, at + k, f)
	}
	return nil
}

// The type of a picture frame, read from its bytes without decoding them.
@(private)
picture_type_of :: proc(f: ^Frame, version: V2_Version) -> (type: Picture_Type, ok: bool) {
	if f.id != "APIC" && f.id != "PIC" || f.problem != .None && f.problem != .Bad_Data_Length {
		return
	}
	at := 4
	if f.id == "APIC" {
		if len(f.data) < 2 {
			return
		}
		mime_end := strings.index_byte(string(f.data[1:]), 0)
		if mime_end < 0 {
			return
		}
		at = 1 + mime_end + 1
	}
	if at >= len(f.data) {
		return
	}
	return Picture_Type(f.data[at]), true
}

@(private)
comment_language :: proc(language: string) -> (lang: [3]u8, ok: bool) {
	if len(language) != 3 {
		return
	}
	for i in 0 ..< 3 {
		c := language[i]
		if !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') {
			return
		}
		lang[i] = c
	}
	return lang, true
}

// A comment frame of a tag, as the setters need it.
@(private)
Comment_Frame :: struct {
	index:       int,
	language:    [3]u8,
	description: string,
	format:      Text_Format,
}

// The comment frames of a tag that decode. Free with delete_comment_frames.
@(private)
comment_frames :: proc(tag: ^Tag) -> (found: [dynamic]Comment_Frame, err: Error) {
	found = make([dynamic]Comment_Frame, tag.allocator)
	for &f, i in tag.frames {
		if f.id != "COMM" && f.id != "COM" {
			continue
		}
		content, decode_err := decode_owned(&f, tag.version, tag.allocator)
		if decode_err != nil {
			delete_comment_frames(&found, tag.allocator)
			return nil, decode_err
		}
		defer destroy_content(&content, tag.allocator)
		c, ok := content.(Comment)
		if !ok {
			continue
		}
		description, clone_err := strings.clone(c.description, tag.allocator)
		if clone_err == nil {
			_, clone_err = append(
				&found,
				Comment_Frame{i, c.language, description, text_format(c.encoding, &f)},
			)
			if clone_err != nil {
				delete(description, tag.allocator)
			}
		}
		if clone_err != nil {
			delete_comment_frames(&found, tag.allocator)
			return nil, clone_err
		}
	}
	return found, nil
}

@(private)
delete_comment_frames :: proc(found: ^[dynamic]Comment_Frame, allocator: runtime.Allocator) {
	for c in found {
		delete(c.description, allocator)
	}
	delete(found^)
}

@(private)
comment_frame :: proc(
	tag: ^Tag,
	language: [3]u8,
	description, text: string,
	previous: Maybe(Text_Format),
) -> (
	frame: Frame,
	err: Error,
) {
	format := keep_format(previous, tag.version, description, text)
	content := Comment {
		encoding    = format.encoding,
		language    = language,
		description = description,
		text        = text,
	}
	frame = encode_frame_in(
		content,
		"COM" if tag.version == .V2_2 else "COMM",
		tag.version,
		format.order,
		tag.allocator,
	) or_return
	frame.status = format.status
	return
}

// Appends to remove the TXXX frames with this description (ignoring case), and gives the format
// of the first.
@(private)
find_user_text :: proc(
	tag: ^Tag,
	description: string,
	remove: ^[dynamic]int,
) -> (
	previous: Maybe(Text_Format),
	err: Error,
) {
	for &f, i in tag.frames {
		if f.id != "TXXX" && f.id != "TXX" {
			continue
		}
		content := decode_owned(&f, tag.version, tag.allocator) or_return
		text, ok := content.(User_Text)
		matches := ok && strings.equal_fold(text.description, description)
		encoding := text.encoding
		destroy_content(&content, tag.allocator)
		if matches {
			if previous == nil {
				previous = text_format(encoding, &f)
			}
			append(remove, i) or_return
		}
	}
	return
}

// The comment get reads, rewritten: the first COMM without a description, else the first that is
// not iTunes' own, else ffmpeg's TXXX comment. An empty value removes all of them.
@(private)
set_read_comment :: proc(tag: ^Tag, value: string) -> Error {
	comments := comment_frames(tag) or_return
	defer delete_comment_frames(&comments, tag.allocator)
	remove := make([dynamic]int, tag.allocator)
	defer delete(remove)
	previous := find_user_text(tag, "comment", &remove) or_return
	chosen := -1
	for c, k in comments {
		if c.description == "" {
			chosen = k
			break
		}
		if chosen < 0 && !strings.has_prefix(c.description, "iTun") {
			chosen = k
		}
	}
	if value == "" {
		for c in comments {
			if !strings.has_prefix(c.description, "iTun") {
				append(&remove, c.index) or_return
			}
		}
		slice.sort(remove[:])
		return edit_frames(tag, remove[:], nil)
	}
	language := [3]u8{'e', 'n', 'g'}
	description := ""
	if chosen >= 0 {
		c := comments[chosen]
		language, description, previous = c.language, c.description, c.format
		append(&remove, c.index) or_return
	}
	slice.sort(remove[:])
	frame := comment_frame(tag, language, description, value, previous) or_return
	return edit_frames(tag, remove[:], {frame})
}

@(private)
field_ids :: proc(field: Field) -> []string {
	#partial switch field {
	case .Title:
		return TITLE_IDS
	case .Artist:
		return ARTIST_IDS
	case .Album_Artist:
		return ALBUM_ARTIST_IDS
	case .Album:
		return ALBUM_IDS
	}
	return nil
}

// The ID a version uses among a field's IDs: the 4 letter one, or the 3 letter one in ID3v2.2.
@(private)
version_id :: proc(ids: []string, version: V2_Version) -> string {
	for id in ids {
		if (len(id) == 3) == (version == .V2_2) {
			return id
		}
	}
	return ids[0]
}

@(private)
set_text :: proc(tag: ^Tag, ids: []string, value: string) -> Error {
	if value == "" {
		return set_text_values(tag, ids, nil)
	}
	return set_text_values(tag, ids, {value})
}

@(private)
text_frame :: proc(
	tag: ^Tag,
	id: string,
	values: []string,
	previous: Maybe(Text_Format),
) -> (
	frame: Frame,
	err: Error,
) {
	format := keep_format(previous, tag.version, ..values)
	frame = encode_frame_in(
		Text{format.encoding, values},
		id,
		tag.version,
		format.order,
		tag.allocator,
	) or_return
	frame.status = format.status
	return
}

// Replaces the frames with one of ids by a text frame holding values, in the place of the first,
// in its format when it can; no values removes them all.
@(private)
set_text_values :: proc(tag: ^Tag, ids: []string, values: []string) -> Error {
	remove := make([dynamic]int, tag.allocator)
	defer delete(remove)
	previous: Maybe(Text_Format)
	for &f, i in tag.frames {
		if !contains(ids, f.id) {
			continue
		}
		if encoding, ok := frame_encoding(&f); ok && previous == nil {
			previous = text_format(encoding, &f)
		}
		append(&remove, i) or_return
	}
	if len(values) == 0 {
		return edit_frames(tag, remove[:], nil)
	}
	frame := text_frame(tag, version_id(ids, tag.version), values, previous) or_return
	return edit_frames(tag, remove[:], {frame})
}

@(private)
set_pair :: proc(tag: ^Tag, ids: []string, number, total: string) -> Error {
	switch {
	case number == "" && total == "":
		return set_text_values(tag, ids, nil)
	case total == "":
		return set_text(tag, ids, number)
	}
	pair := strings.concatenate({number, "/", total}, tag.allocator) or_return
	defer delete(pair, tag.allocator)
	return set_text(tag, ids, pair)
}

@(private)
MAX_NUMBER :: 999_999_999

@(private)
set_number_pair :: proc(tag: ^Tag, ids: []string, number, total: int) -> Error {
	adopt_context_allocator(tag)
	if tag.version == .None {
		return .No_Version
	}
	if number < 0 || number > MAX_NUMBER || total < 0 || total > MAX_NUMBER {
		return .Bad_Value
	}
	a, b: [20]u8
	n := strconv.write_int(a[:], i64(number), 10) if number > 0 else ""
	t := strconv.write_int(b[:], i64(total), 10) if total > 0 else ""
	return set_pair(tag, ids, n, t)
}

// Every ID a date lives in: ID3v2.4's timestamp, then the parts of ID3v2.3 and 2.2.
@(private, rodata)
DATE_IDS := [7]string{"TDRC", "TYER", "TDAT", "TIME", "TYE", "TDA", "TIM"}

// "2019-05-03T10:20" is TDRC in ID3v2.4; before, TYER "2019", TDAT "0305" (day then month) and
// TIME "1020", or TYE, TDA and TIM in ID3v2.2.
@(private)
set_date :: proc(tag: ^Tag, value: string) -> Error {
	parts := 0
	if value != "" {
		ok: bool
		parts, ok = parse_date(value)
		if !ok {
			return .Bad_Value
		}
		if tag.version != .V2_4 && parts % 2 == 0 {
			return .Not_In_Version
		}
	}
	remove := make([dynamic]int, tag.allocator)
	defer delete(remove)
	formats: [len(DATE_IDS)]Maybe(Text_Format)
	for &f, i in tag.frames {
		k := -1
		for id, j in DATE_IDS {
			if f.id == id {
				k = j
			}
		}
		if k < 0 {
			continue
		}
		if encoding, ok := frame_encoding(&f); ok && formats[k] == nil {
			formats[k] = text_format(encoding, &f)
		}
		append(&remove, i) or_return
	}
	day_month := [4]u8{value[8], value[9], value[5], value[6]} if parts >= 3 else {}
	hours := [4]u8{value[11], value[12], value[14], value[15]} if parts >= 5 else {}
	texts: [3]struct {
		id:    int,
		value: string,
	}
	n := 0
	switch {
	case parts == 0:
	case tag.version == .V2_4:
		texts[0] = {0, value}
		n = 1
	case:
		shift := 3 if tag.version == .V2_2 else 0
		texts[0] = {1 + shift, value[:4]}
		n = 1
		if parts >= 3 {
			texts[1] = {2 + shift, string(day_month[:])}
			n = 2
		}
		if parts >= 5 {
			texts[2] = {3 + shift, string(hours[:])}
			n = 3
		}
	}
	frames: [3]Frame
	for text, k in texts[:n] {
		frame, err := text_frame(tag, DATE_IDS[text.id], {text.value}, formats[text.id])
		if err != nil {
			for &f in frames[:k] {
				destroy_frame(&f)
			}
			return err
		}
		frames[k] = frame
	}
	return edit_frames(tag, remove[:], frames[:n])
}

// The number of parts of an ISO 8601 date as ID3v2.4 writes it, from "2019" (1) to
// "2019-05-03T10:20:30" (6); ok is false for anything else.
@(private)
parse_date :: proc(s: string) -> (parts: int, ok: bool) {
	field :: proc(s: string, at: int, lowest, highest: int) -> bool {
		n, is_number := parse_number(s[at:at + 2])
		return is_number && n >= lowest && n <= highest
	}
	switch len(s) {
	case 4, 7, 10, 13, 16, 19:
	case:
		return 0, false
	}
	if !is_number(s[:4]) {
		return 0, false
	}
	parts = 1
	separators := "--T::"
	limits := [5][2]int{{1, 12}, {1, 31}, {0, 23}, {0, 59}, {0, 59}}
	for at := 4; at < len(s); at += 3 {
		k := parts - 1
		if s[at] != separators[k] || !field(s, at + 1, limits[k][0], limits[k][1]) {
			return 0, false
		}
		parts += 1
	}
	return parts, true
}
// A tag made by hand has no allocator yet: it takes the context's, which then owns its frames.
@(private)
adopt_context_allocator :: proc(tag: ^Tag) {
	if tag.allocator.procedure == nil {
		tag.allocator = context.allocator
	}
	if tag.frames.allocator.procedure == nil {
		tag.frames.allocator = tag.allocator
	}
}
