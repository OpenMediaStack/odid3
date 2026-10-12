package odid3

// Where the bytes being read come from. Reading only asks for windows at given offsets, so a file
// never has to be loaded whole.
@(private)
Source :: struct {
	data: []u8,
	size: i64,
}

@(private)
memory_source :: proc(data: []u8) -> Source {
	return {data = data, size = i64(len(data))}
}

// The bytes at offset: as many as buf holds, or fewer near the end of the source. Bytes in memory
// are returned as a slice of the data, without using buf.
@(private)
source_bytes :: proc(src: ^Source, offset: i64, buf: []u8) -> (bytes: []u8, err: Error) {
	if offset < 0 || offset >= src.size {
		return nil, nil
	}
	n := min(i64(len(buf)), src.size - offset)
	return src.data[offset:offset + n], nil
}

@(private)
has_magic :: proc(src: ^Source, offset: i64, magic: string) -> (found: bool, err: Error) {
	buf: [16]u8
	bytes := source_bytes(src, offset, buf[:len(magic)]) or_return
	return string(bytes) == magic, nil
}
