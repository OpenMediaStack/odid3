package odid3

import "base:runtime"
import "core:strings"
import "core:unicode/utf16"
import "core:unicode/utf8"

// Latin-1 maps each byte to the code point of the same value, so a byte above 0x7F takes two bytes
// in UTF-8.
@(private)
decode_latin1 :: proc(data: []u8, allocator: runtime.Allocator) -> (s: string, err: Error) {
	n := len(data)
	for c in data {
		if c >= 0x80 {
			n += 1
		}
	}
	if n == 0 {
		return "", nil
	}
	out := make([]u8, n, allocator) or_return
	i := 0
	for c in data {
		if c < 0x80 {
			out[i] = c
			i += 1
		} else {
			out[i] = 0xC0 | c >> 6
			out[i + 1] = 0x80 | c & 0x3F
			i += 2
		}
	}
	return string(out), nil
}

@(private)
is_ascii :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

// The text encoding of a frame. The values are the encoding byte.
Encoding :: enum u8 {
	Latin1  = 0, // ISO-8859-1
	UTF16   = 1, // UTF-16 with a byte order mark
	UTF16BE = 2, // UTF-16 big endian without a byte order mark, ID3v2.4 only
	UTF8    = 3, // ID3v2.4 only
}

// Text that claims to be UTF-8 but is not is read as Latin-1, which taggers often wrote instead.
@(private)
decode_text :: proc(
	encoding: Encoding,
	data: []u8,
	allocator: runtime.Allocator,
) -> (
	s: string,
	err: Error,
) {
	switch encoding {
	case .UTF16, .UTF16BE:
		return decode_utf16(data, encoding == .UTF16BE, allocator)
	case .UTF8:
		data := data
		if len(data) >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
			data = data[3:]
		}
		if utf8.valid_string(string(data)) {
			return strings.clone(string(data), allocator)
		}
		return decode_latin1(data, allocator)
	case .Latin1:
	}
	return decode_latin1(data, allocator)
}

// UTF-16 text starts with a byte order mark, FF FE for little endian or FE FF for big endian.
// Without one, UTF-16BE is big endian and UTF-16 is taken as little endian, as most writers use.
// An unpaired surrogate becomes U+FFFD, an odd last byte is dropped.
@(private)
decode_utf16 :: proc(
	data: []u8,
	big_endian: bool,
	allocator: runtime.Allocator,
) -> (
	s: string,
	err: Error,
) {
	data := data
	big_endian := big_endian
	if len(data) >= 2 {
		switch {
		case data[0] == 0xFF && data[1] == 0xFE:
			big_endian, data = false, data[2:]
		case data[0] == 0xFE && data[1] == 0xFF:
			big_endian, data = true, data[2:]
		}
	}
	size := 0
	for i := 0; i + 1 < len(data); {
		r := next_utf16_rune(data, &i, big_endian)
		if r != BYTE_ORDER_MARK {
			size += utf8.rune_size(r)
		}
	}
	if size == 0 {
		return "", nil
	}
	out := make([]u8, size, allocator) or_return
	at := 0
	for i := 0; i + 1 < len(data); {
		r := next_utf16_rune(data, &i, big_endian)
		if r != BYTE_ORDER_MARK {
			bytes, n := utf8.encode_rune(r)
			copy(out[at:], bytes[:n])
			at += n
		}
	}
	return string(out), nil
}

// Some writers repeat the byte order mark inside the text; it is dropped there too.
@(private)
BYTE_ORDER_MARK :: rune(0xFEFF)

@(private)
next_utf16_rune :: proc(data: []u8, i: ^int, big_endian: bool) -> rune {
	unit :: proc(data: []u8, at: int, big_endian: bool) -> rune {
		if big_endian {
			return rune(data[at]) << 8 | rune(data[at + 1])
		}
		return rune(data[at + 1]) << 8 | rune(data[at])
	}
	r := unit(data, i^, big_endian)
	i^ += 2
	switch {
	case r >= 0xD800 && r < 0xDC00:
		if i^ + 1 < len(data) {
			low := unit(data, i^, big_endian)
			if low >= 0xDC00 && low < 0xE000 {
				i^ += 2
				return utf16.decode_surrogate_pair(r, low)
			}
		}
		return utf8.RUNE_ERROR
	case r >= 0xDC00 && r < 0xE000:
		return utf8.RUNE_ERROR
	}
	return r
}

// The text before the first terminator of data in an encoding (a NUL, or two aligned NULs in
// UTF-16), and what follows the terminator. Without one, all of data is text.
@(private)
split_terminated :: proc(encoding: Encoding, data: []u8) -> (text, rest: []u8, terminated: bool) {
	if encoding == .UTF16 || encoding == .UTF16BE {
		for i := 0; i + 1 < len(data); i += 2 {
			if data[i] == 0 && data[i + 1] == 0 {
				return data[:i], data[i + 2:], true
			}
		}
		return data, nil, false
	}
	for c, i in data {
		if c == 0 {
			return data[:i], data[i + 1:], true
		}
	}
	return data, nil, false
}
