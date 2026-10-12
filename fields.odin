package odid3

import "base:runtime"
import "core:mem"
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

// A set of fields.
Fields :: bit_set[Field;u16]

// The value of a field, allocated with allocator; "" when absent or undecodable. Several values
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

// Sets a field of a tag: the frame that holds it is replaced, or added. An empty value removes it.
// A new frame takes its version's default encoding (UTF-8 in ID3v2.4; before, Latin-1 when the text
// fits, else UTF-16); an existing frame keeps its own when it can hold the value. The date is split
// into TYER, TDAT and TIME before ID3v2.4; setting the comment also removes ffmpeg's TXXX comment.
set :: proc(tag: ^Tag, field: Field, value: string) -> Error {
	adopt_context_allocator(tag)
	if tag.version == .None {
		return .No_Version
	}
	switch field {
	case .Title, .Artist, .Album_Artist, .Album:
		return set_text(tag, field_ids(field), value)
	case .Date:
		return set_date(tag, value)
	case .Track, .Track_Total, .Disc, .Disc_Total:
		ids := TRACK_IDS if field == .Track || field == .Track_Total else DISC_IDS
		current := first_text(tag, ids, tag.allocator) or_return
		defer delete(current, tag.allocator)
		number, total := split_pair(current)
		if field == .Track || field == .Disc {
			number = strings.trim_space(value)
		} else {
			total = strings.trim_space(value)
		}
		return set_pair(tag, ids, number, total)
	case .Genre:
		if value == "" {
			return set_genres(tag, nil)
		}
		return set_genres(tag, {value})
	case .Comment:
		remove_user_text(tag, "comment")
		return set_comment(tag, value)
	}
	return nil
}

// Sets the track number and total; 0 leaves a part out, and both 0 remove the frame.
set_track :: proc(tag: ^Tag, number, total: int) -> Error {
	return set_number_pair(tag, TRACK_IDS, number, total)
}

// Sets the disc number and total; 0 leaves a part out, and both 0 remove the frame.
set_disc :: proc(tag: ^Tag, number, total: int) -> Error {
	return set_number_pair(tag, DISC_IDS, number, total)
}

// Sets the genres: several values in ID3v2.4, joined with "/" before. No genre removes the frame.
set_genres :: proc(tag: ^Tag, genres: []string) -> Error {
	adopt_context_allocator(tag)
	if tag.version == .None {
		return .No_Version
	}
	return set_text_values(tag, GENRE_IDS, genres)
}

// Replaces the pictures of the same type with picture, or adds it. Its data is copied.
set_picture :: proc(tag: ^Tag, picture: Picture) -> Error {
	adopt_context_allocator(tag)
	if tag.version == .None {
		return .No_Version
	}
	id := "PIC" if tag.version == .V2_2 else "APIC"
	p := picture
	if !encoding_holds(p.encoding, tag.version, p.description) {
		p.encoding = default_encoding(tag.version, p.description)
	}
	frame := encode_frame(p, id, tag.version, tag.allocator) or_return
	remove_pictures(tag, picture.type)
	if err := add_frame(tag, frame); err != nil {
		destroy_frame(&frame)
		return err
	}
	return nil
}

// Removes the pictures of a type, or every picture when type is nil.
remove_pictures :: proc(tag: ^Tag, type: Maybe(Picture_Type) = nil) {
	wanted, only_one_type := type.?
	for i := len(tag.frames) - 1; i >= 0; i -= 1 {
		f := &tag.frames[i]
		if f.id != "APIC" && f.id != "PIC" {
			continue
		}
		if only_one_type {
			content, err := decode_frame(f, tag.version, tag.allocator)
			picture, is_picture := content.(Picture)
			matches := err == nil && is_picture && picture.type == wanted
			destroy_content(&content, tag.allocator)
			if !matches {
				continue
			}
		}
		remove_frame(tag, i)
	}
}

// Sets the value of the TXXX frame with this description (ignoring case), or adds one. An empty
// value removes it.
set_user_text :: proc(tag: ^Tag, description, value: string) -> Error {
	adopt_context_allocator(tag)
	if tag.version == .None {
		return .No_Version
	}
	index := remove_user_text(tag, description)
	if value == "" {
		return nil
	}
	encoding := default_encoding(tag.version, description, value)
	content := User_Text {
		encoding    = encoding,
		description = description,
		values      = {value},
	}
	frame := encode_frame(
		content,
		"TXX" if tag.version == .V2_2 else "TXXX",
		tag.version,
		tag.allocator,
	) or_return
	return insert_frame(tag, index, frame)
}

// Sets the COMM frame with this description and language, or adds one. Empty text removes it.
set_comment :: proc(tag: ^Tag, text: string, description := "", language := "eng") -> Error {
	adopt_context_allocator(tag)
	if tag.version == .None {
		return .No_Version
	}
	lang: [3]u8
	copy(lang[:], language)
	index := -1
	for i := len(tag.frames) - 1; i >= 0; i -= 1 {
		f := &tag.frames[i]
		if f.id != "COMM" && f.id != "COM" {
			continue
		}
		content, err := decode_frame(f, tag.version, tag.allocator)
		comment, is_comment := content.(Comment)
		matches :=
			err == nil &&
			is_comment &&
			comment.description == description &&
			comment.language == lang
		destroy_content(&content, tag.allocator)
		if matches {
			remove_frame(tag, i)
			index = i
		}
	}
	if text == "" {
		return nil
	}
	content := Comment {
		encoding    = default_encoding(tag.version, description, text),
		language    = lang,
		description = description,
		text        = text,
	}
	frame := encode_frame(
		content,
		"COM" if tag.version == .V2_2 else "COMM",
		tag.version,
		tag.allocator,
	) or_return
	return insert_frame(tag, index, frame)
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

// Replaces the first frame with one of ids by a text frame holding values, removing the others;
// no values removes them all. The frame keeps its place, flags and encoding when it can.
@(private)
set_text_values :: proc(tag: ^Tag, ids: []string, values: []string) -> Error {
	index := -1
	encoding: Maybe(Encoding)
	status: Frame_Status
	for i := len(tag.frames) - 1; i >= 0; i -= 1 {
		f := &tag.frames[i]
		if !contains(ids, f.id) {
			continue
		}
		content, err := decode_frame(f, tag.version, tag.allocator)
		if text, ok := content.(Text); err == nil && ok {
			encoding = text.encoding
		}
		destroy_content(&content, tag.allocator)
		status = f.status
		remove_frame(tag, i)
		index = i
	}
	if len(values) == 0 {
		return nil
	}
	chosen, has_encoding := encoding.?
	if !has_encoding || !encoding_holds(chosen, tag.version, ..values) {
		chosen = default_encoding(tag.version, ..values)
	}
	frame := encode_frame(
		Text{chosen, values},
		version_id(ids, tag.version),
		tag.version,
		tag.allocator,
	) or_return
	frame.status = status
	return insert_frame(tag, index, frame)
}

// Inserts a frame where an old one was (index -1: at the end); the tag takes ownership.
@(private)
insert_frame :: proc(tag: ^Tag, index: int, frame: Frame) -> Error {
	frame := frame
	if tag.frames.allocator.procedure == nil {
		tag.frames.allocator = tag.allocator
	}
	err: runtime.Allocator_Error
	if index < 0 || index >= len(tag.frames) {
		_, err = append(&tag.frames, frame)
	} else {
		_, err = inject_at(&tag.frames, index, frame)
	}
	if err != nil {
		destroy_frame(&frame)
	}
	return err
}

// Removes the TXXX frames with this description and returns where the first one was, -1 if none.
@(private)
remove_user_text :: proc(tag: ^Tag, description: string) -> (index: int) {
	index = -1
	for i := len(tag.frames) - 1; i >= 0; i -= 1 {
		f := &tag.frames[i]
		if f.id != "TXXX" && f.id != "TXX" {
			continue
		}
		content, err := decode_frame(f, tag.version, tag.allocator)
		text, ok := content.(User_Text)
		matches := err == nil && ok && strings.equal_fold(text.description, description)
		destroy_content(&content, tag.allocator)
		if matches {
			remove_frame(tag, i)
			index = i
		}
	}
	return
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
set_number_pair :: proc(tag: ^Tag, ids: []string, number, total: int) -> Error {
	adopt_context_allocator(tag)
	if tag.version == .None {
		return .No_Version
	}
	a, b: [20]u8
	n := strconv.write_int(a[:], i64(number), 10) if number > 0 else ""
	t := strconv.write_int(b[:], i64(total), 10) if total > 0 else ""
	return set_pair(tag, ids, n, t)
}

// "2019-05-03T10:20" is TDRC in ID3v2.4; before, TYER "2019", TDAT "0305" (day then month) and
// TIME "1020", or TYE, TDA and TIM in ID3v2.2.
@(private)
set_date :: proc(tag: ^Tag, value: string) -> Error {
	if tag.version == .V2_4 {
		set_text_values(tag, {"TYER", "TDAT", "TIME"}, nil) or_return
		return set_text(tag, {"TDRC"}, value)
	}
	set_text_values(tag, {"TDRC"}, nil) or_return
	v22 := tag.version == .V2_2
	year, day_month, hours: string
	if len(value) >= 4 {
		year = value[:4]
	}
	if len(value) >= 10 && value[4] == '-' && value[7] == '-' {
		day_month = strings.concatenate({value[8:10], value[5:7]}, tag.allocator) or_return
	}
	defer delete(day_month, tag.allocator)
	if len(value) >= 16 && value[10] == 'T' && value[13] == ':' {
		hours = strings.concatenate({value[11:13], value[14:16]}, tag.allocator) or_return
	}
	defer delete(hours, tag.allocator)
	set_text(tag, {"TYE"} if v22 else {"TYER"}, year) or_return
	set_text(tag, {"TDA"} if v22 else {"TDAT"}, day_month) or_return
	return set_text(tag, {"TIM"} if v22 else {"TIME"}, hours)
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
