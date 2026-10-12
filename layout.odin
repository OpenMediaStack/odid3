package odid3

import "core:strings"

// A part of a file, in bytes from its start. size is 0 when the part is absent.
Range :: struct {
	offset: i64,
	size:   i64,
}

// Where each part of a file is.
Layout :: struct {
	file_size:   i64,
	v2:          Range, // the leading ID3v2 tag: header, frames, padding and footer
	v2_stacked:  Range, // ID3v2 tags right after the first one, replaced by it on write
	audio:       Range, // what lies between the tags, kept byte for byte on write
	ape:         Range, // found, never read
	lyrics3:     Range, // found, never read
	v1_enhanced: Range, // the Enhanced TAG, right before ID3v1
	v1:          Range,
}

@(private)
MAX_STACKED_TAGS :: 16

@(private)
APE_FOOTER_SIZE :: 32
@(private)
APE_HAS_HEADER :: 0x8000_0000

@(private)
LYRICS3_BEGIN :: "LYRICSBEGIN"
@(private)
LYRICS3_V1_END :: "LYRICSEND"
@(private)
LYRICS3_V1_MAX_LYRICS :: 5100
@(private)
LYRICS3_V2_END :: "LYRICS200"
@(private)
LYRICS3_V2_TAIL_SIZE :: 6 + len(LYRICS3_V2_END)

@(private)
locate :: proc(
	src: ^Source,
) -> (
	layout: Layout,
	header: V2_Header,
	warnings: Warnings,
	err: Error,
) {
	layout.file_size = src.size
	audio_start: i64
	audio_start, header = locate_v2(src, &layout, &warnings) or_return
	audio_end := locate_trailing(src, audio_start, &layout) or_return
	layout.audio = {audio_start, audio_end - audio_start}
	return
}

@(private)
locate_v2 :: proc(
	src: ^Source,
	layout: ^Layout,
	warnings: ^Warnings,
) -> (
	end: i64,
	header: V2_Header,
	err: Error,
) {
	buf: [V2_HEADER_SIZE]u8
	head := source_bytes(src, 0, buf[:]) or_return
	status: Header_Status
	header, status = parse_v2_header(head)
	switch {
	case status == .Absent:
		return 0, {}, nil
	case status == .Bad || header.major < 2:
		warnings^ += {.Bad_Header}
		return 0, {}, nil
	case v2_version(header.major) == .None:
		warnings^ += {.Unsupported_Version}
		return 0, {}, nil
	}
	end = v2_total_size(header)
	if end > src.size {
		warnings^ += {.Truncated_Tag}
		end = src.size
	}
	layout.v2 = {0, end}
	stacked_end := skip_stacked_tags(src, end, warnings) or_return
	if stacked_end > end {
		layout.v2_stacked = {end, stacked_end - end}
	}
	return stacked_end, header, nil
}

// Some taggers write a new tag in front of the old one instead of replacing it. A stacked tag that
// would run past the end of the file is not one: its bytes stay with the audio.
@(private)
skip_stacked_tags :: proc(
	src: ^Source,
	start: i64,
	warnings: ^Warnings,
) -> (
	end: i64,
	err: Error,
) {
	end = start
	buf: [V2_HEADER_SIZE]u8
	for _ in 0 ..< MAX_STACKED_TAGS {
		head := source_bytes(src, end, buf[:]) or_return
		header, status := parse_v2_header(head)
		next := end + v2_total_size(header)
		if status != .Valid || next > src.size {
			break
		}
		warnings^ += {.Second_V2_Tag}
		end = next
	}
	return
}

// ID3v1 is always last. APE and Lyrics3 tags come before it, in either order.
@(private)
locate_trailing :: proc(src: ^Source, start: i64, layout: ^Layout) -> (end: i64, err: Error) {
	end = src.size
	if end - V1_SIZE >= start {
		if has_magic(src, end - V1_SIZE, "TAG") or_return {
			layout.v1 = {end - V1_SIZE, V1_SIZE}
			end -= V1_SIZE
		}
	}
	if layout.v1.size > 0 && end - V1_ENHANCED_SIZE >= start {
		if has_magic(src, end - V1_ENHANCED_SIZE, "TAG+") or_return {
			layout.v1_enhanced = {end - V1_ENHANCED_SIZE, V1_ENHANCED_SIZE}
			end -= V1_ENHANCED_SIZE
		}
	}
	for _ in 0 ..< 2 {
		if layout.ape.size == 0 {
			layout.ape = find_ape(src, start, end) or_return
			if layout.ape.size > 0 {
				end = layout.ape.offset
				continue
			}
		}
		if layout.lyrics3.size == 0 {
			layout.lyrics3 = find_lyrics3(src, start, end) or_return
			if layout.lyrics3.size > 0 {
				end = layout.lyrics3.offset
				continue
			}
		}
		break
	}
	return
}

// An APE tag ends with a 32 byte footer: "APETAGEX", a version, the size of the items and the
// footer, the item count, flags and 8 reserved bytes, numbers in little endian.
@(private)
find_ape :: proc(src: ^Source, start, end: i64) -> (r: Range, err: Error) {
	if end - APE_FOOTER_SIZE < start {
		return
	}
	buf: [APE_FOOTER_SIZE]u8
	footer := source_bytes(src, end - APE_FOOTER_SIZE, buf[:]) or_return
	if len(footer) < APE_FOOTER_SIZE || string(footer[:8]) != "APETAGEX" {
		return
	}
	size := i64(le32(footer[12:16]))
	offset := end - size
	if size < APE_FOOTER_SIZE || offset < start {
		return {end - APE_FOOTER_SIZE, APE_FOOTER_SIZE}, nil
	}
	if le32(footer[20:24]) & APE_HAS_HEADER != 0 && offset - APE_FOOTER_SIZE >= start {
		if has_magic(src, offset - APE_FOOTER_SIZE, "APETAGEX") or_return {
			offset -= APE_FOOTER_SIZE
		}
	}
	return {offset, end - offset}, nil
}

@(private)
find_lyrics3 :: proc(src: ^Source, start, end: i64) -> (r: Range, err: Error) {
	r = find_lyrics3_v2(src, start, end) or_return
	if r.size == 0 {
		r = find_lyrics3_v1(src, start, end) or_return
	}
	return
}

// Lyrics3 v2 ends with its size in six digits, counted from "LYRICSBEGIN" to the digits, then
// "LYRICS200".
@(private)
find_lyrics3_v2 :: proc(src: ^Source, start, end: i64) -> (r: Range, err: Error) {
	if end - LYRICS3_V2_TAIL_SIZE < start {
		return
	}
	buf: [LYRICS3_V2_TAIL_SIZE]u8
	tail := source_bytes(src, end - LYRICS3_V2_TAIL_SIZE, buf[:]) or_return
	if len(tail) < LYRICS3_V2_TAIL_SIZE || string(tail[6:]) != LYRICS3_V2_END {
		return
	}
	size, ok := parse_digits(tail[:6])
	offset := end - LYRICS3_V2_TAIL_SIZE - i64(size)
	if !ok || offset < start {
		return
	}
	if !(has_magic(src, offset, LYRICS3_BEGIN) or_return) {
		return
	}
	return {offset, end - offset}, nil
}

// Lyrics3 v1 has no size: its start is the last "LYRICSBEGIN" within the 5100 bytes the lyrics can
// take.
@(private)
find_lyrics3_v1 :: proc(src: ^Source, start, end: i64) -> (r: Range, err: Error) {
	lyrics_end := end - len(LYRICS3_V1_END)
	if lyrics_end < start || !(has_magic(src, lyrics_end, LYRICS3_V1_END) or_return) {
		return
	}
	buf: [LYRICS3_V1_MAX_LYRICS + len(LYRICS3_BEGIN)]u8
	window_start := max(start, lyrics_end - len(buf))
	window := source_bytes(src, window_start, buf[:lyrics_end - window_start]) or_return
	at := strings.last_index(string(window), LYRICS3_BEGIN)
	if at < 0 {
		return
	}
	offset := window_start + i64(at)
	return {offset, end - offset}, nil
}

@(private)
le32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

@(private)
parse_digits :: proc(b: []u8) -> (n: int, ok: bool) {
	for c in b {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + int(c - '0')
	}
	return n, len(b) > 0
}
