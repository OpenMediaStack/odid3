package odid3

import "base:runtime"
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

// APIC, or PIC in ID3v2.2.
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
	switch {
	case id == "TXXX" || id == "TXX":
		content = decode_user_text(data, version, allocator) or_return
	case len(id) > 0 && id[0] == 'T' || is_itunes_text_frame(id):
		content = decode_text_frame(data, version, allocator) or_return
	case id == "WXXX" || id == "WXX":
		content = decode_user_url(data, allocator) or_return
	case len(id) > 0 && id[0] == 'W':
		url := decode_latin1(first_string(.Latin1, data), allocator) or_return
		content = Url{url}
	case id == "COMM" || id == "COM" || id == "USLT" || id == "ULT":
		content = decode_comment(data, allocator) or_return
	case id == "APIC" || id == "PIC":
		content = decode_picture(data, id == "PIC", allocator) or_return
	case id == "UFID" || id == "UFI":
		owner, identifier := decode_owned_bytes(data, allocator) or_return
		content = Unique_File_Id{owner, identifier}
	case id == "POPM" || id == "POP":
		content = decode_popularimeter(data, allocator) or_return
	case id == "PCNT" || id == "CNT":
		content = Play_Counter{big_endian_counter(data)}
	case id == "PRIV":
		owner, private := decode_owned_bytes(data, allocator) or_return
		content = Private{owner, private}
	case id == "CHAP":
		content = decode_chapter(frame, version, allocator) or_return
	case id == "CTOC":
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
	switch id {
	case "WFED", "GRP1", "MVNM", "MVIN":
		return true
	}
	return false
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
// are joined with "/", as mutagen does.
encode_frame :: proc(
	content: Frame_Content,
	id: string,
	version: V2_Version,
	allocator := context.allocator,
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
		encode_values(&data, c.encoding, c.values, version) or_return
	case User_Text:
		start_text(&data, c.encoding, version) or_return
		encode_string(&data, c.encoding, c.description, true) or_return
		encode_values(&data, c.encoding, c.values, version) or_return
	case Url:
		encode_string(&data, .Latin1, c.url, false) or_return
	case User_Url:
		start_text(&data, c.encoding, version) or_return
		encode_string(&data, c.encoding, c.description, true) or_return
		encode_string(&data, .Latin1, c.url, false) or_return
	case Comment:
		start_text(&data, c.encoding, version) or_return
		language := c.language
		append(&data, ..language[:]) or_return
		encode_string(&data, c.encoding, c.description, true) or_return
		encode_string(&data, c.encoding, c.text, false) or_return
	case Picture:
		start_text(&data, c.encoding, version) or_return
		if version == .V2_2 {
			append(&data, v22_image_format(c.mime)) or_return
		} else {
			encode_string(&data, .Latin1, c.mime, true) or_return
		}
		append(&data, u8(c.type)) or_return
		encode_string(&data, c.encoding, c.description, true) or_return
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
		for &f in c.frames {
			render_frame(&data, &f, version) or_return
		}
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
		for &f in c.frames {
			render_frame(&data, &f, version) or_return
		}
	case Binary:
		append(&data, ..c.data) or_return
	case:
		return {}, .Bad_Content
	}
	allocated := ([^]u8)(raw_data(data))[:cap(data)]
	frame.data = shrink(allocated, len(data), allocator) or_return
	frame.id = strings.clone(id, allocator) or_return
	frame.allocator = allocator
	frame.offset = -1
	frame.data_length = -1
	return frame, nil
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
) -> Error {
	ok := append_encoded(data, encoding, s) or_return
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
) -> Error {
	if version != .V2_4 && len(values) > 1 {
		joined := strings.join(values, "/", data.allocator) or_return
		defer delete(joined, data.allocator)
		return encode_string(data, encoding, joined, false)
	}
	for value, i in values {
		if i > 0 {
			append_terminator(data, encoding) or_return
		}
		encode_string(data, encoding, value, false) or_return
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
	case strings.equal_fold(mime, "image/jpeg"), strings.equal_fold(mime, "image/jpg"):
		return "JPG"
	case strings.equal_fold(mime, "image/png"):
		return "PNG"
	case strings.equal_fold(mime, "image/gif"):
		return "GIF"
	case strings.equal_fold(mime, "image/bmp"):
		return "BMP"
	case len(mime) == 3:
		return mime
	}
	return "-->" if mime == "-->" else "\x00\x00\x00"
}
