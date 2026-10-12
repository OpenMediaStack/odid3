package odid3

import "base:runtime"

// The version of an ID3v2 tag. None means there is no tag.
V2_Version :: enum u8 {
	None,
	V2_2,
	V2_3,
	V2_4,
}

// The flags of an ID3v2 tag header, with the same names in every version.
Tag_Flag :: enum u8 {
	Unsynchronisation,
	Extended_Header, // ID3v2.3 and 2.4
	Experimental, // ID3v2.3 and 2.4
	Footer, // ID3v2.4
	Compression, // ID3v2.2
}

// The flags set in an ID3v2 tag header.
Tag_Flags :: bit_set[Tag_Flag;u8]

// An ID3v2 tag. Free it with destroy.
Tag :: struct {
	version:   V2_Version,
	revision:  u8,
	flags:     Tag_Flags,
	extended:  Extended_Header,
	frames:    [dynamic]Frame,
	padding:   int, // bytes of padding after the frames, as read
	allocator: runtime.Allocator,
}

// The extended header of an ID3v2.3 or 2.4 tag, as read. Writing drops it.
Extended_Header :: struct {
	present:      bool,
	crc:          Maybe(u32), // of the frames, plus the padding in ID3v2.4
	padding_size: u32, // ID3v2.3
	update:       bool, // ID3v2.4: this tag updates an earlier one
	restrictions: Maybe(u8), // ID3v2.4, the raw byte
}

@(private)
V2_HEADER_SIZE :: 10
@(private)
V2_FOOTER_SIZE :: 10

@(private)
V2_Header :: struct {
	major:    u8,
	revision: u8,
	flags:    u8,
	size:     i64, // after the header, without the footer
}

@(private)
Header_Status :: enum u8 {
	Absent,
	Valid,
	Bad,
}

// A header is "ID3", two version bytes that are never 0xFF, a flags byte and a syncsafe size.
@(private)
parse_v2_header :: proc(b: []u8) -> (h: V2_Header, status: Header_Status) {
	if len(b) < V2_HEADER_SIZE || string(b[:3]) != "ID3" {
		return {}, .Absent
	}
	size, ok := syncsafe(b[6:10])
	if !ok || b[3] == 0xFF || b[4] == 0xFF {
		return {}, .Bad
	}
	return {major = b[3], revision = b[4], flags = b[5], size = i64(size)}, .Valid
}

// Syncsafe integers keep the high bit of every byte at 0, so that no size in a tag can look like
// the 11 set bits that start an MPEG audio frame: 4 bytes hold 28 bits.
@(private)
syncsafe :: proc(b: []u8) -> (n: u32, ok: bool) {
	for c in b {
		if c & 0x80 != 0 {
			return 0, false
		}
		n = n << 7 | u32(c)
	}
	return n, true
}

@(private)
v2_version :: proc(major: u8) -> V2_Version {
	switch major {
	case 2:
		return .V2_2
	case 3:
		return .V2_3
	case 4:
		return .V2_4
	}
	return .None
}

@(private)
v2_total_size :: proc(h: V2_Header) -> i64 {
	total := V2_HEADER_SIZE + h.size
	if .Footer in tag_flags(h.major, h.flags) {
		total += V2_FOOTER_SIZE
	}
	return total
}

@(private)
tag_flags :: proc(major, b: u8) -> (flags: Tag_Flags) {
	if b & 0x80 != 0 {
		flags += {.Unsynchronisation}
	}
	if major == 2 {
		if b & 0x40 != 0 {
			flags += {.Compression}
		}
		return
	}
	if b & 0x40 != 0 {
		flags += {.Extended_Header}
	}
	if b & 0x20 != 0 {
		flags += {.Experimental}
	}
	if major == 4 && b & 0x10 != 0 {
		flags += {.Footer}
	}
	return
}

@(private)
read_v2_tag :: proc(
	src: ^Source,
	range: Range,
	header: V2_Header,
	options: Read_Options,
	warnings: ^Warnings,
	allocator: runtime.Allocator,
) -> (
	tag: Tag,
	err: Error,
) {
	tag = {
		version   = v2_version(header.major),
		revision  = header.revision,
		flags     = tag_flags(header.major, header.flags),
		frames    = make([dynamic]Frame, allocator),
		allocator = allocator,
	}
	defer if err != nil {
		destroy_tag(&tag)
	}
	if .Compression in tag.flags {
		warnings^ += {.Compressed_V22_Tag}
		return
	}
	end := range.offset + V2_HEADER_SIZE + header.size
	body := Body {
		src       = src,
		start     = range.offset + V2_HEADER_SIZE,
		end       = min(end, src.size),
		truncated = end > src.size,
	}
	raw: []u8
	removed: [dynamic]u32
	memory: Source
	defer {
		delete(raw, allocator)
		delete(removed)
	}
	if .Unsynchronisation in tag.flags {
		if tag.version == .V2_4 {
			body.unsync_frames = true
		} else {
			// Before ID3v2.4, the whole tag is unsynchronised, frame headers included: the frames
			// can only be split once it is undone.
			removed = make([dynamic]u32, allocator)
			raw = make([]u8, body.end - body.start, allocator) or_return
			source_read(src, body.start, raw) or_return
			decoded, valid := undo_unsynchronisation(raw, &removed) or_return
			if valid {
				memory = memory_source(decoded)
				body.src = &memory
				body.base = body.start
				body.removed = removed[:]
				body.start, body.end = 0, i64(len(decoded))
			} else {
				warnings^ += {.Bad_Unsynchronisation}
			}
		}
	}
	if .Extended_Header in tag.flags {
		start, ok := read_extended_header(&tag, &body, warnings) or_return
		if ok {
			body.start = start
		} else if (frame_start_at(&body, body.start) or_return) != .Frame {
			return
		}
		// Otherwise the flag lied, as some taggers' did: the frames start right after the header.
	}
	read_frames(&tag, &body, options, warnings) or_return
	return
}

// Reads the extended header at the start of the body and returns where the frames start. ok is
// false when the size of the extended header cannot be trusted.
@(private)
read_extended_header :: proc(
	tag: ^Tag,
	body: ^Body,
	warnings: ^Warnings,
) -> (
	frames_start: i64,
	ok: bool,
	err: Error,
) {
	buf: [16]u8
	b := source_bytes(body.src, body.start, buf[:min(body.end - body.start, len(buf))]) or_return
	available := body.end - body.start
	size: i64
	good: bool
	if tag.version == .V2_3 {
		size, good = extended_header_v23(tag, b)
	} else {
		size, good = extended_header_v24(tag, b)
	}
	if !good {
		warnings^ += {.Bad_Extended_Header}
	}
	if size <= 0 || size > available {
		warnings^ += {.Bad_Extended_Header}
		return 0, false, nil
	}
	return body.start + size, true, nil
}

// An ID3v2.3 extended header: its size without these 4 bytes (6, or 10 with a CRC), 2 flag bytes
// (0x80 means a CRC follows), the padding size, then the CRC.
@(private)
extended_header_v23 :: proc(tag: ^Tag, b: []u8) -> (size: i64, good: bool) {
	if len(b) < 10 {
		return 0, false
	}
	content := be32(b[0:4])
	size = 4 + i64(content)
	has_crc := b[4] & 0x80 != 0
	if content != 6 && content != 10 || has_crc != (content == 10) || len(b) < int(size) {
		return size, false
	}
	tag.extended = {
		present      = true,
		padding_size = be32(b[6:10]),
	}
	if has_crc {
		tag.extended.crc = be32(b[10:14])
	}
	return size, true
}

// An ID3v2.4 extended header: its syncsafe size, these 4 bytes included, the number of flag bytes
// (always 1), the flags, then for each flag set, the length of its data and the data: nothing for
// an update, a CRC-32 as 5 syncsafe bytes, the restrictions byte.
@(private)
extended_header_v24 :: proc(tag: ^Tag, b: []u8) -> (size: i64, good: bool) {
	if len(b) < 6 {
		return 0, false
	}
	n, syncsafe_ok := syncsafe(b[0:4])
	size = i64(n)
	if !syncsafe_ok || size < 6 || b[4] != 1 || len(b) < int(min(size, 16)) {
		return size if syncsafe_ok else 0, false
	}
	flags := b[5]
	at := 6
	extended := Extended_Header {
		present = true,
	}
	if flags & 0x40 != 0 {
		if at >= len(b) || b[at] != 0 {
			return size, false
		}
		extended.update = true
		at += 1
	}
	if flags & 0x20 != 0 {
		// 32 bits in 5 syncsafe bytes: the first holds 4 of them.
		if at + 6 > len(b) || b[at] != 5 || b[at + 1] > 0x0F {
			return size, false
		}
		crc: u64
		for c in b[at + 1:at + 6] {
			crc = crc << 7 | u64(c & 0x7F)
		}
		extended.crc = u32(crc)
		at += 6
	}
	if flags & 0x10 != 0 {
		if at + 2 > len(b) || b[at] != 1 {
			return size, false
		}
		extended.restrictions = b[at + 1]
		at += 2
	}
	if i64(at) > size {
		return size, false
	}
	tag.extended = extended
	return size, true
}
