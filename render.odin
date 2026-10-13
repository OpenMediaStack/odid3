package odid3

// How to write a tag. The tag header's flags come from these options and from the frames; of the
// flags read, only the experimental one is kept.
Write_Options :: struct {
	// Zeros after the frames; nil means DEFAULT_PADDING, below 0 none.
	padding:           Maybe(int),
	// ID3v2.4 only; the spec forbids padding with a footer, so there is none.
	footer:            bool,
	// The whole tag; ID3v2.4 frames can also ask for it one by one. ffmpeg misreads the frames of
	// ID3v2.2 and 2.3 tags written so, after the first byte unsynchronisation inserts.
	unsynchronisation: bool,
	// Every frame but chapters (whose frames inside odid3 would no longer inflate) and encrypted
	// ones, ID3v2.3 and 2.4 only; frames can also ask for it one by one. A frame is compressed even
	// when that makes it larger, as a test file may want. ffmpeg reads compressed ID3v2.3 frames as
	// if they were not.
	compression:       bool,
	// Allow rewriting a file whose tag was read with damage warnings (see write_file), and
	// rendering a tag whose frames could not be read at all (a compressed ID3v2.2 tag).
	replace_damaged:   bool,
	// The text encoding of every ID3v2 text frame, chapters included; nil keeps each frame's, one
	// set on a frame with set_encoding included. The frames are re-encoded on a copy as
	// set_encoding(&tag, encoding) does: those it does not decode (SYLT, GEOB, USER, OWNE, COMR,
	// IPLS) and encrypted ones keep theirs, a COMM, USLT or APIC whose data does not follow its
	// layout, a frame whose text would not survive and a CHAP or CTOC whose content does not decode
	// stay as they are, and before ID3v2.4 several values are joined with "/". An encoding the
	// version lacks gives Encoding_Not_In_Version, text it cannot hold Not_Encodable, and nothing
	// is written.
	encoding:          Maybe(Encoding),
	// The byte order of UTF-16 text with a byte order mark (.UTF16), in every text frame that holds
	// it once encoding applies; nil keeps each frame's, and writes frames encoding re-encodes
	// little endian. A frame already in the order is left as it is; the others are re-encoded on a
	// copy as set_encoding does, with the same exceptions (SYLT, GEOB, USER, OWNE, COMR, IPLS and
	// encrypted frames keep theirs, a COMM, USLT or APIC whose data does not follow its layout, a
	// frame whose text would not survive and a chapter whose content does not decode stay as they
	// are).
	utf16_byte_order:  Maybe(Byte_Order),
	// The text encoding of ID3v1; nil keeps that of tags.v1 (UTF-8 when its text was read as
	// UTF-8). sync_v1 and v1_from_tag do not see it: give them the same encoding to know what
	// does not fit.
	v1_encoding:       Maybe(V1_Encoding),
}

// The padding written when Write_Options.padding is nil: room for later edits to fit without
// moving the audio.
DEFAULT_PADDING :: 1024

@(private)
MAX_TAG_SIZE :: 1 << 28 - 1

// The bytes of an ID3v2 tag in its version: header, frames, padding and footer, allocated with
// allocator and owned by the caller, who frees them with delete. Each frame keeps its status and
// format flags and the bytes they need, so a frame read from a file comes out byte for byte, but
// for what the version writes its own way: syncsafe sizes in ID3v2.4 (where old iTunes wrote plain
// ones), reserved flag bits cleared, compression and unsynchronisation as the write options and
// the frames ask, the size limit applying to the tag as written. A compressed frame is compressed
// again with odid3's encoder: its content stays, its bytes may differ. Encrypted and badly
// compressed frames are written back as stored. A frame read from a file keeps its text encoding
// even when its version lacks it (some taggers wrote UTF-8 in ID3v2.3), unless
// Write_Options.encoding asks for another; a new frame must use one the version has. The header
// keeps the revision and the experimental flag; the extended header is not written, nor ID3v2.4's
// SEEK, whose offset to a next tag no longer holds once the tag is rewritten.
render :: proc(
	tag: ^Tag,
	options := Write_Options{},
	allocator := context.allocator,
) -> (
	bytes: []u8,
	err: Error,
) {
	if tag.version != .V2_2 && tag.version != .V2_3 && tag.version != .V2_4 {
		return nil, .No_Version
	}
	footer := options.footer
	unsync := options.unsynchronisation
	if footer && tag.version != .V2_4 || options.compression && tag.version == .V2_2 {
		return nil, .Not_In_Version
	}
	if .Compression in tag.flags && !options.replace_damaged {
		return nil, .Incomplete_Tag
	}
	if options.encoding != nil || options.utf16_byte_order != nil {
		if encoding, forced := options.encoding.?;
		   forced && !encoding_holds(encoding, tag.version) {
			return nil, .Encoding_Not_In_Version
		}
		work := clone_tag(tag, allocator) or_return
		defer destroy_tag(&work)
		reencode_tag(&work, options.encoding, options.utf16_byte_order) or_return
		as_set := options
		as_set.encoding, as_set.utf16_byte_order = nil, nil
		return render(&work, as_set, allocator)
	}
	forced: Frame_Format
	if unsync {
		forced += {.Unsynchronisation}
	}
	if options.compression {
		forced += {.Compression}
	}
	out := make([dynamic]u8, 0, 1024, allocator) or_return
	defer if err != nil {
		delete(out)
	}
	append(
		&out,
		..[]u8{'I', 'D', '3', tag_major(tag.version), tag.revision, 0, 0, 0, 0, 0},
	) or_return
	// Before ID3v2.4 the whole tag is unsynchronised, frame headers included; ID3v2.4 does it frame
	// by frame.
	body := &out
	whole: [dynamic]u8
	whole.allocator = allocator
	defer delete(whole)
	if unsync && tag.version != .V2_4 {
		body = &whole
	}
	rendered, unsynchronised := 0, 0
	for &f in tag.frames {
		if is_kind(f.id, {.SEEK}) && tag.version == .V2_4 {
			continue
		}
		render_frame(body, &f, tag.version, forced) or_return
		rendered += 1
		if frame_unsynchronised(&f) {
			unsynchronised += 1
		}
		framed := len(body) if body == &whole else len(body) - V2_HEADER_SIZE
		if framed > MAX_TAG_SIZE {
			return nil, .Tag_Too_Large
		}
	}
	every_frame_unsync := tag.version == .V2_4 && rendered > 0 && unsynchronised == rendered
	padding := 0 if footer else options.padding.? or_else DEFAULT_PADDING
	if padding < 0 {
		padding = 0
	}
	framed := len(body) if body == &whole else len(body) - V2_HEADER_SIZE
	if padding > MAX_TAG_SIZE - framed {
		return nil, .Tag_Too_Large
	}
	resize(body, len(body) + padding) or_return
	if body == &whole {
		if unsynchronised_size(whole[:]) > MAX_TAG_SIZE {
			return nil, .Tag_Too_Large
		}
		unsynchronise(&out, whole[:]) or_return
	}
	size := len(out) - V2_HEADER_SIZE
	if size > MAX_TAG_SIZE {
		return nil, .Tag_Too_Large
	}
	flags: u8
	if unsync || every_frame_unsync {
		flags |= 0x80
	}
	if .Experimental in tag.flags && tag.version != .V2_2 {
		flags |= 0x20
	}
	if footer {
		flags |= 0x10
	}
	out[5] = flags
	put_syncsafe(out[6:10], u32(size))
	if footer {
		footer: [V2_FOOTER_SIZE]u8
		copy(footer[:], "3DI")
		copy(footer[3:], out[3:V2_HEADER_SIZE])
		append(&out, ..footer[:]) or_return
	}
	return out[:], nil
}

@(private)
tag_major :: proc(version: V2_Version) -> u8 {
	switch version {
	case .V2_2:
		return 2
	case .V2_3:
		return 3
	case .V2_4:
		return 4
	case .None:
	}
	return 0
}

@(private)
put_syncsafe :: proc(b: []u8, n: u32) {
	b[0] = u8(n >> 21) & 0x7F
	b[1] = u8(n >> 14) & 0x7F
	b[2] = u8(n >> 7) & 0x7F
	b[3] = u8(n) & 0x7F
}

@(private)
put_be32 :: proc(b: []u8, n: u32) {
	b[0] = u8(n >> 24)
	b[1] = u8(n >> 16)
	b[2] = u8(n >> 8)
	b[3] = u8(n)
}

// A frame whose data is its content is written with the bytes its flags need before the content,
// compressed and unsynchronised when its format or forced asks for it; one whose data is not
// (encrypted, badly compressed, too short) is written back as it was stored. A frame read from a
// file (or from a chapter's bytes, which read says, as its offset is -1) only needs an ID that a
// reader finds again; a new one, a valid ID and a text encoding its version has.
@(private)
render_frame :: proc(
	out: ^[dynamic]u8,
	f: ^Frame,
	version: V2_Version,
	forced: Frame_Format = {},
	read := false,
) -> Error {
	if f.problem == .Skipped_Picture {
		return .Incomplete_Tag
	}
	id_len := 3 if version == .V2_2 else 4
	if len(f.id) != id_len || f.id[0] < 'A' || f.id[0] > 'Z' {
		return .Bad_Frame_Id
	}
	is_new := f.offset < 0 && !read
	if is_new && !is_frame_id(transmute([]u8)f.id) {
		return .Bad_Frame_Id
	}
	as_stored := is_stored(f)
	if as_stored && version == .V2_2 {
		// ID3v2.2 has no frame flags to say how the stored bytes were made.
		return .Not_In_Version
	}
	if is_new && !as_stored && has_encoding_byte(f.id) && len(f.data) > 0 {
		if f.data[0] > 3 || f.data[0] > 1 && version != .V2_4 {
			return .Encoding_Not_In_Version
		}
	}
	unsync := version == .V2_4 && (.Unsynchronisation in forced || frame_unsynchronised(f))
	asked := f.format
	if !is_kind(f.id, {.CHAP, .CTOC}) && .Encryption not_in f.format {
		asked += forced
	}
	compress := !as_stored && version != .V2_2 && .Compression in asked
	format := f.format - {.Unsynchronisation}
	if unsync {
		format += {.Unsynchronisation}
	}
	if compress {
		format += {.Compression}
		// ID3v2.4 gives the size before compression in the data length indicator, which a
		// compressed frame must have.
		if version == .V2_4 {
			format += {.Data_Length_Indicator}
		}
	}
	if version != .V2_4 {
		format -= {.Data_Length_Indicator}
	}
	if version == .V2_2 {
		format = {}
	}

	extras: [6]u8
	n := 0
	if f.problem != .Too_Short {
		data_length := u32(len(f.data)) if !as_stored else u32(max(f.data_length, 0))
		order := [3]Frame_Format_Flag{.Compression, .Encryption, .Grouping}
		if version == .V2_4 {
			order = {.Grouping, .Encryption, .Data_Length_Indicator}
		}
		for flag in order {
			if flag not_in format {
				continue
			}
			switch flag {
			case .Grouping:
				extras[n] = f.group
				n += 1
			case .Encryption:
				extras[n] = f.method
				n += 1
			case .Compression:
				put_be32(extras[n:], data_length)
				n += 4
			case .Data_Length_Indicator:
				// A frame written as stored keeps an indicator too large to be syncsafe as it was.
				if data_length > MAX_TAG_SIZE {
					put_be32(extras[n:], data_length)
				} else {
					put_syncsafe(extras[n:], data_length)
				}
				n += 4
			case .Unsynchronisation:
			}
		}
	}

	payload := f.data
	compressed: []u8
	defer delete(compressed, out.allocator)
	if compress {
		// The size before compression is written too, and has the same limit.
		if len(f.data) > MAX_TAG_SIZE {
			return .Tag_Too_Large
		}
		compressed = deflate_zlib(f.data, out.allocator) or_return
		payload = compressed
	}
	stored: [dynamic]u8
	stored.allocator = out.allocator
	defer delete(stored)
	if unsync {
		// The bytes the flags add and the data are one stream.
		if unsynchronised_size(extras[:n], payload) > MAX_TAG_SIZE {
			return .Tag_Too_Large
		}
		unsynchronise(&stored, extras[:n], payload) or_return
		n = 0
		payload = stored[:]
	}
	size := n + len(payload)
	switch version {
	case .V2_2:
		if size >= 1 << 24 {
			return .Tag_Too_Large
		}
		append(out, f.id) or_return
		append(out, u8(size >> 16), u8(size >> 8), u8(size)) or_return
	case .V2_3, .V2_4:
		if size > MAX_TAG_SIZE {
			return .Tag_Too_Large
		}
		header: [FRAME_HEADER_SIZE]u8
		copy(header[:], f.id)
		if version == .V2_4 {
			put_syncsafe(header[4:8], u32(size))
		} else {
			put_be32(header[4:8], u32(size))
		}
		header[8] = status_byte(version, f.status)
		for bit, flag in format_bits(version) {
			if flag in format {
				header[9] |= bit
			}
		}
		append(out, ..header[:]) or_return
	case .None:
	}
	append(out, ..extras[:n]) or_return
	append(out, ..payload) or_return
	return nil
}

// A frame whose unsynchronisation flag lied was not unsynchronised; it is written plain unless the
// whole tag is.
@(private)
frame_unsynchronised :: proc(f: ^Frame) -> bool {
	return .Unsynchronisation in f.format && f.problem != .Bad_Unsynchronisation
}

@(private)
status_byte :: proc(version: V2_Version, status: Frame_Status) -> (b: u8) {
	shift: u8 = 1 if version == .V2_4 else 0
	if .Discard_On_Tag_Alter in status {
		b |= 0x80 >> shift
	}
	if .Discard_On_File_Alter in status {
		b |= 0x40 >> shift
	}
	if .Read_Only in status {
		b |= 0x20 >> shift
	}
	return
}

// The frames whose content starts with a text encoding byte, in every version's IDs.
@(private)
has_encoding_byte :: proc(id: string) -> bool {
	if len(id) > 0 && id[0] == 'T' || is_itunes_text_frame(id) {
		return true
	}
	return is_kind(id, {.COMM, .USLT, .APIC, .WXXX, .SYLT, .GEOB, .USER, .OWNE, .COMR, .IPLS})
}
