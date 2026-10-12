package odid3

import "base:runtime"
import "core:os"
import "core:strings"

// The warnings that mean bytes of the tag could not be read: rewriting the tag loses them, so a
// write asks for Write_Options.replace_damaged first.
DAMAGE_WARNINGS :: Warnings {
	.Truncated_Tag,
	.Damaged_Frames,
	.Bad_Extended_Header,
	.Data_In_Padding,
	.Compressed_V22_Tag,
	.Second_V2_Tag,
	.Too_Many_Frames,
}

// The file bytes with its tags replaced by those of tags: the ID3v2 tag first (none when its version
// is .None), then everything that lies between the tags of the file (the audio, APE and Lyrics3
// tags, unknown bytes) byte for byte, then ID3v1 (none when its version is .None). A second ID3v2
// tag, stacked or appended, is dropped. The tags are located in file again, so tags may come from
// another read of it.
write_bytes :: proc(
	file: []u8,
	tags: ^Tags,
	options := Write_Options{},
	allocator := context.allocator,
) -> (
	out: []u8,
	err: Error,
) {
	check_damage(tags, options) or_return
	src := memory_source(file)
	layout, _, _ := locate(&src) or_return
	head, tail := render_tags(tags, options, allocator) or_return
	defer delete(head, allocator)
	defer delete(tail, allocator)
	ranges, count := kept_ranges(layout)
	size := len(head) + len(tail)
	for r in ranges[:count] {
		size += int(r.size)
	}
	out = make([]u8, size, allocator) or_return
	at := copy(out, head)
	for r in ranges[:count] {
		at += copy(out[at:], file[r.offset:][:r.size])
	}
	copy(out[at:], tail)
	return out, nil
}

// Rewrites the file at path with the tags of tags, as write_bytes does, without loading its audio.
// The new file is written next to it, flushed to the disk, given the original's permissions, then
// renamed over it: on any error the original is left as it was.
write_file :: proc(
	path: string,
	tags: ^Tags,
	options := Write_Options{},
	allocator := context.allocator,
) -> (
	err: Error,
) {
	check_damage(tags, options) or_return
	info := os.stat(path, allocator) or_return
	type, mode := info.type, info.mode
	os.file_info_delete(info, allocator)
	if type != .Regular {
		return os.Error(os.General_Error.Invalid_File)
	}
	head, tail := render_tags(tags, options, allocator) or_return
	defer delete(head, allocator)
	defer delete(tail, allocator)

	original := os.open(path) or_return
	original_open := true
	defer if original_open {
		os.close(original)
	}
	src := file_source(original) or_return
	layout, _, _ := locate(&src) or_return

	dir, name := os.split_path(path)
	pattern := strings.concatenate({".", name, ".*.odid3"}, allocator) or_return
	defer delete(pattern, allocator)
	temp := os.create_temp_file(dir if dir != "" else ".", pattern) or_return
	temp_open := true
	temp_path := strings.clone(os.name(temp), allocator) or_return
	defer delete(temp_path, allocator)
	done := false
	defer if !done {
		if temp_open {
			os.close(temp)
		}
		os.remove(temp_path)
	}

	write_all(temp, head) or_return
	ranges, count := kept_ranges(layout)
	copy_ranges(temp, &src, ranges[:count], allocator) or_return
	write_all(temp, tail) or_return
	os.fchange_mode(temp, mode) or_return
	os.sync(temp) or_return
	temp_open = false
	os.close(temp) or_return
	// Windows cannot rename over a file that is still open.
	original_open = false
	os.close(original) or_return
	os.rename(temp_path, path) or_return
	done = true
	return nil
}

@(private)
check_damage :: proc(tags: ^Tags, options: Write_Options) -> Error {
	if tags.warnings & DAMAGE_WARNINGS != {} && !options.replace_damaged {
		return .Damaged_Tag
	}
	return nil
}

@(private)
render_tags :: proc(
	tags: ^Tags,
	options: Write_Options,
	allocator: runtime.Allocator,
) -> (
	head, tail: []u8,
	err: Error,
) {
	if tags.v2.version != .None {
		head = render(&tags.v2, options, allocator) or_return
	}
	if tags.v1.version != .None {
		tail, err = render_v1(&tags.v1, allocator)
		if err != nil {
			delete(head, allocator)
			return nil, nil, err
		}
	}
	return
}

// What a write keeps from a file, in order: everything from the audio to the trailing ID3v1 or
// Enhanced TAG, but an appended ID3v2 tag.
@(private)
kept_ranges :: proc(layout: Layout) -> (ranges: [2]Range, count: int) {
	start := layout.audio.offset
	end := layout.file_size
	if layout.v1_enhanced.size > 0 {
		end = layout.v1_enhanced.offset
	} else if layout.v1.size > 0 {
		end = layout.v1.offset
	}
	appended := layout.v2_appended
	if appended.size > 0 && appended.offset >= start && appended.offset + appended.size <= end {
		ranges[0] = {start, appended.offset - start}
		ranges[1] = {appended.offset + appended.size, end - appended.offset - appended.size}
		return ranges, 2
	}
	ranges[0] = {start, end - start}
	return ranges, 1
}

@(private)
COPY_CHUNK :: 1024 * 1024

@(private)
copy_ranges :: proc(
	dst: ^os.File,
	src: ^Source,
	ranges: []Range,
	allocator: runtime.Allocator,
) -> Error {
	largest: i64
	for r in ranges {
		largest = max(largest, r.size)
	}
	if largest == 0 {
		return nil
	}
	buf := make([]u8, min(largest, COPY_CHUNK), allocator) or_return
	defer delete(buf, allocator)
	for r in ranges {
		for done: i64 = 0; done < r.size; {
			n := min(r.size - done, i64(len(buf)))
			source_read(src, r.offset + done, buf[:n]) or_return
			write_all(dst, buf[:n]) or_return
			done += n
		}
	}
	return nil
}

@(private)
write_all :: proc(f: ^os.File, data: []u8) -> Error {
	if len(data) == 0 {
		return nil
	}
	_, err := os.write(f, data)
	return err
}
