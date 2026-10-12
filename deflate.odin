package odid3

import "base:runtime"
import "core:hash"
import "core:math/bits"

// Compressed frames are written as a zlib stream (RFC 1950) holding one deflate block (RFC 1951)
// with the fixed Huffman codes, its matches found through hash chains over the last 32 KiB. A
// dynamic code would compress a little better; frames are small and the fixed code keeps the
// encoder short. Data that the fixed code would make larger, such as a JPEG, goes in stored blocks.

@(private)
DEFLATE_WINDOW :: 32 * 1024
@(private)
DEFLATE_MIN_MATCH :: 3
@(private)
DEFLATE_MAX_MATCH :: 258
@(private)
DEFLATE_HASH_BITS :: 15
// How many earlier positions with the same hash a match is looked for at, at most.
@(private)
DEFLATE_MAX_CHAIN :: 128
@(private)
DEFLATE_MAX_STORED :: 65535
// The fixed code spends at most 31 bits on one symbol: a length and a distance with their extra
// bits.
@(private)
DEFLATE_MAX_SYMBOL_BYTES :: 4

@(private)
Bit_Writer :: struct {
	out:   []u8,
	n:     int,
	bits:  u64,
	count: uint,
}

// Compresses data into a zlib stream, allocated with allocator and owned by the caller.
@(private)
deflate_zlib :: proc(data: []u8, allocator: runtime.Allocator) -> (stream: []u8, err: Error) {
	stored_blocks := max(1, (len(data) + DEFLATE_MAX_STORED - 1) / DEFLATE_MAX_STORED)
	stored_size := 2 + len(data) + 5 * stored_blocks + 4
	w := Bit_Writer {
		out = make([]u8, stored_size + 2 * DEFLATE_MAX_SYMBOL_BYTES, allocator) or_return,
	}
	defer if err != nil {
		delete(w.out, allocator)
	}
	w.out[0], w.out[1] = 0x78, 0x9C
	w.n = 2
	fits := deflate_fixed(&w, data, stored_size - 4, allocator) or_return
	if !fits {
		w.n, w.bits, w.count = 2, 0, 0
		deflate_stored(&w, data)
	}
	checksum := hash.adler32(data)
	put_be32(w.out[w.n:], checksum)
	w.n += 4
	return shrink(w.out, w.n, allocator)
}

// Writes data as one fixed Huffman block, unless the stream would reach most bytes.
@(private = "file")
deflate_fixed :: proc(
	w: ^Bit_Writer,
	data: []u8,
	most: int,
	allocator: runtime.Allocator,
) -> (
	fits: bool,
	err: runtime.Allocator_Error,
) {
	head := make([]i32, 1 << DEFLATE_HASH_BITS, allocator) or_return
	defer delete(head, allocator)
	prev := make([]i32, DEFLATE_WINDOW, allocator) or_return
	defer delete(prev, allocator)
	for &h in head {
		h = -1
	}
	insert :: proc(head, prev: []i32, data: []u8, at: int) {
		if at + DEFLATE_MIN_MATCH <= len(data) {
			h := deflate_hash(data[at:])
			prev[at % DEFLATE_WINDOW] = head[h]
			head[h] = i32(at)
		}
	}

	put_bits(w, 1, 1)
	put_bits(w, 1, 2)
	for at := 0; at < len(data); {
		if w.n >= most {
			return false, nil
		}
		length, distance := longest_match(head, prev, data, at)
		if length < DEFLATE_MIN_MATCH {
			put_symbol(w, int(data[at]))
			insert(head, prev, data, at)
			at += 1
			continue
		}
		put_match(w, length, distance)
		for i in at ..< at + length {
			insert(head, prev, data, i)
		}
		at += length
	}
	put_symbol(w, 256)
	flush_bits(w)
	return w.n <= most, nil
}

// The chain of positions with the same hash only holds positions inside the window: an entry of
// prev is overwritten one window later, when no match can reach it any more.
@(private = "file")
longest_match :: proc(head, prev: []i32, data: []u8, at: int) -> (length, distance: int) {
	if at + DEFLATE_MIN_MATCH > len(data) {
		return
	}
	most := min(DEFLATE_MAX_MATCH, len(data) - at)
	candidate := int(head[deflate_hash(data[at:])])
	for chain := 0; candidate >= 0 && at - candidate <= DEFLATE_WINDOW; chain += 1 {
		if chain == DEFLATE_MAX_CHAIN {
			break
		}
		n := 0
		for n < most && data[candidate + n] == data[at + n] {
			n += 1
		}
		if n > length {
			length, distance = n, at - candidate
			if n == most {
				break
			}
		}
		candidate = int(prev[candidate % DEFLATE_WINDOW])
	}
	return
}

@(private = "file")
deflate_hash :: proc(b: []u8) -> int {
	key := u32(b[0]) << 16 | u32(b[1]) << 8 | u32(b[2])
	return int((key * 2654435761) >> (32 - DEFLATE_HASH_BITS))
}

@(private = "file")
deflate_stored :: proc(w: ^Bit_Writer, data: []u8) {
	rest := data
	for {
		n := min(len(rest), DEFLATE_MAX_STORED)
		last := n == len(rest)
		put_bits(w, 1 if last else 0, 1)
		put_bits(w, 0, 2)
		flush_bits(w)
		w.out[w.n], w.out[w.n + 1] = u8(n), u8(n >> 8)
		w.out[w.n + 2], w.out[w.n + 3] = ~u8(n), ~u8(n >> 8)
		copy(w.out[w.n + 4:], rest[:n])
		w.n += 4 + n
		rest = rest[n:]
		if last {
			return
		}
	}
}

@(private = "file")
put_match :: proc(w: ^Bit_Writer, length, distance: int) {
	code := len(LENGTH_BASE) - 1
	for int(LENGTH_BASE[code]) > length {
		code -= 1
	}
	put_symbol(w, 257 + code)
	put_bits(w, u32(length - int(LENGTH_BASE[code])), uint(LENGTH_EXTRA[code]))
	code = len(DISTANCE_BASE) - 1
	for int(DISTANCE_BASE[code]) > distance {
		code -= 1
	}
	put_huffman(w, u32(code), 5)
	put_bits(w, u32(distance - int(DISTANCE_BASE[code])), uint(DISTANCE_EXTRA[code]))
}

// RFC 1951, section 3.2.6: the fixed literal and length code.
@(private = "file")
put_symbol :: proc(w: ^Bit_Writer, symbol: int) {
	switch {
	case symbol < 144:
		put_huffman(w, u32(0x30 + symbol), 8)
	case symbol < 256:
		put_huffman(w, u32(0x190 + symbol - 144), 9)
	case symbol < 280:
		put_huffman(w, u32(symbol - 256), 7)
	case:
		put_huffman(w, u32(0xC0 + symbol - 280), 8)
	}
}

// Huffman codes are packed from their most significant bit, everything else from the least.
@(private = "file")
put_huffman :: proc(w: ^Bit_Writer, code: u32, n: uint) {
	put_bits(w, bits.reverse_bits(code) >> (32 - n), n)
}

@(private = "file")
put_bits :: proc(w: ^Bit_Writer, value: u32, n: uint) {
	w.bits |= u64(value) << w.count
	w.count += n
	for w.count >= 8 {
		w.out[w.n] = u8(w.bits)
		w.n += 1
		w.bits >>= 8
		w.count -= 8
	}
}

@(private = "file")
flush_bits :: proc(w: ^Bit_Writer) {
	if w.count > 0 {
		put_bits(w, 0, 8 - w.count)
	}
}
