package odid3

import "base:runtime"
import "core:mem"
import "core:strings"

// A frame of an ID3v2 tag. Free it with destroy.
Frame :: struct {
	id:           string, // "TIT2", or "TT2" in an ID3v2.2 tag
	status:       Frame_Status,
	format:       Frame_Format,
	group:        u8, // when format has .Grouping
	method:       u8, // the encryption method, when format has .Encryption
	data:         []u8, // the content, unless problem says otherwise
	problem:      Frame_Problem,
	offset:       i64, // of the frame header in the file; -1 for a frame not read from a file
	size:         int, // the size field of the frame header
	stored_flags: [2]u8, // the flag bytes of the frame header, as read
	data_length:  int, // data length indicator (ID3v2.4) or decompressed size (ID3v2.3); -1 if none
	allocator:    runtime.Allocator,
}

// The status flags of a frame, with the same names in ID3v2.3 and 2.4.
Frame_Status_Flag :: enum u8 {
	Discard_On_Tag_Alter,
	Discard_On_File_Alter,
	Read_Only,
}

// The status flags set on a frame.
Frame_Status :: bit_set[Frame_Status_Flag;u8]

// The format flags of a frame, with the same names in ID3v2.3 and 2.4.
Frame_Format_Flag :: enum u8 {
	Grouping,
	Compression,
	Encryption,
	Unsynchronisation, // ID3v2.4
	Data_Length_Indicator, // ID3v2.4
}

// The format flags set on a frame. Setting .Compression (ID3v2.3 and 2.4) or .Unsynchronisation
// (ID3v2.4) asks render to apply it to this frame, with the data length indicator ID3v2.4 needs.
Frame_Format :: bit_set[Frame_Format_Flag;u8]

// Why a frame's data is not its content.
Frame_Problem :: enum u8 {
	None,
	// Shorter than the bytes its format flags add: data holds all the bytes after the frame header,
	// unsynchronisation undone.
	Too_Short,
	// Read with skip_picture_data: data is nil.
	Skipped_Picture,
	// The data length indicator, or ID3v2.3's decompressed size, does not match the data: data
	// holds what was decoded.
	Bad_Data_Length,
	// Said to be unsynchronised, but its bytes cannot be (a 0xFF followed by 0xE0 or more, or last):
	// the flag lied, and data holds the bytes as stored.
	Bad_Unsynchronisation,
	// Encrypted: data holds the bytes as stored, unsynchronisation undone.
	Encrypted,
	// Compressed, but the zlib stream is damaged or inflates well past its declared size, or the
	// frame sits in a CHAP or CTOC that was compressed itself or not read from the file: data
	// holds the bytes as stored, unsynchronisation undone.
	Bad_Compression,
	// A CHAP or CTOC inside another: kept as it is but not decoded, since chapters do not nest and
	// decoding them level after level would cost memory without bound.
	Nested_Chapter,
}

// Whether a frame's data is its bytes as stored rather than its content: encrypted, badly
// compressed, too short for its flags, or compressed or encrypted behind an unsynchronisation
// flag that lied.
@(private)
is_stored :: proc(f: ^Frame) -> bool {
	lied := f.problem == .Bad_Unsynchronisation && f.format & {.Compression, .Encryption} != {}
	return(
		f.problem == .Encrypted ||
		f.problem == .Bad_Compression ||
		f.problem == .Too_Short ||
		lied \
	)
}

// The first frame with this ID or of this kind at or after start. A kind is looked for under its ID
// in the tag's version; in ID3v2.3 and 2.4 tags, which can hold one another's frames, under its 4
// letter ID even when the version does not have the frame (a TDRC in an ID3v2.3 tag). A kind
// ID3v2.2 has no ID for is never in an ID3v2.2 tag, and no kind is in a tag of version .None.
find_frame :: proc {
	find_frame_by_id,
	find_frame_by_kind,
}

// See find_frame.
find_frame_by_id :: proc(tag: ^Tag, id: string, start := 0) -> (index: int, ok: bool) {
	for i in max(start, 0) ..< len(tag.frames) {
		if tag.frames[i].id == id {
			return i, true
		}
	}
	return -1, false
}

// See find_frame.
find_frame_by_kind :: proc(tag: ^Tag, kind: Frame_Kind, start := 0) -> (index: int, ok: bool) {
	id := id_in_tag(kind, tag.version)
	if id == "" {
		return -1, false
	}
	return find_frame_by_id(tag, id, start)
}

// A new frame with copies of id and data, owned by allocator; its offset is -1. Made from a kind,
// it takes the kind's ID in version, and gives .Not_In_Version when the version does not have the
// frame (see frame_id), .No_Version for .None. data is the caller's, in that version's layout: a
// PIC holds a 3 letter image format where an APIC holds a MIME type.
make_frame :: proc {
	make_frame_by_id,
	make_frame_by_kind,
}

// See make_frame.
make_frame_by_id :: proc(
	id: string,
	data: []u8,
	allocator := context.allocator,
) -> (
	frame: Frame,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	frame = {
		offset      = -1,
		data_length = -1,
		allocator   = allocator,
	}
	frame.id = strings.clone(id, allocator) or_return
	if len(data) > 0 {
		frame.data, err = make([]u8, len(data), allocator)
		if err != nil {
			delete(frame.id, allocator)
			return {}, err
		}
		copy(frame.data, data)
	}
	return
}

// See make_frame.
make_frame_by_kind :: proc(
	kind: Frame_Kind,
	data: []u8,
	version: V2_Version,
	allocator := context.allocator,
) -> (
	frame: Frame,
	err: Error,
) {
	if version == .None {
		return {}, .No_Version
	}
	id, ok := frame_id(kind, version)
	if !ok {
		return {}, .Not_In_Version
	}
	return make_frame_by_id(id, data, allocator)
}

// Adds a frame at the end of a tag, which takes ownership of it.
add_frame :: proc(tag: ^Tag, frame: Frame) -> runtime.Allocator_Error {
	adopt_context_allocator(tag)
	_, err := append(&tag.frames, frame)
	return err
}

// Removes the frame at index from a tag and frees it.
remove_frame :: proc(tag: ^Tag, index: int) {
	if index < 0 || index >= len(tag.frames) {
		return
	}
	destroy_frame(&tag.frames[index])
	ordered_remove(&tag.frames, index)
}

// Frees what a frame holds and resets it.
destroy_frame :: proc(frame: ^Frame) {
	delete(frame.id, frame.allocator)
	delete(frame.data, frame.allocator)
	frame^ = {}
}

@(private)
FRAME_HEADER_SIZE :: 10
@(private)
V22_FRAME_HEADER_SIZE :: 6

// ID3v2.2 frame headers are 6 bytes: a 3 character ID and a 24-bit size, without flags. Later
// versions use 10: a 4 character ID, a 32-bit size and 2 flag bytes.
@(private)
frame_header_size :: proc(version: V2_Version) -> i64 {
	return V22_FRAME_HEADER_SIZE if version == .V2_2 else FRAME_HEADER_SIZE
}

@(private)
frame_id_len :: proc(version: V2_Version) -> int {
	return 3 if version == .V2_2 else 4
}

// No real tag comes near it, but a tag of empty frames costs up to about 33 times its size in
// memory (ID3v2.2's 6 byte frames, while the array of frames grows).
@(private)
MAX_FRAMES :: 1 << 16

// The frames and padding of a tag, as positions in src. When unsynchronisation was undone for the
// whole tag, src holds the decoded bytes: base is where they start in the file, and removed lists
// the decoded positions where a byte was taken out, to find frames in the file again.
@(private)
Body :: struct {
	src:           ^Source,
	start:         i64,
	end:           i64,
	truncated:     bool,
	plain_sizes:   bool, // ID3v2.4: a frame size was a plain integer, so later ones probably are
	version:       V2_Version, // the layout of the frames
	base:          i64,
	removed:       []u32,
	unsync_frames: bool, // ID3v2.4: the tag header says every frame is unsynchronised
	no_inflation:  bool, // frames in a CHAP or CTOC whose own bytes came from inflation
}

@(private)
file_offset :: proc(body: ^Body, pos: i64) -> i64 {
	low, high := 0, len(body.removed)
	for low < high {
		mid := (low + high) / 2
		if i64(body.removed[mid]) <= pos {
			low = mid + 1
		} else {
			high = mid
		}
	}
	return body.base + pos + i64(low)
}

// Unsynchronisation keeps a tag from holding a false MPEG frame sync (0xFF then a byte of 0xE0 or
// more) that an old player could mistake for audio: writing puts a 0x00 after every 0xFF followed
// by such a byte or by 0x00, and after a last 0xFF; reading takes out the 0x00 after every 0xFF.
// So unsynchronised bytes never hold a 0xFF followed by 0xE0 or more, nor end with 0xFF: when they
// do, the flag lied and valid is false (mutagen checks the same). Works in place; removed, when
// given, gets the positions of the output where a byte was taken out.
@(private)
undo_unsynchronisation :: proc(
	data: []u8,
	removed: ^[dynamic]u32 = nil,
) -> (
	out: []u8,
	valid: bool,
	err: Error,
) {
	for c, i in data {
		if c == 0xFF && (i + 1 == len(data) || data[i + 1] >= 0xE0) {
			return data, false, nil
		}
	}
	n := 0
	for i := 0; i < len(data); i += 1 {
		data[n] = data[i]
		n += 1
		if data[i] == 0xFF && i + 1 < len(data) && data[i + 1] == 0 {
			if removed != nil {
				append(removed, u32(n)) or_return
			}
			i += 1
		}
	}
	return data[:n], true, nil
}

// Appends parts, read as one stream, unsynchronised: a 0x00 after every 0xFF followed by 0x00 or a
// byte of 0xE0 or more, and after a last 0xFF. Room for them is made once.
@(private)
unsynchronise :: proc(out: ^[dynamic]u8, parts: ..[]u8) -> runtime.Allocator_Error {
	at := len(out)
	resize(out, at + unsynchronised_size(..parts)) or_return
	for part, p in parts {
		for c, i in part {
			out[at] = c
			at += 1
			if c == 0xFF && needs_zero(parts, p, i) {
				out[at] = 0
				at += 1
			}
		}
	}
	return nil
}

// The size of parts once unsynchronised, so that a size limit is checked before anything grows.
@(private)
unsynchronised_size :: proc(parts: ..[]u8) -> int {
	n := 0
	for part, p in parts {
		n += len(part)
		for c, i in part {
			if c == 0xFF && needs_zero(parts, p, i) {
				n += 1
			}
		}
	}
	return n
}

// Whether the 0xFF at parts[p][i] needs a 0x00 after it: the next byte of the stream is 0x00 or
// 0xE0 or more, or there is none.
@(private)
needs_zero :: proc(parts: [][]u8, p, i: int) -> bool {
	if i + 1 < len(parts[p]) {
		next := parts[p][i + 1]
		return next >= 0xE0 || next == 0
	}
	for part in parts[p + 1:] {
		if len(part) > 0 {
			return part[0] >= 0xE0 || part[0] == 0
		}
	}
	return true
}

// Gives a slice shrunk in place its new size in its allocation: some allocators need the size a
// block was allocated with when it is freed.
@(private)
shrink :: proc(data: []u8, n: int, allocator: runtime.Allocator) -> (out: []u8, err: Error) {
	if n == len(data) {
		return data, nil
	}
	if n == 0 {
		delete(data, allocator)
		return nil, nil
	}
	return mem.resize_bytes(data, n, allocator = allocator)
}

// What can follow a frame.
@(private)
Frame_Start :: enum u8 {
	Nothing,
	Frame,
	Padding,
	End,
}

@(private)
Frame_Header :: struct {
	id:    [4]u8,
	size:  i64,
	flags: [2]u8,
}

@(private)
read_frames :: proc(tag: ^Tag, body: ^Body, options: Read_Options, warnings: ^Warnings) -> Error {
	header_size := frame_header_size(tag.version)
	id_len := frame_id_len(tag.version)
	pos := body.start
	for pos < body.end {
		buf: [FRAME_HEADER_SIZE]u8
		head := source_bytes(body.src, pos, buf[:min(body.end - pos, header_size)]) or_return
		if len(head) == 0 {
			return nil
		}
		if head[0] == 0 {
			read_padding(tag, body, pos, warnings) or_return
			return nil
		}
		if i64(len(head)) < header_size || head[0] < 'A' || head[0] > 'Z' {
			report_damage(body, warnings)
			return nil
		}
		h := Frame_Header{}
		copy(h.id[:], head[:id_len])
		if tag.version == .V2_2 {
			h.size = i64(be24(head[3:6]))
		} else {
			copy(h.flags[:], head[8:10])
			h.size = frame_size(body, pos, tag.version, head[4:8], warnings) or_return
		}
		next := pos + header_size + h.size
		if h.size < 0 || next > body.end {
			report_damage(body, warnings)
			return nil
		}
		if !is_frame_id(head[:id_len]) {
			// Some taggers wrote odd IDs, such as ID3v2.2's 3 letters and a NUL in an ID3v2.3 tag:
			// such a frame is kept when its size leads to what can follow a frame.
			if (frame_start_at(body, next) or_return) == .Nothing {
				report_damage(body, warnings)
				return nil
			}
			warnings^ += {.Bad_Frame_Ids}
		}
		if len(tag.frames) >= MAX_FRAMES {
			warnings^ += {.Too_Many_Frames}
			return nil
		}
		frame := read_frame(body, pos, h, tag.version, options, tag.allocator) or_return
		#partial switch frame.problem {
		case .Too_Short, .Bad_Data_Length, .Bad_Unsynchronisation, .Bad_Compression:
			warnings^ += {.Frame_Problems}
		}
		if _, append_err := append(&tag.frames, frame); append_err != nil {
			destroy_frame(&frame)
			return append_err
		}
		pos = next
	}
	return nil
}

// A frame that cannot be right ends the frames. In a truncated tag, Truncated_Tag already says so.
@(private)
report_damage :: proc(body: ^Body, warnings: ^Warnings) {
	if !body.truncated {
		warnings^ += {.Damaged_Frames}
	}
}

@(private)
is_frame_id :: proc(b: []u8) -> bool {
	for c in b {
		if !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}

@(private)
be32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}

@(private)
be24 :: proc(b: []u8) -> u32 {
	return u32(b[0]) << 16 | u32(b[1]) << 8 | u32(b[2])
}

// iTunes wrote ID3v2.2's PIC, with a NUL, in some ID3v2.3 tags.
@(private)
is_picture_id :: proc(id: string, version: V2_Version) -> bool {
	if version == .V2_2 {
		return id == id_in_tag(.APIC, .V2_2)
	}
	return id == id_in_tag(.APIC, .V2_3) || id == "PIC\x00"
}

// ID3v2.4 frame sizes are syncsafe, but iTunes wrote plain integers for years (mutagen's
// determine_bpi in mutagen/id3/_tags.py deals with it too). When the two readings differ, the one
// that leads to another frame or to the end of the tag wins, then the one that leads to padding;
// once a plain size wins, plain sizes win ties for the rest of the tag. -1 when neither can be
// right.
@(private)
frame_size :: proc(
	body: ^Body,
	pos: i64,
	version: V2_Version,
	b: []u8,
	warnings: ^Warnings,
) -> (
	size: i64,
	err: Error,
) {
	plain := i64(be32(b))
	if version != .V2_4 {
		return plain, nil
	}
	value, ok := syncsafe(b)
	safe := i64(value)
	if ok && safe == plain {
		return safe, nil
	}
	rank :: proc(start: Frame_Start) -> int {
		#partial switch start {
		case .Frame, .End:
			return 2
		case .Padding:
			return 1
		}
		return 0
	}
	safe_rank := 0
	if ok {
		safe_rank = rank(frame_start_at(body, pos + FRAME_HEADER_SIZE + safe) or_return)
	}
	plain_rank := rank(frame_start_at(body, pos + FRAME_HEADER_SIZE + plain) or_return)
	if plain_rank > safe_rank || (plain_rank > 0 && plain_rank == safe_rank && body.plain_sizes) {
		warnings^ += {.Plain_Frame_Sizes}
		body.plain_sizes = true
		return plain, nil
	}
	if ok {
		return safe, nil
	}
	return -1, nil
}

@(private)
frame_start_at :: proc(body: ^Body, at: i64) -> (start: Frame_Start, err: Error) {
	if at == body.end {
		return .End, nil
	}
	if at > body.end || at < body.start {
		return .Nothing, nil
	}
	buf: [4]u8
	id_len := frame_id_len(body.version)
	b := source_bytes(body.src, at, buf[:min(body.end - at, i64(id_len))]) or_return
	switch {
	case len(b) > 0 && b[0] == 0:
		return .Padding, nil
	case len(b) == id_len && is_frame_id(b):
		return .Frame, nil
	}
	return .Nothing, nil
}

@(private)
read_frame :: proc(
	body: ^Body,
	pos: i64,
	h: Frame_Header,
	version: V2_Version,
	options: Read_Options,
	allocator: runtime.Allocator,
) -> (
	f: Frame,
	err: Error,
) {
	f.allocator = allocator
	f.offset = file_offset(body, pos)
	f.size = int(h.size)
	f.stored_flags = h.flags
	f.status = frame_status(version, h.flags[0])
	f.format = frame_format(version, h.flags[1])
	f.data_length = -1
	id := h.id
	f.id = strings.clone(string(id[:frame_id_len(version)]), allocator) or_return
	defer if err != nil {
		destroy_frame(&f)
	}
	if options.skip_picture_data && is_picture_id(f.id, version) {
		f.problem = .Skipped_Picture
		return
	}
	f.data = make([]u8, h.size, allocator) or_return
	source_read(body.src, pos + frame_header_size(version), f.data) or_return
	// ID3v2.4 unsynchronises everything after the frame header, the bytes the flags add included.
	if version == .V2_4 && (.Unsynchronisation in f.format || body.unsync_frames) {
		decoded, valid := undo_unsynchronisation(f.data) or_return
		if valid {
			f.data = shrink(f.data, len(decoded), allocator) or_return
			// Flagged in the tag header alone, the frame is unsynchronised all the same.
			f.format += {.Unsynchronisation}
		} else {
			f.problem = .Bad_Unsynchronisation
		}
	}
	extras := split_frame_extras(&f, version)
	copy(f.data, f.data[extras:])
	f.data = shrink(f.data, len(f.data) - extras, allocator) or_return
	switch {
	case f.problem != .None:
		return
	case .Encryption in f.format:
		f.problem = .Encrypted
		return
	case .Compression in f.format && body.no_inflation:
		f.problem = .Bad_Compression
		return
	case .Compression in f.format:
		inflated, ok := inflate_frame(f.data, i64(f.data_length), allocator) or_return
		if !ok {
			f.problem = .Bad_Compression
			return
		}
		delete(f.data, allocator)
		f.data = inflated
	}
	if f.problem == .None && f.data_length >= 0 && f.data_length != len(f.data) {
		f.problem = .Bad_Data_Length
	}
	return
}

// The bytes a frame's format flags add before its content: in ID3v2.3 the decompressed size, the
// encryption method and the group, in ID3v2.4 the group, the encryption method and the data length
// indicator. Reads them from the start of the frame's data and returns how many there are, 0 when
// the frame is too short to hold them.
@(private)
split_frame_extras :: proc(f: ^Frame, version: V2_Version) -> (n: int) {
	fields: [3]struct {
		flag: Frame_Format_Flag,
		size: int,
	}
	switch version {
	case .V2_3:
		fields = {{.Compression, 4}, {.Encryption, 1}, {.Grouping, 1}}
	case .V2_4:
		fields = {{.Grouping, 1}, {.Encryption, 1}, {.Data_Length_Indicator, 4}}
	case .V2_2, .None:
		return 0
	}
	for field in fields {
		if field.flag in f.format {
			n += field.size
		}
	}
	if n > len(f.data) {
		f.problem = .Too_Short
		return 0
	}
	at := 0
	for field in fields {
		if field.flag not_in f.format {
			continue
		}
		b := f.data[at:]
		#partial switch field.flag {
		case .Grouping:
			f.group = b[0]
		case .Encryption:
			f.method = b[0]
		case .Compression:
			f.data_length = int(be32(b[:4]))
		case .Data_Length_Indicator:
			length, ok := syncsafe(b[:4])
			f.data_length = int(length) if ok else int(be32(b[:4]))
		}
		at += field.size
	}
	return n
}

@(private)
frame_status :: proc(version: V2_Version, b: u8) -> (status: Frame_Status) {
	shift: u8 = 1 if version == .V2_4 else 0
	if b & (0x80 >> shift) != 0 {
		status += {.Discard_On_Tag_Alter}
	}
	if b & (0x40 >> shift) != 0 {
		status += {.Discard_On_File_Alter}
	}
	if b & (0x20 >> shift) != 0 {
		status += {.Read_Only}
	}
	return
}

@(private)
frame_format :: proc(version: V2_Version, b: u8) -> (format: Frame_Format) {
	for bit, flag in format_bits(version) {
		if bit != 0 && b & bit != 0 {
			format += {flag}
		}
	}
	return
}

// Where each format flag sits in a frame header; 0 for a flag the version does not have.
@(private)
format_bits :: proc(version: V2_Version) -> [Frame_Format_Flag]u8 {
	if version == .V2_4 {
		return {
			.Grouping = 0x40,
			.Compression = 0x08,
			.Encryption = 0x04,
			.Unsynchronisation = 0x02,
			.Data_Length_Indicator = 0x01,
		}
	}
	if version == .V2_3 {
		return {
			.Compression = 0x80,
			.Encryption = 0x40,
			.Grouping = 0x20,
			.Unsynchronisation = 0,
			.Data_Length_Indicator = 0,
		}
	}
	return {}
}

// Padding is zeros after the last frame. Anything else there is reported, since rewriting the tag
// loses it.
@(private)
read_padding :: proc(tag: ^Tag, body: ^Body, start: i64, warnings: ^Warnings) -> Error {
	tag.padding = int(file_offset(body, body.end) - file_offset(body, start))
	buf: [4096]u8
	for pos := start; pos < body.end; {
		chunk := source_bytes(body.src, pos, buf[:min(body.end - pos, len(buf))]) or_return
		if len(chunk) == 0 {
			break
		}
		for c in chunk {
			if c != 0 {
				warnings^ += {.Data_In_Padding}
				return nil
			}
		}
		pos += i64(len(chunk))
	}
	return nil
}

// Reads the frames inside a CHAP or CTOC frame, laid out as in a tag of the same version. Their
// offset is -1: they are not read straight from the file. Inflating frames whose bytes were
// inflated already would let a few bytes of the file grow without bound, so they are only inflated
// when parent comes straight from the file, compressed neither itself nor as part of another frame.
@(private)
read_embedded_frames :: proc(
	data: []u8,
	parent: ^Frame,
	version: V2_Version,
	allocator: runtime.Allocator,
) -> (
	frames: [dynamic]Frame,
	warnings: Warnings,
	err: Error,
) {
	src := memory_source(data)
	body := Body {
		src          = &src,
		end          = i64(len(data)),
		version      = version,
		no_inflation = parent.offset < 0 || .Compression in parent.format,
	}
	tag := Tag {
		version   = version,
		frames    = make([dynamic]Frame, allocator),
		allocator = allocator,
	}
	if err = read_frames(&tag, &body, {}, &warnings); err != nil {
		destroy_tag(&tag)
		return nil, {}, err
	}
	for &f in tag.frames {
		f.offset = -1
		if is_kind(f.id, {.CHAP, .CTOC}) && f.problem == .None {
			f.problem = .Nested_Chapter
		}
	}
	return tag.frames, warnings, nil
}
