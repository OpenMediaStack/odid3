package odid3

import "base:runtime"
import "core:bytes"
import "core:strings"

// The content of a frame, decoded. Everything in it is allocated with the allocator given to
// decode_frame; free it with destroy and that allocator.
Frame_Content :: union {
	Text,
	User_Text,
	Url,
	User_Url,
	Comment,
	Picture,
	Unique_File_Id,
	Popularimeter,
	Play_Counter,
	Private,
	Chapter,
	Table_Of_Contents,
	Binary,
}

// A text frame (T*** but TXXX). ID3v2.4 can hold several values; earlier versions hold one.
Text :: struct {
	encoding: Encoding,
	values:   []string,
}

// TXXX: text under a description.
User_Text :: struct {
	encoding:    Encoding,
	description: string,
	values:      []string,
}

// A URL frame (W*** but WXXX). URLs are Latin-1.
Url :: struct {
	url: string,
}

// WXXX: a URL under a description.
User_Url :: struct {
	encoding:    Encoding,
	description: string,
	url:         string,
}

// COMM (a comment) or USLT (lyrics): text in a language, under a description.
Comment :: struct {
	encoding:    Encoding,
	language:    [3]u8, // ISO-639-2, such as "eng"; often "XXX" or zeros
	description: string,
	text:        string,
}

// APIC, or PIC in ID3v2.2. One that decode_frame or front_cover returns owns its strings and data:
// free it with destroy. set_picture copies it, and gives it the version's default encoding when
// its own cannot hold the description.
Picture :: struct {
	encoding:    Encoding,
	mime:        string, // as stored; ID3v2.2's "JPG" and "PNG" read as "image/jpeg" and "image/png"
	type:        Picture_Type,
	description: string,
	data:        []u8, // the image, or its URL when mime is "-->"
}

// What a picture shows. Values past Publisher_Logo are kept as they are.
Picture_Type :: enum u8 {
	Other,
	File_Icon,
	Other_File_Icon,
	Front_Cover,
	Back_Cover,
	Leaflet,
	Media,
	Lead_Artist,
	Artist,
	Conductor,
	Band,
	Composer,
	Lyricist,
	Recording_Location,
	During_Recording,
	During_Performance,
	Screen_Capture,
	Bright_Coloured_Fish,
	Illustration,
	Band_Logo,
	Publisher_Logo,
}

// UFID: an identifier given by the owner, such as a MusicBrainz recording ID.
Unique_File_Id :: struct {
	owner:      string,
	identifier: []u8,
}

// POPM: how much a user (an email address) likes the file, from 1 to 255 (0 is unknown), and how
// many times it was played.
Popularimeter :: struct {
	email:   string,
	rating:  u8,
	counter: u64, // 0 when absent; saturates past 64 bits
}

// PCNT: how many times the file was played.
Play_Counter :: struct {
	counter: u64, // saturates past 64 bits
}

// PRIV: data a program keeps under its owner identifier.
Private :: struct {
	owner: string,
	data:  []u8,
}

// CHAP, from the ID3v2 chapter addendum (ID3v2.3 and 2.4): a part of the file, with frames of its
// own, such as a TIT2 title. The frames belong to the content and go with it on destroy; decode
// them with the version of the tag, like the tag's own frames.
Chapter :: struct {
	element_id:   string,
	start_ms:     u32,
	end_ms:       u32,
	start_offset: u32, // in bytes from the start of the file; 0xFFFFFFFF when unused
	end_offset:   u32,
	frames:       [dynamic]Frame, // offset -1
	warnings:     Warnings, // what reading the frames found wrong
}

// CTOC, from the ID3v2 chapter addendum: a table listing chapters, or other tables, by element ID.
// Its frames are like a Chapter's.
Table_Of_Contents :: struct {
	element_id: string,
	top_level:  bool,
	ordered:    bool,
	children:   []string,
	frames:     [dynamic]Frame, // offset -1
	warnings:   Warnings,
}

// A frame odid3 does not decode: its data, copied.
Binary :: struct {
	data: []u8,
}

// Decodes the content of a frame; version is the version of its tag, which decides whether a text
// frame holds several values (ID3v2.4) and how the frames inside CHAP and CTOC are laid out. The
// content copies what it needs from the frame and belongs to the caller, who frees it with destroy
// and the same allocator. A frame whose data is not its content (encrypted, compressed but not
// inflated, skipped, too short, a chapter inside a chapter) gives .Not_Decodable; data that does
// not follow the frame's layout gives .Bad_Content.
decode_frame :: proc(
	frame: ^Frame,
	version: V2_Version,
	allocator := context.allocator,
) -> (
	content: Frame_Content,
	err: Error,
) {
	#partial switch frame.problem {
	case .Too_Short, .Skipped_Picture, .Encrypted, .Bad_Compression, .Nested_Chapter:
		return nil, .Not_Decodable
	case .Bad_Unsynchronisation:
		if frame.format & {.Compression, .Encryption} != {} {
			return nil, .Not_Decodable
		}
	}
	defer if err != nil {
		destroy_content(&content, allocator)
	}
	data := frame.data
	id := frame.id
	kind := kinds_of(id)
	switch {
	case .TXXX in kind:
		content = decode_user_text(data, version, allocator) or_return
	case len(id) > 0 && id[0] == 'T' || is_itunes_text_frame(id):
		content = decode_text_frame(data, version, allocator) or_return
	case .WXXX in kind:
		content = decode_user_url(data, allocator) or_return
	case len(id) > 0 && id[0] == 'W':
		url := decode_latin1(first_string(.Latin1, data), allocator) or_return
		content = Url{url}
	case kind & {.COMM, .USLT} != {}:
		content = decode_comment(data, allocator) or_return
	case .APIC in kind:
		content = decode_picture(data, len(id) == 3, allocator) or_return
	case .UFID in kind:
		owner, identifier := decode_owned_bytes(data, allocator) or_return
		content = Unique_File_Id{owner, identifier}
	case .POPM in kind:
		content = decode_popularimeter(data, allocator) or_return
	case .PCNT in kind:
		content = Play_Counter{big_endian_counter(data)}
	case .PRIV in kind:
		owner, private := decode_owned_bytes(data, allocator) or_return
		content = Private{owner, private}
	case .CHAP in kind:
		content = decode_chapter(frame, version, allocator) or_return
	case .CTOC in kind:
		content = decode_table_of_contents(frame, version, allocator) or_return
	case:
		content = Binary{clone_bytes(data, allocator) or_return}
	}
	return
}

// Frees what decode_frame allocated in content, with the same allocator, and resets it.
destroy_content :: proc(content: ^Frame_Content, allocator := context.allocator) {
	switch &c in content {
	case Text:
		delete_strings(c.values, allocator)
	case User_Text:
		delete(c.description, allocator)
		delete_strings(c.values, allocator)
	case Url:
		delete(c.url, allocator)
	case User_Url:
		delete(c.description, allocator)
		delete(c.url, allocator)
	case Comment:
		delete(c.description, allocator)
		delete(c.text, allocator)
	case Picture:
		delete(c.mime, allocator)
		delete(c.description, allocator)
		delete(c.data, allocator)
	case Unique_File_Id:
		delete(c.owner, allocator)
		delete(c.identifier, allocator)
	case Popularimeter:
		delete(c.email, allocator)
	case Play_Counter:
	case Private:
		delete(c.owner, allocator)
		delete(c.data, allocator)
	case Chapter:
		delete(c.element_id, allocator)
		destroy_frames(&c.frames)
	case Table_Of_Contents:
		delete(c.element_id, allocator)
		delete_strings(c.children, allocator)
		destroy_frames(&c.frames)
	case Binary:
		delete(c.data, allocator)
	}
	content^ = nil
}

@(private)
destroy_frames :: proc(frames: ^[dynamic]Frame) {
	for &f in frames {
		destroy_frame(&f)
	}
	delete(frames^)
}

@(private)
delete_strings :: proc(values: []string, allocator: runtime.Allocator) {
	for value in values {
		delete(value, allocator)
	}
	delete(values, allocator)
}

@(private)
clone_bytes :: proc(data: []u8, allocator: runtime.Allocator) -> (out: []u8, err: Error) {
	if len(data) == 0 {
		return nil, nil
	}
	out = make([]u8, len(data), allocator) or_return
	copy(out, data)
	return out, nil
}

@(private)
encoding_of :: proc(b: u8) -> (encoding: Encoding, ok: bool) {
	if b > u8(max(Encoding)) {
		return .Latin1, false
	}
	return Encoding(b), true
}

@(private)
first_string :: proc(encoding: Encoding, data: []u8) -> []u8 {
	text, _, _ := split_terminated(encoding, data)
	return text
}

// The strings of a text frame. ID3v2.4 separates several values with terminators; before it, what
// follows the first terminator is to be ignored.
@(private)
decode_values :: proc(
	encoding: Encoding,
	data: []u8,
	version: V2_Version,
	allocator: runtime.Allocator,
) -> (
	values: []string,
	err: Error,
) {
	count := 0
	for rest := data; len(rest) > 0; {
		_, next, _ := split_terminated(encoding, rest)
		rest = next
		count += 1
		if version != .V2_4 {
			break
		}
	}
	if count == 0 {
		return nil, nil
	}
	values = make([]string, count, allocator) or_return
	defer if err != nil {
		delete_strings(values, allocator)
	}
	rest := data
	order := encoding
	for &value, i in values {
		text: []u8
		text, rest, _ = split_terminated(encoding, rest)
		value = decode_text(order, text, allocator) or_return
		if i == 0 {
			order = byte_order_of(order, text)
		}
	}
	return
}

// The byte order of a UTF-16 frame's text as decoding reads it: that of its first string's byte
// order mark, little endian without one, followed by the strings after it without a mark. mixed
// is true when a later string's mark says otherwise; known is false for a layout odid3 does not
// decode.
@(private)
utf16_order_of :: proc(f: ^Frame) -> (order: Byte_Order, mixed, known: bool) {
	text, only_first, decoded := text_of(f)
	if !decoded {
		return .Little_Endian, false, false
	}
	for rest, first := text, true; len(rest) > 0; first = false {
		s: []u8
		s, rest, _ = split_terminated(.UTF16, rest)
		mark: Maybe(Byte_Order)
		if len(s) >= 2 && s[0] == 0xFE && s[1] == 0xFF {
			mark = .Big_Endian
		} else if len(s) >= 2 && s[0] == 0xFF && s[1] == 0xFE {
			mark = .Little_Endian
		}
		if first {
			order = mark.? or_else .Little_Endian
			if only_first {
				break
			}
		} else if m, marked := mark.?; marked && m != order {
			mixed = true
		}
	}
	return order, mixed, true
}

// The data of a frame with an encoding byte from its first string of text on; only_first is true
// when that string is the only text (a URL or an image follows it). known is false for a layout
// odid3 does not decode.
@(private)
text_of :: proc(f: ^Frame) -> (text: []u8, only_first, known: bool) {
	if len(f.data) == 0 {
		return nil, false, false
	}
	kind := kinds_of(f.id)
	switch {
	case kind & {.COMM, .USLT} != {}:
		return f.data[min(4, len(f.data)):], false, true
	case .APIC in kind && len(f.id) == 3:
		return f.data[min(5, len(f.data)):], true, true
	case .APIC in kind:
		nul := bytes.index_byte(f.data[1:], 0)
		if nul < 0 {
			return nil, true, true
		}
		return f.data[min(nul + 3, len(f.data)):], true, true
	case .WXXX in kind:
		return f.data[1:], true, true
	}
	if len(f.id) == 0 || f.id[0] != 'T' && !is_itunes_text_frame(f.id) {
		return nil, false, false
	}
	return f.data[1:], false, true
}

// ID3v2.4, section 4: all the UTF-16 strings of a frame share one byte order, so a string
// without a byte order mark follows the order of the first one. Decoding a string as UTF16BE
// still honours its own byte order mark.
@(private)
byte_order_of :: proc(encoding: Encoding, first: []u8) -> Encoding {
	if encoding == .UTF16 && len(first) >= 2 && first[0] == 0xFE && first[1] == 0xFF {
		return .UTF16BE
	}
	return encoding
}

// iTunes writes these frames as text frames, with an encoding byte, under IDs outside the T family.
@(private)
is_itunes_text_frame :: proc(id: string) -> bool {
	return is_kind(id, {.WFED, .GRP1, .MVNM, .MVIN})
}

@(private)
decode_text_frame :: proc(
	data: []u8,
	version: V2_Version,
	allocator: runtime.Allocator,
) -> (
	t: Text,
	err: Error,
) {
	if len(data) < 1 {
		return {}, .Bad_Content
	}
	ok: bool
	t.encoding, ok = encoding_of(data[0])
	if !ok {
		return {}, .Bad_Content
	}
	t.values = decode_values(t.encoding, data[1:], version, allocator) or_return
	return
}

@(private)
decode_user_text :: proc(
	data: []u8,
	version: V2_Version,
	allocator: runtime.Allocator,
) -> (
	t: User_Text,
	err: Error,
) {
	if len(data) < 1 {
		return {}, .Bad_Content
	}
	ok: bool
	t.encoding, ok = encoding_of(data[0])
	if !ok {
		return {}, .Bad_Content
	}
	description, rest, _ := split_terminated(t.encoding, data[1:])
	t.description = decode_text(t.encoding, description, allocator) or_return
	t.values, err = decode_values(byte_order_of(t.encoding, description), rest, version, allocator)
	if err != nil {
		delete(t.description, allocator)
	}
	return
}

@(private)
decode_user_url :: proc(data: []u8, allocator: runtime.Allocator) -> (u: User_Url, err: Error) {
	if len(data) < 1 {
		return {}, .Bad_Content
	}
	ok: bool
	u.encoding, ok = encoding_of(data[0])
	if !ok {
		return {}, .Bad_Content
	}
	description, rest, _ := split_terminated(u.encoding, data[1:])
	u.description = decode_text(u.encoding, description, allocator) or_return
	u.url, err = decode_latin1(first_string(.Latin1, rest), allocator)
	if err != nil {
		delete(u.description, allocator)
	}
	return
}

@(private)
decode_comment :: proc(data: []u8, allocator: runtime.Allocator) -> (c: Comment, err: Error) {
	if len(data) < 4 {
		return {}, .Bad_Content
	}
	ok: bool
	c.encoding, ok = encoding_of(data[0])
	if !ok {
		return {}, .Bad_Content
	}
	copy(c.language[:], data[1:4])
	description, rest, _ := split_terminated(c.encoding, data[4:])
	c.description = decode_text(c.encoding, description, allocator) or_return
	order := byte_order_of(c.encoding, description)
	c.text, err = decode_text(order, first_string(c.encoding, rest), allocator)
	if err != nil {
		delete(c.description, allocator)
	}
	return
}

// APIC holds a MIME type in Latin-1 ended by a NUL; ID3v2.2's PIC holds a 3 character image format.
@(private)
decode_picture :: proc(
	data: []u8,
	v22: bool,
	allocator: runtime.Allocator,
) -> (
	p: Picture,
	err: Error,
) {
	if len(data) < 2 {
		return {}, .Bad_Content
	}
	ok: bool
	p.encoding, ok = encoding_of(data[0])
	if !ok {
		return {}, .Bad_Content
	}
	rest := data[1:]
	mime: []u8
	if v22 {
		if len(rest) < 4 {
			return {}, .Bad_Content
		}
		mime, rest = rest[:3], rest[3:]
	} else {
		terminated: bool
		mime, rest, terminated = split_terminated(.Latin1, rest)
		if !terminated || len(rest) < 1 {
			return {}, .Bad_Content
		}
	}
	p.type = Picture_Type(rest[0])
	description, image, terminated := split_terminated(p.encoding, rest[1:])
	if !terminated {
		return {}, .Bad_Content
	}
	defer if err != nil {
		delete(p.mime, allocator)
		delete(p.description, allocator)
	}
	known := v22_image_mime(string(mime)) if v22 else string(mime)
	if known != string(mime) {
		p.mime = strings.clone(known, allocator) or_return
	} else {
		p.mime = decode_latin1(mime, allocator) or_return
	}
	p.description = decode_text(p.encoding, description, allocator) or_return
	p.data = clone_bytes(image, allocator) or_return
	return
}

// An owner in Latin-1 ended by a NUL, then bytes: the layout of UFID and PRIV.
@(private)
decode_owned_bytes :: proc(
	data: []u8,
	allocator: runtime.Allocator,
) -> (
	owner: string,
	bytes: []u8,
	err: Error,
) {
	owner_bytes, rest, _ := split_terminated(.Latin1, data)
	owner = decode_latin1(owner_bytes, allocator) or_return
	bytes, err = clone_bytes(rest, allocator)
	if err != nil {
		delete(owner, allocator)
	}
	return
}

// The element ID in Latin-1 ended by a NUL, the start and end times in milliseconds, the start and
// end byte offsets, then frames.
@(private)
decode_chapter :: proc(
	frame: ^Frame,
	version: V2_Version,
	allocator: runtime.Allocator,
) -> (
	c: Chapter,
	err: Error,
) {
	id, rest, terminated := split_terminated(.Latin1, frame.data)
	if !terminated || len(rest) < 16 {
		return {}, .Bad_Content
	}
	c.start_ms = be32(rest[0:4])
	c.end_ms = be32(rest[4:8])
	c.start_offset = be32(rest[8:12])
	c.end_offset = be32(rest[12:16])
	c.element_id = decode_latin1(id, allocator) or_return
	c.frames, c.warnings, err = read_embedded_frames(rest[16:], frame, version, allocator)
	if err != nil {
		delete(c.element_id, allocator)
		return {}, err
	}
	return
}

// The element ID ended by a NUL, flags (0x02 top level, 0x01 ordered), the number of children,
// their element IDs each ended by a NUL, then frames.
@(private)
decode_table_of_contents :: proc(
	frame: ^Frame,
	version: V2_Version,
	allocator: runtime.Allocator,
) -> (
	toc: Table_Of_Contents,
	err: Error,
) {
	id, rest, terminated := split_terminated(.Latin1, frame.data)
	if !terminated || len(rest) < 2 {
		return {}, .Bad_Content
	}
	toc.top_level = rest[0] & 0x02 != 0
	toc.ordered = rest[0] & 0x01 != 0
	count := int(rest[1])
	rest = rest[2:]
	err = decode_children(&toc, id, count, &rest, allocator)
	if err == nil {
		toc.frames, toc.warnings, err = read_embedded_frames(rest, frame, version, allocator)
	}
	if err != nil {
		content := Frame_Content(toc)
		destroy_content(&content, allocator)
		return {}, err
	}
	return toc, nil
}

// The element ID of a table and the IDs of its children, each ended by a NUL.
@(private)
decode_children :: proc(
	toc: ^Table_Of_Contents,
	id: []u8,
	count: int,
	rest: ^[]u8,
	allocator: runtime.Allocator,
) -> Error {
	toc.element_id = decode_latin1(id, allocator) or_return
	toc.children = make([]string, count, allocator) or_return
	for &child in toc.children {
		text: []u8
		terminated: bool
		text, rest^, terminated = split_terminated(.Latin1, rest^)
		if !terminated {
			return .Bad_Content
		}
		child = decode_latin1(text, allocator) or_return
	}
	return nil
}

@(private)
v22_image_mime :: proc(format: string) -> string {
	switch {
	case strings.equal_fold(format, "JPG"):
		return "image/jpeg"
	case strings.equal_fold(format, "PNG"):
		return "image/png"
	case strings.equal_fold(format, "GIF"):
		return "image/gif"
	case strings.equal_fold(format, "BMP"):
		return "image/bmp"
	}
	return format
}

@(private)
decode_popularimeter :: proc(
	data: []u8,
	allocator: runtime.Allocator,
) -> (
	p: Popularimeter,
	err: Error,
) {
	email, rest, terminated := split_terminated(.Latin1, data)
	if !terminated || len(rest) < 1 {
		return {}, .Bad_Content
	}
	p.rating = rest[0]
	p.counter = big_endian_counter(rest[1:])
	p.email = decode_latin1(email, allocator) or_return
	return
}

@(private)
big_endian_counter :: proc(b: []u8) -> (n: u64) {
	for c in b {
		if n > max(u64) >> 8 {
			return max(u64)
		}
		n = n << 8 | u64(c)
	}
	return
}

// A new frame holding content in the layout of a tag of the given version, owned by allocator. Text
// that its encoding cannot hold gives .Not_Encodable, an encoding the version does not have
// .Encoding_Not_In_Version, an ID of the wrong length .Bad_Frame_Id. Before ID3v2.4, several values
// are joined with "/", as mutagen does. UTF-16 is written little endian after its byte order mark;
// set_encoding gives a frame the other order. The frames inside a Chapter or Table_Of_Contents are
// checked as new ones, even those decoded from a file: an ID other than capital letters and digits
// gives .Bad_Frame_Id, an encoding byte the version lacks .Encoding_Not_In_Version.
encode_frame :: proc(
	content: Frame_Content,
	id: string,
	version: V2_Version,
	allocator := context.allocator,
) -> (
	frame: Frame,
	err: Error,
) {
	return encode_frame_in(content, id, version, .Little_Endian, allocator)
}

@(private)
encode_frame_in :: proc(
	content: Frame_Content,
	id: string,
	version: V2_Version,
	order: Byte_Order,
	allocator: runtime.Allocator,
	frames_read := false,
) -> (
	frame: Frame,
	err: Error,
) {
	if version == .None {
		return {}, .No_Version
	}
	if len(id) != (3 if version == .V2_2 else 4) {
		return {}, .Bad_Frame_Id
	}
	data := make([dynamic]u8, allocator)
	defer if err != nil {
		delete(data)
	}
	switch c in content {
	case Text:
		start_text(&data, c.encoding, version) or_return
		encode_values(&data, c.encoding, c.values, version, order) or_return
	case User_Text:
		start_text(&data, c.encoding, version) or_return
		encode_string(&data, c.encoding, c.description, true, order) or_return
		encode_values(&data, c.encoding, c.values, version, order) or_return
	case Url:
		encode_string(&data, .Latin1, c.url, false) or_return
	case User_Url:
		start_text(&data, c.encoding, version) or_return
		encode_string(&data, c.encoding, c.description, true, order) or_return
		encode_string(&data, .Latin1, c.url, false) or_return
	case Comment:
		start_text(&data, c.encoding, version) or_return
		language := c.language
		append(&data, ..language[:]) or_return
		encode_string(&data, c.encoding, c.description, true, order) or_return
		encode_string(&data, c.encoding, c.text, false, order) or_return
	case Picture:
		start_text(&data, c.encoding, version) or_return
		if version == .V2_2 {
			format := v22_image_format(c.mime)
			if format == "" {
				return {}, .Not_In_Version
			}
			append(&data, format) or_return
		} else {
			encode_string(&data, .Latin1, c.mime, true) or_return
		}
		append(&data, u8(c.type)) or_return
		encode_string(&data, c.encoding, c.description, true, order) or_return
		append(&data, ..c.data) or_return
	case Unique_File_Id:
		encode_string(&data, .Latin1, c.owner, true) or_return
		append(&data, ..c.identifier) or_return
	case Popularimeter:
		encode_string(&data, .Latin1, c.email, true) or_return
		append(&data, c.rating) or_return
		if c.counter > 0 {
			append_counter(&data, c.counter) or_return
		}
	case Play_Counter:
		append_counter(&data, c.counter) or_return
	case Private:
		encode_string(&data, .Latin1, c.owner, true) or_return
		append(&data, ..c.data) or_return
	case Chapter:
		encode_string(&data, .Latin1, c.element_id, true) or_return
		times: [16]u8
		put_be32(times[0:4], c.start_ms)
		put_be32(times[4:8], c.end_ms)
		put_be32(times[8:12], c.start_offset)
		put_be32(times[12:16], c.end_offset)
		append(&data, ..times[:]) or_return
		render_embedded_frames(&data, c.frames[:], version, frames_read) or_return
	case Table_Of_Contents:
		encode_string(&data, .Latin1, c.element_id, true) or_return
		flags: u8 = (0x02 if c.top_level else 0) | (0x01 if c.ordered else 0)
		if len(c.children) > 255 {
			return {}, .Bad_Content
		}
		append(&data, flags, u8(len(c.children))) or_return
		for child in c.children {
			encode_string(&data, .Latin1, child, true) or_return
		}
		render_embedded_frames(&data, c.frames[:], version, frames_read) or_return
	case Binary:
		append(&data, ..c.data) or_return
	case:
		return {}, .Bad_Content
	}
	// The ID first: once the data shrinks into a new block, nothing else may fail.
	frame.id = strings.clone(id, allocator) or_return
	allocated := ([^]u8)(raw_data(data))[:cap(data)]
	frame.data, err = shrink(allocated, len(data), allocator)
	if err != nil {
		delete(frame.id, allocator)
		return {}, err
	}
	frame.allocator = allocator
	frame.offset = -1
	frame.data_length = -1
	return frame, nil
}

// The frames inside a chapter are written uncompressed: odid3 only inflates them when the chapter
// comes straight from a file, which a new one does not.
@(private)
render_embedded_frames :: proc(
	data: ^[dynamic]u8,
	frames: []Frame,
	version: V2_Version,
	frames_read: bool,
) -> Error {
	for f in frames {
		plain := f
		if !is_stored(&plain) {
			plain.format -= {.Compression}
		}
		render_frame(data, &plain, version, read = frames_read) or_return
	}
	return nil
}

// encode_frame for a CHAP or CTOC that odid3 decoded: the frames inside were read from its bytes
// (or rebuilt by odid3, valid anyway), so they keep what render keeps in a frame read from a tag,
// an odd ID or an encoding byte the version lacks, rather than being refused as new frames are.
@(private)
encode_decoded_chapter :: proc(
	content: Frame_Content,
	id: string,
	version: V2_Version,
	allocator: runtime.Allocator,
) -> (
	Frame,
	Error,
) {
	return encode_frame_in(content, id, version, .Little_Endian, allocator, frames_read = true)
}

@(private)
start_text :: proc(data: ^[dynamic]u8, encoding: Encoding, version: V2_Version) -> Error {
	if !encoding_holds(encoding, version) {
		return .Encoding_Not_In_Version
	}
	append(data, u8(encoding)) or_return
	return nil
}

@(private)
encode_string :: proc(
	data: ^[dynamic]u8,
	encoding: Encoding,
	s: string,
	terminated: bool,
	order := Byte_Order.Little_Endian,
) -> Error {
	ok := append_encoded(data, encoding, s, order) or_return
	if !ok {
		return .Not_Encodable
	}
	if terminated {
		append_terminator(data, encoding) or_return
	}
	return nil
}

@(private)
encode_values :: proc(
	data: ^[dynamic]u8,
	encoding: Encoding,
	values: []string,
	version: V2_Version,
	order: Byte_Order,
) -> Error {
	if version != .V2_4 && len(values) > 1 {
		joined := strings.join(values, "/", data.allocator) or_return
		defer delete(joined, data.allocator)
		return encode_string(data, encoding, joined, false, order)
	}
	for value, i in values {
		if i > 0 {
			append_terminator(data, encoding) or_return
		}
		encode_string(data, encoding, value, false, order) or_return
	}
	return nil
}

@(private)
append_counter :: proc(data: ^[dynamic]u8, counter: u64) -> runtime.Allocator_Error {
	b: [8]u8
	n := counter
	for i := 7; i >= 0; i -= 1 {
		b[i] = u8(n)
		n >>= 8
	}
	start := 0
	for start < 4 && b[start] == 0 {
		start += 1
	}
	_, err := append(data, ..b[start:])
	return err
}

@(private)
v22_image_format :: proc(mime: string) -> string {
	switch {
	case strings.equal_fold(mime, "image/jpeg"),
	     strings.equal_fold(mime, "image/jpg"),
	     strings.equal_fold(mime, "image/pjpeg"):
		return "JPG"
	case strings.equal_fold(mime, "image/png"), strings.equal_fold(mime, "image/x-png"):
		return "PNG"
	case strings.equal_fold(mime, "image/gif"):
		return "GIF"
	case strings.equal_fold(mime, "image/bmp"):
		return "BMP"
	case len(mime) == 3:
		return mime
	}
	return ""
}

// Re-encodes the text of a frame, or of every frame of a tag that holds text, chapters included.
// Text the encoding cannot hold gives .Not_Encodable and changes nothing, an encoding the version
// lacks .Encoding_Not_In_Version. A frame already in the encoding is left as it is. Text that would
// not survive (bytes other than NULs after the text of a comment or the URL of a WXXX, a UTF-16
// surrogate without its pair, an odd last byte of UTF-16 text other than a NUL) gives .Bad_Content
// rather than being changed; before ID3v2.4, several values are joined with "/". UTF-16 with a
// byte order mark is written in byte_order, and a frame already in the encoding but in the other
// order is re-encoded; nil keeps the order of a frame already in UTF-16 and writes the others
// little endian.
set_encoding :: proc {
	set_frame_encoding,
	set_tag_encoding,
}

// See set_encoding; version is the version of the frame's tag. A frame whose data is not its
// content gives .Not_Decodable, as does one whose layout odid3 does not decode (SYLT, GEOB, USER,
// OWNE, COMR, IPLS); a COMM, USLT or APIC whose data does not follow its layout gives
// .Bad_Content. The new data is allocated with the frame's allocator.
set_frame_encoding :: proc(
	frame: ^Frame,
	version: V2_Version,
	encoding: Encoding,
	byte_order: Maybe(Byte_Order) = nil,
) -> Error {
	if !encoding_holds(encoding, version) {
		return .Encoding_Not_In_Version
	}
	replacement, changed, refused := reencoded(frame, version, encoding, byte_order) or_return
	if refused != .None {
		return refused
	}
	if changed {
		destroy_frame(frame)
		frame^ = replacement
	}
	return nil
}

// See set_encoding. Every frame changes, or none; the frames set_frame_encoding refuses as
// .Not_Decodable, a COMM, USLT or APIC whose data does not follow its layout, empty ones, those
// with an unknown encoding byte and a CHAP or CTOC whose content does not decode are left as they
// are.
set_tag_encoding :: proc(
	tag: ^Tag,
	encoding: Encoding,
	byte_order: Maybe(Byte_Order) = nil,
) -> Error {
	adopt_context_allocator(tag)
	if tag.version == .None {
		return .No_Version
	}
	if !encoding_holds(encoding, tag.version) {
		return .Encoding_Not_In_Version
	}
	return reencode_tag(tag, encoding, byte_order)
}

// set_tag_encoding, where a nil encoding keeps each frame's.
@(private)
reencode_tag :: proc(tag: ^Tag, encoding: Maybe(Encoding), order: Maybe(Byte_Order)) -> Error {
	replacements := make([dynamic]Frame, len(tag.frames), tag.allocator) or_return
	defer {
		for &r in replacements {
			destroy_frame(&r)
		}
		delete(replacements)
	}
	changed := reencode_frames(
		tag.frames[:],
		tag.version,
		encoding,
		order,
		replacements[:],
	) or_return
	if !changed {
		return nil
	}
	for &r, i in replacements {
		if r.id != "" {
			destroy_frame(&tag.frames[i])
			tag.frames[i] = r
			r = {}
		}
	}
	return nil
}

// Fills replacements (as long as frames) with the frames whose encoding changes, CHAP and CTOC
// with their frames inside; a frame that stays has no replacement. Nothing in frames changes.
@(private)
reencode_frames :: proc(
	frames: []Frame,
	version: V2_Version,
	encoding: Maybe(Encoding),
	order: Maybe(Byte_Order),
	replacements: []Frame,
) -> (
	changed: bool,
	err: Error,
) {
	for &f, i in frames {
		replacement: Frame
		frame_changed: bool
		if is_kind(f.id, {.CHAP, .CTOC}) {
			replacement, frame_changed = reencoded_chapter(&f, version, encoding, order) or_return
		} else {
			replacement, frame_changed, _ = reencoded(&f, version, encoding, order) or_return
		}
		if frame_changed {
			replacements[i] = replacement
			changed = true
		}
	}
	return
}

// A chapter whose frames inside change encoding, encoded again. One whose content does not decode
// holds no frame odid3 can find, and stays as it is.
@(private)
reencoded_chapter :: proc(
	f: ^Frame,
	version: V2_Version,
	encoding: Maybe(Encoding),
	order: Maybe(Byte_Order),
) -> (
	replacement: Frame,
	changed: bool,
	err: Error,
) {
	if is_stored(f) || f.problem == .Nested_Chapter {
		return {}, false, nil
	}
	content := decode_owned(f, version, f.allocator) or_return
	defer destroy_content(&content, f.allocator)
	frames: ^[dynamic]Frame
	#partial switch &c in content {
	case Chapter:
		frames = &c.frames
	case Table_Of_Contents:
		frames = &c.frames
	case:
		return {}, false, nil
	}
	inner := make([]Frame, len(frames), f.allocator) or_return
	defer {
		for &r in inner {
			destroy_frame(&r)
		}
		delete(inner, f.allocator)
	}
	if !(reencode_frames(frames[:], version, encoding, order, inner) or_return) {
		return {}, false, nil
	}
	for &r, i in inner {
		if r.id != "" {
			destroy_frame(&frames[i])
			frames[i] = r
			r = {}
		}
	}
	replacement = encode_decoded_chapter(content, f.id, version, f.allocator) or_return
	keep_identity(&replacement, f)
	return replacement, true, nil
}

// A rewritten frame keeps what makes it the frame it was: its flags, group, and where it was read.
@(private)
keep_identity :: proc(replacement, f: ^Frame) {
	replacement.status = f.status
	replacement.format = f.format
	replacement.group = f.group
	replacement.method = f.method
	replacement.offset = f.offset
	replacement.size = f.size
	replacement.stored_flags = f.stored_flags
}

// The frame with its text in another encoding (nil keeps its own), UTF-16 with a byte order mark
// in order. changed is false for a frame without text, an empty one, one with an unknown encoding
// byte, one whose data is not its content or does not follow its layout, and one already in the
// encoding and order; refused is what set_frame_encoding gives for a frame odid3 does not decode,
// which set_tag_encoding leaves as it is.
@(private)
reencoded :: proc(
	f: ^Frame,
	version: V2_Version,
	asked: Maybe(Encoding),
	order: Maybe(Byte_Order),
) -> (
	replacement: Frame,
	changed: bool,
	refused: Format_Error,
	err: Error,
) {
	if !has_encoding_byte(f.id) || len(f.data) == 0 {
		return
	}
	if is_stored(f) || f.problem == .Skipped_Picture {
		return {}, false, .Not_Decodable, nil
	}
	encoding := asked.? or_else Encoding(f.data[0])
	if f.data[0] == u8(encoding) {
		wanted, ordered := order.?
		if !ordered || encoding != .UTF16 {
			return
		}
		current, mixed, known := utf16_order_of(f)
		if known && !mixed && current == wanted {
			return
		}
	}
	if _, known := encoding_of(f.data[0]); !known {
		return
	}
	// Read as ID3v2.4 reads it, so that values after the first are not lost before ID3v2.4.
	content, decode_err := decode_frame(f, .V2_4, f.allocator)
	defer destroy_content(&content, f.allocator)
	if format_err, is_format := decode_err.(Format_Error); is_format {
		return {}, false, format_err, nil
	}
	if decode_err != nil {
		return {}, false, .None, decode_err
	}
	if !text_survives(f, &content) {
		return {}, false, .None, .Bad_Content
	}
	switch &c in content {
	case Text:
		if len(c.values) > 1 && version != .V2_4 {
			join_values(&c.values, is_kind(f.id, {.TCON}), f.allocator) or_return
		}
		c.encoding = encoding
	case User_Text:
		if len(c.values) > 1 && version != .V2_4 {
			join_values(&c.values, false, f.allocator) or_return
		}
		c.encoding = encoding
	case User_Url:
		c.encoding = encoding
	case Comment:
		c.encoding = encoding
	case Picture:
		c.encoding = encoding
	case Url, Unique_File_Id, Popularimeter, Play_Counter, Private, Chapter, Table_Of_Contents:
		return
	case Binary:
		return {}, false, .Not_Decodable, nil
	}
	replacement = encode_frame_in(
		content,
		f.id,
		version,
		order.? or_else .Little_Endian,
		f.allocator,
	) or_return
	if f.data[0] == u8(encoding) && bytes.equal(replacement.data, f.data) {
		destroy_frame(&replacement)
		return {}, false, .None, nil
	}
	keep_identity(&replacement, f)
	return replacement, true, .None, nil
}

// Whether a frame's text decoded whole: nothing but NULs (a final terminator, sometimes doubled)
// follows the text of a comment or the URL of a WXXX, and every string decodes whole, read in the
// byte order decoding reads it in.
@(private)
text_survives :: proc(f: ^Frame, content: ^Frame_Content) -> bool {
	encoding, _ := encoding_of(f.data[0])
	text, _, _ := text_of(f)
	switch _ in content {
	case Text:
		return values_whole(encoding, text)
	case User_Text:
		description, values, _ := split_terminated(encoding, text)
		return(
			decodes_whole(encoding, description) &&
			values_whole(byte_order_of(encoding, description), values) \
		)
	case User_Url:
		description, url, _ := split_terminated(encoding, text)
		_, after, _ := split_terminated(.Latin1, url)
		return decodes_whole(encoding, description) && only_nuls(after)
	case Picture:
		return decodes_whole(encoding, first_string(encoding, text))
	case Comment:
		description, rest, _ := split_terminated(encoding, text)
		comment, after, _ := split_terminated(encoding, rest)
		return(
			decodes_whole(encoding, description) &&
			decodes_whole(byte_order_of(encoding, description), comment) &&
			only_nuls(after) \
		)
	case Url,
	     Unique_File_Id,
	     Popularimeter,
	     Play_Counter,
	     Private,
	     Chapter,
	     Table_Of_Contents,
	     Binary:
	}
	return true
}

// Whether the values of a text frame, read as decode_values reads them in ID3v2.4, decode whole.
@(private)
values_whole :: proc(encoding: Encoding, data: []u8) -> bool {
	order := encoding
	for rest, first := data, true; len(rest) > 0; first = false {
		value: []u8
		value, rest, _ = split_terminated(encoding, rest)
		if !decodes_whole(order, value) {
			return false
		}
		if first {
			order = byte_order_of(order, value)
		}
	}
	return true
}

@(private)
only_nuls :: proc(data: []u8) -> bool {
	for c in data {
		if c != 0 {
			return false
		}
	}
	return true
}
