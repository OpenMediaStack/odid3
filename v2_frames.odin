package odid3

import "base:runtime"
import "core:strings"

// A frame of an ID3v2 tag. Free it with destroy.
Frame :: struct {
	id:           string, // "TIT2", or "TT2" in an ID3v2.2 tag
	status:       Frame_Status,
	format:       Frame_Format,
	group:        u8, // when format has .Grouping
	method:       u8, // the encryption method, when format has .Encryption
	data:         []u8, // as stored, without the bytes the format flags add
	problem:      Frame_Problem,
	offset:       i64, // of the frame header in the file; -1 for a frame not read from a file
	size:         int, // the size field of the frame header
	stored_flags: [2]u8, // the flag bytes of the frame header, as read
	data_length:  int, // the data length indicator (ID3v2.4) or decompressed size (ID3v2.3); -1 if none
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

// The format flags set on a frame.
Frame_Format :: bit_set[Frame_Format_Flag;u8]

// Why a frame's data is not its content.
Frame_Problem :: enum u8 {
	None,
	// Shorter than the bytes its format flags add: data holds the bytes as stored.
	Too_Short,
	// Read with skip_picture_data: data is nil.
	Skipped_Picture,
}

// The first frame with this ID at or after start.
find_frame :: proc(tag: ^Tag, id: string, start := 0) -> (index: int, ok: bool) {
	for i in max(start, 0) ..< len(tag.frames) {
		if tag.frames[i].id == id {
			return i, true
		}
	}
	return -1, false
}

// Frees what a frame holds and resets it.
destroy_frame :: proc(frame: ^Frame) {
	delete(frame.id, frame.allocator)
	delete(frame.data, frame.allocator)
	frame^ = {}
}

@(private)
FRAME_HEADER_SIZE :: 10

// The frames and padding of a tag, as positions in src.
@(private)
Body :: struct {
	src:         ^Source,
	start:       i64,
	end:         i64,
	truncated:   bool,
	plain_sizes: bool, // ID3v2.4: a frame size was a plain integer, so later ones probably are
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
	pos := body.start
	for pos < body.end {
		buf: [FRAME_HEADER_SIZE]u8
		head := source_bytes(body.src, pos, buf[:min(body.end - pos, FRAME_HEADER_SIZE)]) or_return
		if len(head) == 0 {
			return nil
		}
		if head[0] == 0 {
			read_padding(tag, body, pos, warnings) or_return
			return nil
		}
		if len(head) < FRAME_HEADER_SIZE || head[0] < 'A' || head[0] > 'Z' {
			report_damage(body, warnings)
			return nil
		}
		h := Frame_Header{}
		copy(h.id[:], head[:4])
		copy(h.flags[:], head[8:10])
		h.size = frame_size(body, pos, tag.version, head[4:8], warnings) or_return
		next := pos + FRAME_HEADER_SIZE + h.size
		if h.size < 0 || next > body.end {
			report_damage(body, warnings)
			return nil
		}
		if !is_frame_id(head[:4]) {
			// Some taggers wrote odd IDs, such as ID3v2.2's 3 letters and a NUL in an ID3v2.3 tag:
			// such a frame is kept when its size leads to what can follow a frame.
			if (frame_start_at(body, next) or_return) == .Nothing {
				report_damage(body, warnings)
				return nil
			}
			warnings^ += {.Bad_Frame_Ids}
		}
		frame := read_frame(body, pos, h, tag.version, options, tag.allocator) or_return
		if frame.problem == .Too_Short {
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

// ID3v2.4 frame sizes are syncsafe, but iTunes wrote plain integers for years (mutagen's
// determine_bpi in mutagen/id3/_tags.py deals with it too). When the two readings differ, the one
// that leads to another frame or to the end of the tag wins, then the one that leads to padding; once
// a plain size wins, plain sizes win ties for the rest of the tag. -1 when neither can be right.
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
	b := source_bytes(body.src, at, buf[:min(body.end - at, 4)]) or_return
	switch {
	case len(b) > 0 && b[0] == 0:
		return .Padding, nil
	case len(b) == 4 && is_frame_id(b):
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
	f.offset = pos
	f.size = int(h.size)
	f.stored_flags = h.flags
	f.status = frame_status(version, h.flags[0])
	f.format = frame_format(version, h.flags[1])
	f.data_length = -1
	id := h.id
	f.id = strings.clone(string(id[:]), allocator) or_return
	defer if err != nil {
		destroy_frame(&f)
	}
	if options.skip_picture_data && f.id == "APIC" {
		f.problem = .Skipped_Picture
		return
	}
	f.data = make([]u8, h.size, allocator) or_return
	source_read(body.src, pos + FRAME_HEADER_SIZE, f.data) or_return
	extras := split_frame_extras(&f, version)
	copy(f.data, f.data[extras:])
	f.data = f.data[:len(f.data) - extras]
	return
}

// The bytes a frame's format flags add before its content: in ID3v2.3 the decompressed size, the
// encryption method and the group, in ID3v2.4 the group, the encryption method and the data length
// indicator. Reads them from the start of the frame's data and returns how many there are, 0 when the
// frame is too short to hold them.
@(private)
split_frame_extras :: proc(f: ^Frame, version: V2_Version) -> (n: int) {
	fields: [3]struct {
		flag: Frame_Format_Flag,
		size: int,
	}
	if version == .V2_3 {
		fields = {{.Compression, 4}, {.Encryption, 1}, {.Grouping, 1}}
	} else {
		fields = {{.Grouping, 1}, {.Encryption, 1}, {.Data_Length_Indicator, 4}}
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
	bits: [Frame_Format_Flag]u8
	if version == .V2_4 {
		bits = {
			.Grouping              = 0x40,
			.Compression           = 0x08,
			.Encryption            = 0x04,
			.Unsynchronisation     = 0x02,
			.Data_Length_Indicator = 0x01,
		}
	} else {
		bits = {
			.Compression           = 0x80,
			.Encryption            = 0x40,
			.Grouping              = 0x20,
			.Unsynchronisation     = 0,
			.Data_Length_Indicator = 0,
		}
	}
	for bit, flag in bits {
		if bit != 0 && b & bit != 0 {
			format += {flag}
		}
	}
	return
}

// Padding is zeros after the last frame. Anything else there is reported, since rewriting the tag
// loses it.
@(private)
read_padding :: proc(tag: ^Tag, body: ^Body, start: i64, warnings: ^Warnings) -> Error {
	tag.padding = int(body.end - start)
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
