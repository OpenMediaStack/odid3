package odid3

import "core:io"
import "core:os"

// Where the bytes being read come from. Reading only asks for windows at given offsets, so a file
// never has to be loaded whole.
@(private)
Source :: struct {
	data: []u8,
	file: ^os.File,
	size: i64,
}

@(private)
memory_source :: proc(data: []u8) -> Source {
	return {data = data, size = i64(len(data))}
}

@(private)
file_source :: proc(f: ^os.File) -> (src: Source, err: Error) {
	size := os.file_size(f) or_return
	return {file = f, size = size}, nil
}

// The bytes at offset: as many as buf holds, or fewer near the end of the source (or of a file that
// shrank since its size was read). Bytes in memory are a slice of the data, without using buf.
@(private)
source_bytes :: proc(src: ^Source, offset: i64, buf: []u8) -> (bytes: []u8, err: Error) {
	if offset < 0 || offset >= src.size {
		return nil, nil
	}
	n := int(min(i64(len(buf)), src.size - offset))
	if src.file == nil {
		return src.data[offset:][:n], nil
	}
	read := 0
	for read < n {
		m, read_err := os.read_at(src.file, buf[read:n], offset + i64(read))
		read += m
		if read_err == io.Error.EOF || (read_err == nil && m == 0) {
			break
		}
		if read_err != nil {
			return nil, read_err
		}
	}
	return buf[:read], nil
}

@(private)
has_magic :: proc(src: ^Source, offset: i64, magic: string) -> (found: bool, err: Error) {
	buf: [16]u8
	bytes := source_bytes(src, offset, buf[:len(magic)]) or_return
	return string(bytes) == magic, nil
}

// Fills dst with the bytes at offset. Fewer bytes than asked means the file changed while it was
// read.
@(private)
source_read :: proc(src: ^Source, offset: i64, dst: []u8) -> Error {
	bytes := source_bytes(src, offset, dst) or_return
	if len(bytes) < len(dst) {
		return os.Error(io.Error.Unexpected_EOF)
	}
	if src.file == nil {
		copy(dst, bytes)
	}
	return nil
}
