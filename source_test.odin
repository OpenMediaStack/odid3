#+private
package odid3

import "base:runtime"
import "core:io"
import "core:os"
import "core:testing"

// Stands between the reading code and a file: counts the bytes read, can return fewer bytes per
// call than asked, and can report a size larger than the file, as if it shrank once opened.
@(private = "file")
Spy :: struct {
	file:       os.File, // first, so that &spy.file is also the ^Spy the stream gets back
	inner:      ^os.File,
	bytes_read: i64,
	max_read:   int,
	extra_size: i64,
}

@(private = "file")
spy_proc :: proc(
	stream_data: rawptr,
	mode: os.File_Stream_Mode,
	p: []byte,
	offset: i64,
	whence: io.Seek_From,
	allocator: runtime.Allocator,
) -> (
	n: i64,
	err: os.Error,
) {
	spy := (^Spy)(stream_data)
	inner := spy.inner.stream
	#partial switch mode {
	case .Read_At:
		buf := p
		if spy.max_read > 0 && len(buf) > spy.max_read {
			buf = buf[:spy.max_read]
		}
		n, err = inner.procedure(spy.inner, mode, buf, offset, whence, allocator)
		spy.bytes_read += n
		return
	case .Size:
		n, err = inner.procedure(spy.inner, mode, p, offset, whence, allocator)
		return n + spy.extra_size, err
	}
	return inner.procedure(spy.inner, mode, p, offset, whence, allocator)
}

@(private = "file")
read_through_spy :: proc(t: ^testing.T, path: string, spy: ^Spy) -> (tags: Tags, err: Error) {
	inner, open_err := os.open(path)
	if open_err != nil {
		testing.fail_now(t, "cannot open the file")
	}
	defer os.close(inner)
	spy.inner = inner
	spy.file.stream.procedure = spy_proc
	src := file_source(&spy.file) or_return
	return read_source(&src, {}, context.allocator)
}

@(private = "file")
temp_file :: proc(t: ^testing.T, parts: ..struct {
		offset: i64,
		data:   []u8,
	}) -> string {
	dir, err := os.make_directory_temp("", "odid3-*", context.allocator)
	if err != nil {
		testing.fail_now(t, "cannot create a temporary directory")
	}
	testing.cleanup(t, proc(data: rawptr) {
			dir := (^string)(data)
			os.remove_all(dir^)
			delete(dir^)
			free(dir)
		}, new_clone(dir))
	path, _ := os.join_path({dir, "file.mp3"}, context.temp_allocator)
	f, open_err := os.open(path, {.Write, .Create, .Trunc})
	if open_err != nil {
		testing.fail_now(t, "cannot create the file")
	}
	defer os.close(f)
	for part in parts {
		_, write_err := os.write_at(f, part.data, part.offset)
		testing.expect_value(t, write_err, nil)
	}
	return path
}

@(test)
reading_a_file_never_reads_the_audio :: proc(t: ^testing.T) {
	AUDIO_SIZE :: 8 * 1024 * 1024
	tag := [?]u8{'I', 'D', '3', 3, 0, 0, 0, 0, 0, 0}
	v1: [128]u8
	copy(v1[:], "TAG")
	path := temp_file(t, {0, tag[:]}, {AUDIO_SIZE, v1[:]})

	spy: Spy
	tags, err := read_through_spy(t, path, &spy)
	defer destroy_tags(&tags)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, tags.v1.version, V1_Version.V1_0)
	testing.expectf(t, spy.bytes_read < 16 * 1024, "%v bytes read", spy.bytes_read)
}

@(test)
short_reads_give_the_same_tags :: proc(t: ^testing.T) {
	lyrics := "LYRICSBEGIN[00:01]HelloLYRICSEND"
	v1: [128]u8
	copy(v1[:], "TAGTitle")
	audio: [1000]u8
	path := temp_file(
		t,
		{0, audio[:]},
		{1000, transmute([]u8)lyrics},
		{1000 + i64(len(lyrics)), v1[:]},
	)

	spy := Spy {
		max_read = 1,
	}
	tags, err := read_through_spy(t, path, &spy)
	defer destroy_tags(&tags)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, tags.layout.lyrics3, Range{1000, i64(len(lyrics))})
	testing.expect_value(t, tags.v1.title, "Title")
}

@(test)
file_shorter_than_its_size :: proc(t: ^testing.T) {
	v1: [128]u8
	copy(v1[:], "TAG")
	audio: [1000]u8
	path := temp_file(t, {0, audio[:]}, {1000, v1[:]})

	spy := Spy {
		extra_size = 500,
	}
	tags, err := read_through_spy(t, path, &spy)
	defer destroy_tags(&tags)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, tags.layout.file_size, 1628)
	testing.expect_value(t, tags.v1.version, V1_Version.None)
}
