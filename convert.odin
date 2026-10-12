package odid3

import "base:runtime"
import "core:strings"

// A frame a conversion removed, and why.
Dropped_Frame :: struct {
	id:     string,
	reason: Drop_Reason,
}

// The frames a conversion removed. Free with destroy.
Dropped_Frames :: [dynamic]Dropped_Frame

// Why a conversion removed a frame.
Drop_Reason :: enum u8 {
	// The target version has no frame with this layout (RVA2 in ID3v2.3, RVAD in ID3v2.4...).
	No_Equivalent,
	// Encrypted, or compressed in a way that cannot be carried without its key or sizes.
	Encrypted,
	// A frame odid3 does not know, which asks to be dropped when its tag changes.
	Discard_On_Tag_Alter,
	// Text in an encoding the target version does not have, in a frame odid3 cannot re-encode.
	Not_Encodable,
	// The tag was converted to .None.
	Tag_Removed,
}

// A deep copy, to preview a conversion or an edit without touching the original. The copy belongs
// to the caller, who frees it with destroy.
clone :: proc {
	clone_tag,
	clone_tags,
}

// See clone.
clone_tag :: proc(tag: ^Tag, allocator := context.allocator) -> (duplicate: Tag, err: Error) {
	duplicate = tag^
	duplicate.allocator = allocator
	duplicate.frames = make([dynamic]Frame, 0, len(tag.frames), allocator) or_return
	defer if err != nil {
		destroy_tag(&duplicate)
	}
	for &f in tag.frames {
		frame := clone_frame(&f, allocator) or_return
		if _, append_err := append(&duplicate.frames, frame); append_err != nil {
			destroy_frame(&frame)
			return duplicate, append_err
		}
	}
	return
}

// See clone.
clone_tags :: proc(tags: ^Tags, allocator := context.allocator) -> (duplicate: Tags, err: Error) {
	duplicate.layout, duplicate.warnings = tags.layout, tags.warnings
	duplicate.v2 = clone_tag(&tags.v2, allocator) or_return
	duplicate.v1, err = clone_v1(&tags.v1, allocator)
	if err != nil {
		destroy_tag(&duplicate.v2)
	}
	return
}

@(private)
clone_frame :: proc(f: ^Frame, allocator: runtime.Allocator) -> (duplicate: Frame, err: Error) {
	duplicate = f^
	duplicate.allocator = allocator
	duplicate.id = strings.clone(f.id, allocator) or_return
	duplicate.data, err = clone_bytes(f.data, allocator)
	if err != nil {
		delete(duplicate.id, allocator)
	}
	return
}

// Converts a tag in place to another version: renames and merges frames (TYER, TDAT and TIME into
// TDRC, TORY into TDOR, IPLS into TIPL, and back), re-encodes text the target cannot hold, and
// removes the frames it cannot carry, which it returns. From .None it only sets the version; to
// .None it removes every frame. Free the result with destroy.
convert :: proc(
	tag: ^Tag,
	to: V2_Version,
	allocator := context.allocator,
) -> (
	dropped: Dropped_Frames,
	err: Error,
) {
	adopt_context_allocator(tag)
	dropped = make(Dropped_Frames, allocator)
	defer if err != nil {
		destroy_dropped(&dropped, allocator)
	}
	from := tag.version
	switch {
	case from == to:
		return
	case from == .None:
		tag.version = to
		return
	case to == .None:
		for len(tag.frames) > 0 {
			drop(tag, len(tag.frames) - 1, .Tag_Removed, &dropped, allocator) or_return
		}
		tag.version = .None
		tag.flags = {}
		return
	}
	date := tag_date(tag, tag.allocator) or_return
	defer delete(date, tag.allocator)
	original_year := first_text(tag, {"TORY", "TDOR", "TOR"}, tag.allocator) or_return
	defer delete(original_year, tag.allocator)
	people := involved_people(tag, tag.allocator) or_return
	defer destroy_strings(&people, tag.allocator)

	for i := len(tag.frames) - 1; i >= 0; i -= 1 {
		f := &tag.frames[i]
		reason, drop_it := conversion_drop(f, from, to)
		if drop_it {
			drop(tag, i, reason, &dropped, allocator) or_return
		}
	}
	remove_frames(tag, DATE_IDS[:])
	remove_frames(tag, ORIGINAL_YEAR_IDS)
	remove_frames(tag, PEOPLE_IDS)
	tag.version = to
	tag.flags = {}

	for i := len(tag.frames) - 1; i >= 0; i -= 1 {
		if !(reencode_if_needed(tag, i) or_return) {
			drop(tag, i, .Not_Encodable, &dropped, allocator) or_return
		}
	}
	if date != "" {
		set_date(tag, date) or_return
	}
	if original_year != "" {
		if to == .V2_4 {
			set_text(tag, {"TDOR"}, original_year) or_return
		} else {
			set_text(tag, {"TORY"}, original_year[:min(4, len(original_year))]) or_return
		}
	}
	if len(people) > 0 {
		set_people(tag, people) or_return
	}
	return
}

// Frees the IDs of dropped frames and the list.
destroy_dropped :: proc(dropped: ^Dropped_Frames, allocator := context.allocator) {
	for d in dropped {
		delete(d.id, allocator)
	}
	delete(dropped^)
	dropped^ = nil
}

@(private, rodata)
ORIGINAL_YEAR_IDS := []string{"TDOR", "TORY", "TOR"}
@(private, rodata)
PEOPLE_IDS := []string{"IPLS", "TIPL", "TMCL", "IPL"}

// Frames whose binary layout changed between ID3v2.3 and 2.4.
@(private, rodata)
V23_ONLY := []string{"EQUA", "RVAD"}
@(private, rodata)
V24_ONLY := []string{"EQU2", "RVA2", "ASPI", "SEEK", "SIGN"}

// The frames of ID3v2.3 and 2.4, with chapters and the frames iTunes added: any other frame is one
// odid3 does not know.
@(private, rodata)
KNOWN_FRAMES := []string {
	"AENC",
	"APIC",
	"ASPI",
	"CHAP",
	"COMM",
	"COMR",
	"CTOC",
	"ENCR",
	"EQU2",
	"EQUA",
	"ETCO",
	"GEOB",
	"GRID",
	"GRP1",
	"IPLS",
	"LINK",
	"MCDI",
	"MLLT",
	"MVIN",
	"MVNM",
	"OWNE",
	"PCNT",
	"PCST",
	"POPM",
	"POSS",
	"PRIV",
	"RBUF",
	"RVA2",
	"RVAD",
	"RVRB",
	"SEEK",
	"SIGN",
	"SYLT",
	"SYTC",
	"TALB",
	"TBPM",
	"TCAT",
	"TCMP",
	"TCOM",
	"TCON",
	"TCOP",
	"TDAT",
	"TDEN",
	"TDES",
	"TDLY",
	"TDOR",
	"TDRC",
	"TDRL",
	"TDTG",
	"TENC",
	"TEXT",
	"TFLT",
	"TGID",
	"TIME",
	"TIPL",
	"TIT1",
	"TIT2",
	"TIT3",
	"TKEY",
	"TKWD",
	"TLAN",
	"TLEN",
	"TMCL",
	"TMED",
	"TMOO",
	"TOAL",
	"TOFN",
	"TOLY",
	"TOPE",
	"TORY",
	"TOWN",
	"TPE1",
	"TPE2",
	"TPE3",
	"TPE4",
	"TPOS",
	"TPRO",
	"TPUB",
	"TRCK",
	"TRDA",
	"TRSN",
	"TRSO",
	"TSIZ",
	"TSO2",
	"TSOA",
	"TSOC",
	"TSOP",
	"TSOT",
	"TSRC",
	"TSSE",
	"TSST",
	"TXXX",
	"TYER",
	"UFID",
	"USER",
	"USLT",
	"WCOM",
	"WCOP",
	"WFED",
	"WOAF",
	"WOAR",
	"WOAS",
	"WORS",
	"WPAY",
	"WPUB",
	"WXXX",
}

@(private)
conversion_drop :: proc(f: ^Frame, from, to: V2_Version) -> (reason: Drop_Reason, drop_it: bool) {
	if to == .V2_3 && contains(V24_ONLY, f.id) || to == .V2_4 && contains(V23_ONLY, f.id) {
		return .No_Equivalent, true
	}
	if .Discard_On_Tag_Alter in f.status && !contains(KNOWN_FRAMES, f.id) {
		return .Discard_On_Tag_Alter, true
	}
	// Before ID3v2.4, a compressed frame states its decompressed size, which an encrypted or
	// badly compressed frame from ID3v2.4 may not have given.
	as_stored := f.problem == .Encrypted || f.problem == .Bad_Compression
	if as_stored && .Compression in f.format && f.data_length < 0 {
		return .Encrypted, true
	}
	return {}, false
}

@(private)
drop :: proc(
	tag: ^Tag,
	index: int,
	reason: Drop_Reason,
	dropped: ^Dropped_Frames,
	allocator: runtime.Allocator,
) -> Error {
	id := strings.clone(tag.frames[index].id, allocator) or_return
	if _, err := append(dropped, Dropped_Frame{id, reason}); err != nil {
		delete(id, allocator)
		return err
	}
	remove_frame(tag, index)
	return nil
}

@(private)
remove_frames :: proc(tag: ^Tag, ids: []string) {
	for i := len(tag.frames) - 1; i >= 0; i -= 1 {
		if contains(ids, tag.frames[i].id) {
			remove_frame(tag, i)
		}
	}
}

// Re-encodes a frame whose text is in an encoding the tag's version does not have. ok is false when
// the frame needs it but its content cannot be decoded and encoded again.
@(private)
reencode_if_needed :: proc(tag: ^Tag, index: int) -> (ok: bool, err: Error) {
	f := &tag.frames[index]
	as_stored :=
		f.problem == .Encrypted || f.problem == .Bad_Compression || f.problem == .Too_Short
	if as_stored || !has_encoding_byte(f.id) || len(f.data) == 0 {
		return true, nil
	}
	encoding, known := encoding_of(f.data[0])
	if !known || encoding_holds(encoding, tag.version) {
		return true, nil
	}
	content, decode_err := decode_frame(f, .V2_4, tag.allocator)
	defer destroy_content(&content, tag.allocator)
	if decode_err != nil {
		if alloc, is_alloc := decode_err.(runtime.Allocator_Error); is_alloc {
			return false, alloc
		}
		return false, nil
	}
	// Only versions before ID3v2.4 lack encodings, and they hold Latin-1 or UTF-16.
	switch &c in content {
	case Text:
		c.encoding = .Latin1 if fits_all_latin1(..c.values) else .UTF16
	case User_Text:
		c.encoding =
			.Latin1 if fits_all_latin1(..c.values) && fits_all_latin1(c.description) else .UTF16
	case User_Url:
		c.encoding = .Latin1 if fits_all_latin1(c.description) else .UTF16
	case Comment:
		c.encoding = .Latin1 if fits_all_latin1(c.description, c.text) else .UTF16
	case Picture:
		c.encoding = .Latin1 if fits_all_latin1(c.description) else .UTF16
	case Url,
	     Unique_File_Id,
	     Popularimeter,
	     Play_Counter,
	     Private,
	     Chapter,
	     Table_Of_Contents,
	     Binary:
		return false, nil
	}
	replacement := encode_frame(content, f.id, tag.version, tag.allocator) or_return
	replacement.status = f.status
	replacement.format = f.format & {.Grouping}
	replacement.group = f.group
	destroy_frame(f)
	f^ = replacement
	return true, nil
}

@(private)
fits_all_latin1 :: proc(values: ..string) -> bool {
	for value in values {
		if !fits_latin1(value, max(int)) {
			return false
		}
	}
	return true
}

// The involved people of a tag: ID3v2.3's IPLS, or ID3v2.4's TIPL and TMCL, as pairs of a role and
// a name.
@(private)
involved_people :: proc(
	tag: ^Tag,
	allocator: runtime.Allocator,
) -> (
	people: []string,
	err: runtime.Allocator_Error,
) {
	out := make([dynamic]string, allocator)
	defer if err != nil {
		partial := out[:]
		destroy_strings(&partial, allocator)
	}
	for &f in tag.frames {
		if !contains(PEOPLE_IDS, f.id) || len(f.data) < 1 {
			continue
		}
		encoding, ok := encoding_of(f.data[0])
		if !ok || f.problem != .None {
			continue
		}
		for rest := f.data[1:]; len(rest) > 0; {
			text: []u8
			text, rest, _ = split_terminated(encoding, rest)
			value := decode_text(encoding, text, allocator) or_else ""
			append(&out, value) or_return
		}
	}
	return out[:], nil
}

// Writes involved people as pairs of strings each ended by a terminator: IPLS in ID3v2.3, TIPL in
// ID3v2.4, IPL in ID3v2.2.
@(private)
set_people :: proc(tag: ^Tag, people: []string) -> Error {
	encoding := default_encoding(tag.version, ..people)
	data := make([dynamic]u8, tag.allocator)
	defer delete(data)
	append(&data, u8(encoding)) or_return
	for value in people {
		encode_string(&data, encoding, value, true) or_return
	}
	id := "TIPL" if tag.version == .V2_4 else "IPL" if tag.version == .V2_2 else "IPLS"
	frame := make_frame(id, data[:], tag.allocator) or_return
	return insert_frame(tag, -1, frame)
}

// Inserts a frame at index, or at the end for -1; the tag takes it, and frees it on an error.
@(private)
insert_frame :: proc(tag: ^Tag, index: int, frame: Frame) -> Error {
	frame := frame
	at := index if index >= 0 && index <= len(tag.frames) else len(tag.frames)
	if _, err := inject_at(&tag.frames, at, frame); err != nil {
		destroy_frame(&frame)
		return err
	}
	return nil
}
