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
