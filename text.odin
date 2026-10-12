package odid3

import "base:runtime"

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
