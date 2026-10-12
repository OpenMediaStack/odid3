package odid3

import "base:runtime"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

// The warnings that mean bytes of the tag could not be read, or a second tag the model does not
// hold: rewriting the tag loses them, so a write asks for Write_Options.replace_damaged first.
DAMAGE_WARNINGS :: Warnings {
	.Truncated_Tag,
	.Damaged_Frames,
	.Bad_Extended_Header,
	.Data_In_Padding,
	.Compressed_V22_Tag,
	.Second_V2_Tag,
	.Too_Many_Frames,
}

// The file bytes with its tags replaced by those of tags, allocated with allocator and owned by the
// caller, who frees them with delete: the ID3v2 tag first (none when its version is .None), then
// everything that lies between the tags of the file (the audio, APE and Lyrics3 tags, unknown
// bytes) byte for byte, then ID3v1 (none when its version is .None). A second ID3v2 tag, stacked
// or appended, is dropped. The tags are located in file again, so tags may come from another read
// of it; damage found in file as it is now also needs replace_damaged.
write_bytes :: proc(
	file: []u8,
	tags: ^Tags,
	options := Write_Options{},
	allocator := context.allocator,
) -> (
	out: []u8,
	err: Error,
) {
	check_damage(tags.warnings, options) or_return
	src := memory_source(file)
	layout, _, warnings := locate(&src) or_return
	check_damage(warnings, options) or_return
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
// The new file is written next to the original, given its permissions (and on Unix its owner and
// group, as far as the process may), flushed to the disk, then renamed over it: on any error the
// original is left as it was. Through a symbolic link, the file it points to is rewritten and the
// link stays. A file the caller cannot write is refused, as is one that is not a regular file
// (Invalid_File). A file that changes while it is rewritten gives File_Changed. What the rename
// does not carry over is lost: extended attributes, ACLs and alternate data streams, and a hard
// link, whose other names keep the old content.
write_file :: proc(
	path: string,
	tags: ^Tags,
	options := Write_Options{},
	allocator := context.allocator,
) -> (
	err: Error,
) {
	check_damage(tags.warnings, options) or_return
	target := resolve_links(path, allocator) or_return
	defer delete(target, allocator)
	info := os.stat(target, allocator) or_return
	type, mode := info.type, info.mode
	os.file_info_delete(info, allocator)
	if type != .Regular {
		return os.Error(os.General_Error.Invalid_File)
	}
	head, tail := render_tags(tags, options, allocator) or_return
	defer delete(head, allocator)
	defer delete(tail, allocator)

	// Opened for writing too, so that a file the caller may not write is refused everywhere, as
	// Windows refuses to rename over it.
	original := os.open(target, {.Read, .Write}) or_return
	original_open := true
	defer if original_open {
		os.close(original)
	}
	before := os.fstat(original, allocator) or_return
	os.file_info_delete(before, allocator)
	src := file_source(original) or_return
	layout, _, warnings := locate(&src) or_return
	check_damage(warnings, options) or_return

	dir, name := os.split_path(target)
	dir = dir if dir != "" else "."
	pattern := temp_pattern(name, allocator) or_return
	defer delete(pattern, allocator)
	temp := os.create_temp_file(dir, pattern) or_return
	temp_path, clone_err := strings.clone(os.name(temp), allocator)
	if clone_err != nil {
		os.remove(os.name(temp))
		os.close(temp)
		return clone_err
	}
	defer delete(temp_path, allocator)
	temp_open := true
	done := false
	defer if !done {
		if temp_open {
			os.close(temp)
		}
		os.remove(temp_path)
	}
	// Before any byte of the original goes in, so that a private file never shows to others.
	os.fchange_mode(temp, mode) or_return
	keep_owner(original, temp)

	write_all(temp, head) or_return
	ranges, count := kept_ranges(layout)
	copy_ranges(temp, &src, ranges[:count], allocator) or_return
	write_all(temp, tail) or_return
	os.sync(temp) or_return
	temp_open = false
	os.close(temp) or_return
	check_unchanged(original, target, before, allocator) or_return
	// Windows cannot rename over a file that is still open.
	original_open = false
	os.close(original) or_return
	os.rename(temp_path, target) or_return
	done = true
	sync_directory(dir)
	return nil
}

@(private)
check_damage :: proc(warnings: Warnings, options: Write_Options) -> Error {
	if warnings & DAMAGE_WARNINGS != {} && !options.replace_damaged {
		return .Damaged_Tag
	}
	return nil
}

@(private)
MAX_LINKS :: 16

// The file a path names, through its symbolic links, relative ones being relative to the
// directory of the link.
@(private)
resolve_links :: proc(
	path: string,
	allocator: runtime.Allocator,
) -> (
	resolved: string,
	err: Error,
) {
	resolved = strings.clone(path, allocator) or_return
	defer if err != nil {
		delete(resolved, allocator)
	}
	for _ in 0 ..< MAX_LINKS {
		info := os.lstat(resolved, allocator) or_return
		type := info.type
		os.file_info_delete(info, allocator)
		if type != .Symlink {
			return resolved, nil
		}
		target := os.read_link(resolved, allocator) or_return
		if !os.is_absolute_path(target) {
			dir, _ := os.split_path(resolved)
			joined, join_err := os.join_path({dir, target}, allocator)
			delete(target, allocator)
			if join_err != nil {
				return resolved, join_err
			}
			target = joined
		}
		delete(resolved, allocator)
		resolved = target
	}
	return resolved, os.Error(os.General_Error.Invalid_File)
}

// ".name.*.odid3", the name cut to its first 32 bytes so that the temporary name stays within
// the length a file system allows.
@(private)
temp_pattern :: proc(
	name: string,
	allocator: runtime.Allocator,
) -> (
	string,
	runtime.Allocator_Error,
) {
	short := name
	if len(short) > 32 {
		cut := 32
		for cut > 0 && !utf8.rune_start(short[cut]) {
			cut -= 1
		}
		short = short[:cut]
	}
	return strings.concatenate({".", short, ".*.odid3"}, allocator)
}

// The original must be the file it was when write_file opened it: still at its path, with the
// same size and modification time, or another program wrote it meanwhile.
@(private)
check_unchanged :: proc(
	original: ^os.File,
	path: string,
	before: os.File_Info,
	allocator: runtime.Allocator,
) -> Error {
	now := os.fstat(original, allocator) or_return
	os.file_info_delete(now, allocator)
	at_path := os.stat(path, allocator) or_return
	os.file_info_delete(at_path, allocator)
	if now.size != before.size || now.modification_time != before.modification_time {
		return .File_Changed
	}
	if at_path.inode != now.inode || at_path.device != now.device {
		return .File_Changed
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
