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
	allocator: runtime.Allocator,
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
