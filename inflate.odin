package odid3

import "base:runtime"
import "core:hash"

// Compressed frames are zlib streams (RFC 1950) around deflate data (RFC 1951). They are inflated
// here rather than with core:compress/zlib, which asserts on some damaged streams: frame data is
// untrusted. The decoder follows puff, the reference inflater Mark Adler ships with zlib: Huffman
// codes are decoded one bit at a time, which is slow but checks every step.

@(private)
MAX_INFLATED_SIZE :: 256 * 1024 * 1024

// How far past its declared size a stream may inflate before it counts as damaged: declared sizes
// are sometimes a little wrong, a bomb inflates far past them.
@(private)
INFLATE_SLACK :: 64 * 1024

// Deflate encodes at best 258 bytes in a little over 2 bits, so no stream inflates to more than
// about 1032 times its size.
@(private)
MAX_DEFLATE_RATIO :: 1032

@(private)
DEFLATE_MAX_BITS :: 15
@(private)
DEFLATE_LENGTH_CODES :: 286
@(private)
DEFLATE_DISTANCE_CODES :: 30
@(private)
DEFLATE_FIXED_LENGTH_CODES :: 288

@(private, rodata)
LENGTH_BASE := [29]u16 {
	3,
	4,
	5,
	6,
	7,
	8,
	9,
	10,
	11,
	13,
	15,
	17,
	19,
	23,
	27,
	31,
	35,
	43,
	51,
	59,
	67,
	83,
	99,
	115,
	131,
	163,
	195,
	227,
	258,
}
@(private, rodata)
LENGTH_EXTRA := [29]u8 {
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	1,
	1,
	1,
	1,
	2,
	2,
	2,
	2,
	3,
	3,
	3,
	3,
	4,
	4,
	4,
	4,
	5,
	5,
	5,
	5,
	0,
}
@(private, rodata)
DISTANCE_BASE := [30]u16 {
	1,
	2,
	3,
	4,
	5,
	7,
	9,
	13,
	17,
	25,
	33,
	49,
	65,
	97,
	129,
	193,
	257,
	385,
	513,
	769,
	1025,
	1537,
	2049,
	3073,
	4097,
	6145,
	8193,
	12289,
	16385,
	24577,
}
@(private, rodata)
DISTANCE_EXTRA := [30]u8 {
	0,
	0,
	0,
	0,
	1,
	1,
	2,
	2,
	3,
	3,
	4,
	4,
	5,
	5,
	6,
	6,
	7,
	7,
	8,
	8,
	9,
	9,
	10,
	10,
	11,
	11,
	12,
	12,
	13,
	13,
}
// The order in which a dynamic block lists the lengths of the code length code.
@(private, rodata)
CODE_LENGTH_ORDER := [19]u8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

@(private)
Inflate_Error :: enum u8 {
	None,
	Truncated,
	Bad_Header,
	Bad_Block,
	Bad_Code,
	Too_Far,
	Too_Big,
	Bad_Checksum,
	Out_Of_Memory,
}

@(private)
Inflater :: struct {
	input:  []u8,
	pos:    int,
	bits:   u32,
	count:  u32,
	output: [dynamic]u8,
	limit:  int,
}

// A canonical Huffman code: how many codes have each length, and the symbols ordered by code.
@(private)
Huffman :: struct {
	count:  [DEFLATE_MAX_BITS + 1]u16,
	symbol: [DEFLATE_FIXED_LENGTH_CODES]u16,
}

// Inflates a zlib stream that should give declared bytes (-1 when unknown). ok is false when the
// stream is damaged or would inflate well past what it declares, or past what it could hold.
@(private)
inflate_frame :: proc(
	stream: []u8,
	declared: i64,
	allocator: runtime.Allocator,
) -> (
	out: []u8,
	ok: bool,
	err: Error,
) {
	most := min(i64(len(stream)) * MAX_DEFLATE_RATIO + 1024, MAX_INFLATED_SIZE)
	if declared > most {
		return nil, false, nil
	}
	limit := most
	if declared >= 0 {
		limit = max(declared, min(most, INFLATE_SLACK))
	}
	result: Inflate_Error
	out, result = inflate_zlib(stream, int(limit), allocator)
	#partial switch result {
	case .None:
		return out, true, nil
	case .Out_Of_Memory:
		return nil, false, runtime.Allocator_Error.Out_Of_Memory
	}
	return nil, false, nil
}

// A zlib stream is a 2 byte header, deflate blocks, then the Adler-32 checksum of the inflated
// bytes, big endian.
@(private)
inflate_zlib :: proc(
	stream: []u8,
	limit: int,
	allocator: runtime.Allocator,
) -> (
	out: []u8,
	e: Inflate_Error,
) {
	if len(stream) < 6 {
		return nil, .Truncated
	}
	cmf, flg := stream[0], stream[1]
	if cmf & 0x0F != 8 || cmf >> 4 > 7 || (u16(cmf) << 8 | u16(flg)) % 31 != 0 || flg & 0x20 != 0 {
		return nil, .Bad_Header
	}
	s := Inflater {
		input = stream[2:],
		limit = limit,
	}
	reserved, alloc_err := make([dynamic]u8, 0, min(limit, len(stream) * 4 + 1024), allocator)
	if alloc_err != nil {
		return nil, .Out_Of_Memory
	}
	s.output = reserved
	defer if e != .None {
		delete(s.output)
	}
	for last: u32 = 0; last == 0; {
		last = inflate_bits(&s, 1) or_return
		switch inflate_bits(&s, 2) or_return {
		case 0:
			inflate_stored(&s) or_return
		case 1:
			inflate_fixed(&s) or_return
		case 2:
			inflate_dynamic(&s) or_return
		case:
			return nil, .Bad_Block
		}
	}
	// Fewer than 8 bits are left over, from the last byte read: the checksum starts at the next.
	if s.pos + 4 > len(s.input) {
		return nil, .Truncated
	}
	if hash.adler32(s.output[:]) != be32(s.input[s.pos:][:4]) {
		return nil, .Bad_Checksum
	}
	allocated := ([^]u8)(raw_data(s.output))[:cap(s.output)]
	exact, shrink_err := shrink(allocated, len(s.output), allocator)
	if shrink_err != nil {
		return nil, .Out_Of_Memory
	}
	return exact, .None
}

@(private)
inflate_bits :: proc(s: ^Inflater, need: u32) -> (value: u32, e: Inflate_Error) {
	bits := s.bits
	for s.count < need {
		if s.pos >= len(s.input) {
			return 0, .Truncated
		}
		bits |= u32(s.input[s.pos]) << s.count
		s.pos += 1
		s.count += 8
	}
	s.bits = bits >> need
	s.count -= need
	return bits & (1 << need - 1), .None
}

@(private)
inflate_put :: proc(s: ^Inflater, b: u8) -> Inflate_Error {
	if len(s.output) >= s.limit {
		return .Too_Big
	}
	if _, err := append(&s.output, b); err != nil {
		return .Out_Of_Memory
	}
	return .None
}

// A stored block: after the bits left in the current byte, its length, the length's complement,
// then the bytes as they are.
@(private)
inflate_stored :: proc(s: ^Inflater) -> Inflate_Error {
	s.bits, s.count = 0, 0
	if s.pos + 4 > len(s.input) {
		return .Truncated
	}
	length := int(s.input[s.pos]) | int(s.input[s.pos + 1]) << 8
	complement := int(s.input[s.pos + 2]) | int(s.input[s.pos + 3]) << 8
	s.pos += 4
	if length != ~complement & 0xFFFF {
		return .Bad_Block
	}
	if s.pos + length > len(s.input) {
		return .Truncated
	}
	for b in s.input[s.pos:][:length] {
		inflate_put(s, b) or_return
	}
	s.pos += length
	return .None
}

// Builds a canonical code from the length of each symbol's code (0 for no code). Returns how many
// codes are missing for the code to be complete, negative when there are too many.
@(private)
huffman_construct :: proc(h: ^Huffman, lengths: []u16) -> int {
	h.count = {}
	for length in lengths {
		h.count[length] += 1
	}
	if int(h.count[0]) == len(lengths) {
		return 0
	}
	left := 1
	for length in 1 ..= DEFLATE_MAX_BITS {
		left <<= 1
		left -= int(h.count[length])
		if left < 0 {
			return left
		}
	}
	offsets: [DEFLATE_MAX_BITS + 1]u16
	for length in 1 ..< DEFLATE_MAX_BITS {
		offsets[length + 1] = offsets[length] + h.count[length]
	}
	for length, symbol in lengths {
		if length != 0 {
			h.symbol[offsets[length]] = u16(symbol)
			offsets[length] += 1
		}
	}
	return left
}

@(private)
huffman_decode :: proc(s: ^Inflater, h: ^Huffman) -> (symbol: int, e: Inflate_Error) {
	code, first, index := 0, 0, 0
	for length in 1 ..= DEFLATE_MAX_BITS {
		code |= int(inflate_bits(s, 1) or_return)
		count := int(h.count[length])
		if code - count < first {
			at := index + (code - first)
			if at < 0 || at >= len(h.symbol) {
				return -1, .Bad_Code
			}
			return int(h.symbol[at]), .None
		}
		index += count
		first += count
		first <<= 1
		code <<= 1
	}
	return -1, .Bad_Code
}

@(private)
inflate_codes :: proc(s: ^Inflater, lengths, distances: ^Huffman) -> Inflate_Error {
	for {
		symbol := huffman_decode(s, lengths) or_return
		switch {
		case symbol < 256:
			inflate_put(s, u8(symbol)) or_return
		case symbol == 256:
			return .None
		case:
			symbol -= 257
			if symbol >= len(LENGTH_BASE) {
				return .Bad_Code
			}
			length :=
				int(LENGTH_BASE[symbol]) +
				int(inflate_bits(s, u32(LENGTH_EXTRA[symbol])) or_return)
			code := huffman_decode(s, distances) or_return
			if code >= len(DISTANCE_BASE) {
				return .Bad_Code
			}
			distance :=
				int(DISTANCE_BASE[code]) +
				int(inflate_bits(s, u32(DISTANCE_EXTRA[code])) or_return)
			if distance > len(s.output) {
				return .Too_Far
			}
			for _ in 0 ..< length {
				inflate_put(s, s.output[len(s.output) - distance]) or_return
			}
		}
	}
}

@(private)
inflate_fixed :: proc(s: ^Inflater) -> Inflate_Error {
	lengths: [DEFLATE_FIXED_LENGTH_CODES]u16
	for &length, symbol in lengths {
		switch {
		case symbol < 144:
			length = 8
		case symbol < 256:
			length = 9
		case symbol < 280:
			length = 7
		case:
			length = 8
		}
	}
	distance_lengths: [DEFLATE_DISTANCE_CODES]u16
	for &length in distance_lengths {
		length = 5
	}
	length_code, distance_code: Huffman
	huffman_construct(&length_code, lengths[:])
	huffman_construct(&distance_code, distance_lengths[:])
	return inflate_codes(s, &length_code, &distance_code)
}

// A dynamic block first gives the lengths of a code for code lengths, then with it the code lengths
// of the literal and length code and of the distance code, with repeat codes 16, 17 and 18.
@(private)
inflate_dynamic :: proc(s: ^Inflater) -> Inflate_Error {
	length_count := int(inflate_bits(s, 5) or_return) + 257
	distance_count := int(inflate_bits(s, 5) or_return) + 1
	code_count := int(inflate_bits(s, 4) or_return) + 4
	if length_count > DEFLATE_LENGTH_CODES || distance_count > DEFLATE_DISTANCE_CODES {
		return .Bad_Block
	}
	lengths: [DEFLATE_LENGTH_CODES + DEFLATE_DISTANCE_CODES]u16
	for i in 0 ..< code_count {
		lengths[CODE_LENGTH_ORDER[i]] = u16(inflate_bits(s, 3) or_return)
	}
	length_code, distance_code: Huffman
	if huffman_construct(&length_code, lengths[:19]) != 0 {
		return .Bad_Block
	}
	total := length_count + distance_count
	for index := 0; index < total; {
		symbol := huffman_decode(s, &length_code) or_return
		if symbol < 16 {
			lengths[index] = u16(symbol)
			index += 1
			continue
		}
		repeated: u16
		times: int
		switch symbol {
		case 16:
			if index == 0 {
				return .Bad_Block
			}
			repeated = lengths[index - 1]
			times = 3 + int(inflate_bits(s, 2) or_return)
		case 17:
			times = 3 + int(inflate_bits(s, 3) or_return)
		case:
			times = 11 + int(inflate_bits(s, 7) or_return)
		}
		if index + times > total {
			return .Bad_Block
		}
		for _ in 0 ..< times {
			lengths[index] = repeated
			index += 1
		}
	}
	if lengths[256] == 0 {
		return .Bad_Block
	}
	// Only a code with a single symbol may be incomplete.
	left := huffman_construct(&length_code, lengths[:length_count])
	if left < 0 || (left > 0 && length_count - int(length_code.count[0]) != 1) {
		return .Bad_Block
	}
	left = huffman_construct(&distance_code, lengths[length_count:total])
	if left < 0 || (left > 0 && distance_count - int(distance_code.count[0]) != 1) {
		return .Bad_Block
	}
	return inflate_codes(s, &length_code, &distance_code)
}
