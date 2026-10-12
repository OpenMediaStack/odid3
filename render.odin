package odid3

// How to write a tag.
Write_Options :: struct {
	padding:         Maybe(int), // zeros after the frames; nil means DEFAULT_PADDING, below 0 none
	footer:          bool, // ID3v2.4 only; the spec forbids padding with a footer, so there is none
	// Allow rewriting a file whose tag was read with damage warnings (see write_file), and
	// rendering a tag whose frames could not be read at all (a compressed ID3v2.2 tag).
	replace_damaged: bool,
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
// ones), reserved flag bits cleared, and compression and unsynchronisation as the write options
// say. Encrypted and badly compressed frames are written back as stored. A frame read from a file
// keeps its text encoding even when its version lacks it (some taggers wrote UTF-8 in ID3v2.3); a
// new frame must use one the version has. The header keeps the revision and the experimental flag;
// the extended header is not written.
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
	if options.footer && tag.version != .V2_4 {
		return nil, .Not_In_Version
	}
	if .Compression in tag.flags && !options.replace_damaged {
		return nil, .Incomplete_Tag
	}
	out := make([dynamic]u8, 0, 1024, allocator) or_return
	defer if err != nil {
		delete(out)
	}
	append(
		&out,
		..[]u8{'I', 'D', '3', tag_major(tag.version), tag.revision, 0, 0, 0, 0, 0},
	) or_return
	for &f in tag.frames {
		render_frame(&out, &f, tag.version) or_return
		if len(out) - V2_HEADER_SIZE > MAX_TAG_SIZE {
			return nil, .Tag_Too_Large
		}
	}
	padding := 0 if options.footer else options.padding.? or_else DEFAULT_PADDING
	if padding < 0 {
		padding = 0
	}
	if padding > MAX_TAG_SIZE - (len(out) - V2_HEADER_SIZE) {
		return nil, .Tag_Too_Large
	}
	size := len(out) - V2_HEADER_SIZE + padding
	resize(&out, len(out) + padding) or_return
	flags: u8
	if .Experimental in tag.flags && tag.version != .V2_2 {
		flags |= 0x20
	}
	if options.footer {
		flags |= 0x10
	}
	out[5] = flags
	put_syncsafe(out[6:10], u32(size))
	if options.footer {
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

// A frame whose data is its content is written with the bytes its flags need before the content;
// one whose data is not (encrypted, badly compressed, too short) is written back as it was stored.
// A frame read from a file only needs an ID that a reader finds again; a new one, a valid ID and a
// text encoding its version has.
@(private)
render_frame :: proc(out: ^[dynamic]u8, f: ^Frame, version: V2_Version) -> Error {
	if f.problem == .Skipped_Picture {
		return .Incomplete_Tag
	}
	id_len := 3 if version == .V2_2 else 4
	if len(f.id) != id_len || f.id[0] < 'A' || f.id[0] > 'Z' {
		return .Bad_Frame_Id
	}
	is_new := f.offset < 0
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
	format := f.format - {.Unsynchronisation}
	if !as_stored {
		// Compressing on write comes with its own option; the data is written as it is.
		format -= {.Compression}
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

	size := n + len(f.data)
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
	append(out, ..f.data) or_return
	return nil
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
	switch id {
	case "COMM",
	     "COM",
	     "USLT",
	     "ULT",
	     "APIC",
	     "PIC",
	     "WXXX",
	     "WXX",
	     "SYLT",
	     "SLT",
	     "GEOB",
	     "GEO",
	     "USER",
	     "OWNE",
	     "COMR",
	     "IPLS",
	     "IPL":
		return true
	}
	return false
}
