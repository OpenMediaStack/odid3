package odid3

import "base:runtime"
import "core:slice"
import "core:strings"

// A frame a conversion removed, or carried only in part, and why. Converting an ID3v2.2 tag lists
// its frames under the IDs they have in it.
Dropped_Frame :: struct {
	id:     string,
	reason: Drop_Reason,
}

// The frames a conversion removed or carried only in part, in the order it met them. Free with
// destroy and the allocator given to convert.
Dropped_Frames :: [dynamic]Dropped_Frame

// Why a conversion removed a frame, or carried it only in part.
Drop_Reason :: enum u8 {
	// The target version has no frame with this layout (RVA2 in ID3v2.3, RVAD in ID3v2.4...), or
	// the value has no place there (a second date, a day without its year, a date that is none).
	No_Equivalent,
	// Encrypted, or compressed in a way that cannot be carried without its key or sizes.
	Encrypted,
	// In a group of frames (the grouping flag), which ID3v2.2 has no room for.
	Grouped,
	// A frame odid3 does not know, which asks to be dropped when its tag changes.
	Discard_On_Tag_Alter,
	// Text in an encoding the target version does not have, in a frame odid3 cannot re-encode.
	Not_Encodable,
	// The tag was converted to .None.
	Tag_Removed,
	// Converted, but part of its value has no place in the target version: a date's seconds or a
	// month without its day in ID3v2.3, values after the first, the group of a frame merged into
	// a frame of another group; or re-encoded without what its text held that does not decode
	// (bytes other than NULs after a comment, lyrics or the URL of a WXXX, a UTF-16 surrogate
	// without its pair, which becomes U+FFFD, an odd last byte of UTF-16 text other than a NUL).
	Partly_Converted,
}

// A deep copy, to preview a conversion or an edit without touching the original. The copy belongs
// to the caller, who frees it with destroy.
clone :: proc {
	clone_tag,
	clone_tags,
}

// See clone.
clone_tag :: proc(tag: ^Tag, allocator := context.allocator) -> (duplicate: Tag, err: Error) {
	duplicate = tag^
	duplicate.allocator = allocator
	duplicate.frames = make([dynamic]Frame, 0, len(tag.frames), allocator) or_return
	defer if err != nil {
		destroy_tag(&duplicate)
	}
	for &f in tag.frames {
		frame := clone_frame(&f, allocator) or_return
		if _, append_err := append(&duplicate.frames, frame); append_err != nil {
			destroy_frame(&frame)
			return duplicate, append_err
		}
	}
	return
}

// See clone.
clone_tags :: proc(tags: ^Tags, allocator := context.allocator) -> (duplicate: Tags, err: Error) {
	duplicate.layout, duplicate.warnings = tags.layout, tags.warnings
	duplicate.v2 = clone_tag(&tags.v2, allocator) or_return
	duplicate.v1, err = clone_v1(&tags.v1, allocator)
	if err != nil {
		destroy_tag(&duplicate.v2)
	}
	return
}

@(private)
clone_frame :: proc(f: ^Frame, allocator: runtime.Allocator) -> (duplicate: Frame, err: Error) {
	duplicate = f^
	duplicate.allocator = allocator
	duplicate.id = strings.clone(f.id, allocator) or_return
	duplicate.data, err = clone_bytes(f.data, allocator)
	if err != nil {
		delete(duplicate.id, allocator)
	}
	return
}

// Converts a tag to another version: renames and merges frames (TYER, TDAT and TIME into TDRC,
// TORY into TDOR, IPLS into TIPL, and back; ID3v2.2's 3 letter IDs to 4 letters and back, PIC
// into APIC), converts the frames inside chapters, re-encodes text the target cannot hold, joins
// several values with "/" before ID3v2.4, and removes the frames it cannot carry; ID3v2.2 frames
// have no flags, so encrypted and grouped frames are removed first and the others lose theirs. It
// returns, in the order it met them, the frames it removed and those whose value it could only
// carry in part, each with the reason. From .None it only sets the version; to .None it removes
// every frame. Tags whose frames were not all read (a compressed ID3v2.2 tag, pictures skipped
// when they need a new layout) give .Incomplete_Tag. On an error the tag is left as it was. Free
// the result with destroy and the same allocator.
convert :: proc(
	tag: ^Tag,
	to: V2_Version,
	allocator := context.allocator,
) -> (
	dropped: Dropped_Frames,
	err: Error,
) {
	adopt_context_allocator(tag)
	from := tag.version
	switch {
	case from == to:
		return nil, nil
	case from == .None:
		tag.version = to
		return nil, nil
	case .Compression in tag.flags && to != .None:
		// A compressed ID3v2.2 tag: no scheme was ever defined, so its frames could not be read.
		return nil, .Incomplete_Tag
	}
	work := clone_tag(tag, tag.allocator) or_return
	list := make(Dropped_Frames, allocator)
	if err = convert_versions(&work, to, &list, allocator); err != nil {
		destroy_tag(&work)
		destroy_dropped(&list, allocator)
		return nil, err
	}
	destroy_tag(tag)
	tag^ = work
	return list, nil
}

// ID3v2.2 is converted through ID3v2.3, whose frames it renames.
@(private)
convert_versions :: proc(
	tag: ^Tag,
	to: V2_Version,
	dropped: ^Dropped_Frames,
	allocator: runtime.Allocator,
) -> Error {
	if to == .None {
		return convert_frames(tag, to, dropped, allocator)
	}
	from_v22 := tag.version == .V2_2
	if from_v22 {
		convert_from_v22(tag, dropped, allocator) or_return
	}
	renamed := len(dropped^)
	if to == .V2_2 {
		drop_flagged_for_v22(tag, dropped, allocator) or_return
	}
	// Going to ID3v2.2, an ID3v2.3 tag needs the same care as one from ID3v2.4: dates, people and
	// text in ID3v2.3's form first.
	middle := V2_Version.V2_3 if to == .V2_2 else to
	if tag.version != middle || to == .V2_2 {
		convert_frames(tag, middle, dropped, allocator) or_return
	}
	if from_v22 {
		restore_v22_ids(dropped^[renamed:], allocator) or_return
	}
	if to == .V2_2 {
		convert_to_v22(tag, dropped, allocator) or_return
	}
	tag.flags = {}
	return nil
}

// Converts the frames of a tag in place between ID3v2.3 and 2.4; on an error the tag is left half
// converted, which is why convert works on a copy.
@(private)
convert_frames :: proc(
	tag: ^Tag,
	to: V2_Version,
	dropped: ^Dropped_Frames,
	allocator: runtime.Allocator,
) -> Error {
	if to == .None {
		for len(tag.frames) > 0 {
			drop(tag, 0, .Tag_Removed, dropped, allocator) or_return
		}
		tag.version, tag.flags = .None, {}
		return nil
	}
	from := tag.version
	for i := 0; i < len(tag.frames); {
		if reason, drop_it := conversion_drop(&tag.frames[i], from, to); drop_it {
			drop(tag, i, reason, dropped, allocator) or_return
		} else {
			i += 1
		}
	}
	for i in 0 ..< len(tag.frames) {
		if is_kind(tag.frames[i].id, {.CHAP, .CTOC}) {
			convert_chapter(tag, i, to, dropped, allocator) or_return
		}
	}
	tag.version, tag.flags = to, {}
	convert_date(tag, from, dropped, allocator) or_return
	convert_original_year(tag, dropped, allocator) or_return
	convert_people(tag, dropped, allocator) or_return
	for i := 0; i < len(tag.frames); {
		if convert_text(tag, i, dropped, allocator) or_return {
			i += 1
		} else {
			drop(tag, i, .Not_Encodable, dropped, allocator) or_return
		}
	}
	for &f in tag.frames {
		if to != .V2_4 {
			f.format -= {.Data_Length_Indicator}
		} else if .Compression in f.format && f.data_length >= 0 {
			// ID3v2.4 gives the size before compression in the data length indicator.
			f.format += {.Data_Length_Indicator}
		}
	}
	return nil
}

// A frame rebuilt by a conversion keeps the group and the compression of the frame it replaces.
@(private)
carry_format :: proc(replacement, f: ^Frame) {
	replacement.format += f.format & {.Grouping, .Compression}
	replacement.group = f.group
}

@(private)
same_group :: proc(a, b: ^Frame) -> bool {
	grouped := .Grouping in a.format
	return grouped == (.Grouping in b.format) && (!grouped || a.group == b.group)
}

// The frames inside a CHAP or CTOC are laid out in their tag's version: they are converted with
// it, and the chapter encoded again.
@(private)
convert_chapter :: proc(
	tag: ^Tag,
	index: int,
	to: V2_Version,
	dropped: ^Dropped_Frames,
	allocator: runtime.Allocator,
) -> Error {
	f := &tag.frames[index]
	content := decode_owned(f, tag.version, tag.allocator) or_return
	defer destroy_content(&content, tag.allocator)
	inner := Tag {
		version   = tag.version,
		allocator = tag.allocator,
	}
	switch &c in content {
	case Chapter:
		inner.frames = c.frames
		defer c.frames = inner.frames
		convert_frames(&inner, to, dropped, allocator) or_return
	case Table_Of_Contents:
		inner.frames = c.frames
		defer c.frames = inner.frames
		convert_frames(&inner, to, dropped, allocator) or_return
	case Text, User_Text, Url, User_Url, Comment, Picture, Unique_File_Id, Popularimeter:
		return nil
	case Play_Counter, Private, Binary:
		return nil
	}
	replacement := encode_frame(content, f.id, to, tag.allocator) or_return
	replacement.status = f.status
	carry_format(&replacement, f)
	destroy_frame(f)
	f^ = replacement
	return nil
}

@(private)
drop_reason_of :: proc(f: ^Frame) -> Drop_Reason {
	if f.problem == .Encrypted || f.problem == .Bad_Compression {
		return .Encrypted
	}
	return .Not_Encodable
}

// The first value of a text frame, cloned with the tag's allocator; ok is false when the frame
// does not decode as text. partly tells whether the frame holds what the value cannot carry: text
// after a terminator, read as ID3v2.4 reads it, or text that does not decode whole (a UTF-16
// surrogate without its pair, which becomes U+FFFD, or an odd last byte other than a NUL).
@(private)
first_value :: proc(tag: ^Tag, f: ^Frame) -> (value: string, partly, ok: bool, err: Error) {
	content := decode_owned(f, .V2_4, tag.allocator) or_return
	defer destroy_content(&content, tag.allocator)
	text, is_text := content.(Text)
	if !is_text || len(text.values) == 0 {
		return "", false, false, nil
	}
	value = strings.clone(text.values[0], tag.allocator) or_return
	return value, len(text.values) > 1 || !text_survives(f, &content), true, nil
}

// Puts frames where the frame at index was, in its place; the tag takes them.
@(private)
replace_frame :: proc(tag: ^Tag, index: int, frames: []Frame) -> Error {
	return edit_frames(tag, {index}, frames)
}

// The date frames: the first TDRC becomes TYER, TDAT and TIME, or the first TYER with the first
// TDAT and TIME becomes TDRC. A date frame whose value goes nowhere (a second one, a TDAT without
// its year, a value that is no date) is listed, and one carried in part too. The tag already has
// its new version; from is the one its frames were read in.
@(private)
convert_date :: proc(
	tag: ^Tag,
	from: V2_Version,
	dropped: ^Dropped_Frames,
	allocator: runtime.Allocator,
) -> Error {
	first := [len(DATE_KINDS)]int{-1, -1, -1, -1}
	for i := 0; i < len(tag.frames); {
		k := -1
		for date, j in DATE_KINDS {
			if is_kind_in(tag.frames[i].id, {date}, from) {
				k = j
			}
		}
		switch {
		case k < 0:
			i += 1
		case tag.frames[i].problem != .None && tag.frames[i].problem != .Bad_Data_Length:
			drop(tag, i, drop_reason_of(&tag.frames[i]), dropped, allocator) or_return
		case first[k] >= 0:
			drop(tag, i, .No_Equivalent, dropped, allocator) or_return
		case:
			first[k] = i
			i += 1
		}
	}
	if tag.version == .V2_4 {
		return date_to_v24(tag, first, dropped, allocator)
	}
	return date_to_v23(tag, first, dropped, allocator)
}


// The format of a text frame to keep for the frame that replaces it.
@(private)
format_of :: proc(f: ^Frame) -> Maybe(Text_Format) {
	if encoding, ok := frame_encoding(f); ok {
		return text_format(encoding, f)
	}
	return nil
}

// Lists a frame whose value a conversion carried only in part.
@(private)
note :: proc(
	dropped: ^Dropped_Frames,
	id: string,
	reason: Drop_Reason,
	allocator: runtime.Allocator,
) -> Error {
	cloned := strings.clone(id, allocator) or_return
	if _, err := append(dropped, Dropped_Frame{cloned, reason}); err != nil {
		delete(cloned, allocator)
		return err
	}
	return nil
}

// TORY holds a year, TDOR a timestamp: TORY goes to TDOR as it is, TDOR to TORY as its year.
@(private)
convert_original_year :: proc(
	tag: ^Tag,
	dropped: ^Dropped_Frames,
	allocator: runtime.Allocator,
) -> Error {
	source: Frame_Kind = .TORY if tag.version == .V2_4 else .TDOR
	target: Frame_Kind = .TDOR if tag.version == .V2_4 else .TORY
	at := -1
	for i := 0; i < len(tag.frames); {
		f := &tag.frames[i]
		switch {
		case !is_kind_in(f.id, {source}, tag.version):
			i += 1
		case f.problem != .None && f.problem != .Bad_Data_Length:
			drop(tag, i, drop_reason_of(f), dropped, allocator) or_return
		case at >= 0:
			drop(tag, i, .No_Equivalent, dropped, allocator) or_return
		case:
			at = i
			i += 1
		}
	}
	if at < 0 {
		return nil
	}
	value, partly, ok := first_value(tag, &tag.frames[at]) or_return
	defer delete(value, tag.allocator)
	carried := value
	if tag.version != .V2_4 {
		if !ok || len(value) < 4 || !is_number(value[:4]) {
			return drop(tag, at, .No_Equivalent, dropped, allocator)
		}
		carried = value[:4]
	}
	if !ok {
		return drop(tag, at, .Not_Encodable, dropped, allocator)
	}
	frame := text_frame(tag, target, {carried}, format_of(&tag.frames[at])) or_return
	carry_format(&frame, &tag.frames[at])
	replace_frame(tag, at, {frame}) or_return
	if partly || len(carried) < len(value) {
		note(dropped, id_in_tag(source, tag.version), .Partly_Converted, allocator) or_return
	}
	return nil
}

// ID3v2.3's IPLS and ID3v2.4's TIPL and TMCL hold pairs of a role and a name: TIPL and TMCL merge
// into IPLS, IPLS goes to TIPL.
@(private)
convert_people :: proc(
	tag: ^Tag,
	dropped: ^Dropped_Frames,
	allocator: runtime.Allocator,
) -> Error {
	sources := Frame_Kinds{.IPLS} if tag.version == .V2_4 else {.TIPL, .TMCL, .IPLS}
	people := make([dynamic]string, tag.allocator)
	defer {
		for p in people {
			delete(p, tag.allocator)
		}
		delete(people)
	}
	at := -1
	previous: Maybe(Text_Format)
	for i := 0; i < len(tag.frames); {
		f := &tag.frames[i]
		if !is_kind_in(f.id, sources, tag.version) {
			i += 1
			continue
		}
		ok, whole := people_of_frame(f, &people, tag.allocator) or_return
		switch {
		case !ok:
			drop(tag, i, drop_reason_of(f), dropped, allocator) or_return
		case at < 0:
			if !whole {
				note(dropped, f.id, .Partly_Converted, allocator) or_return
			}
			at = i
			previous = format_of(f)
			i += 1
		case:
			if !whole || !same_group(f, &tag.frames[at]) {
				note(dropped, f.id, .Partly_Converted, allocator) or_return
			}
			remove_frame(tag, i)
		}
	}
	if at < 0 {
		return nil
	}
	if len(people) == 0 {
		remove_frame(tag, at)
		return nil
	}
	format := keep_format(previous, tag.version, ..people[:])
	data := make([dynamic]u8, tag.allocator)
	defer delete(data)
	append(&data, u8(format.encoding)) or_return
	for value in people {
		encode_string(&data, format.encoding, value, true, format.order) or_return
	}
	frame := make_frame(
		Frame_Kind.TIPL if tag.version == .V2_4 else .IPLS,
		data[:],
		tag.version,
		tag.allocator,
	) or_return
	frame.status = format.status
	carry_format(&frame, &tag.frames[at])
	return replace_frame(tag, at, {frame})
}

// Appends the strings of a people frame, padded to whole pairs, each read in the byte order
// decode_values reads it in; ok is false when the frame does not decode, whole is false when a
// string does not decode whole (a UTF-16 surrogate without its pair, which becomes U+FFFD, or an
// odd last byte other than a NUL).
@(private)
people_of_frame :: proc(
	f: ^Frame,
	people: ^[dynamic]string,
	allocator: runtime.Allocator,
) -> (
	ok, whole: bool,
	err: Error,
) {
	encoding, known := frame_encoding(f)
	if !known {
		return false, false, nil
	}
	whole = true
	order := encoding
	count := 0
	for rest := f.data[1:]; len(rest) > 0; {
		text: []u8
		text, rest, _ = split_terminated(encoding, rest)
		whole = whole && decodes_whole(order, text)
		value := decode_text(order, text, allocator) or_return
		if _, append_err := append(people, value); append_err != nil {
			delete(value, allocator)
			return false, false, append_err
		}
		if count == 0 {
			order = byte_order_of(order, text)
		}
		count += 1
	}
	if count % 2 == 1 {
		append(people, "") or_return
	}
	return true, whole, nil
}

// Renames ID3v2.2 frames to their ID3v2.3 IDs, turns PIC into APIC, and drops the frames ID3v2.3
// has no frame for.
@(private)
convert_from_v22 :: proc(
	tag: ^Tag,
	dropped: ^Dropped_Frames,
	allocator: runtime.Allocator,
) -> Error {
	for i := 0; i < len(tag.frames); {
		f := &tag.frames[i]
		id := v22_to_v23(f.id)
		switch {
		case id == "":
			drop(tag, i, .No_Equivalent, dropped, allocator) or_return
		case is_kind(f.id, {.APIC}) &&
		     !(change_picture_layout(tag, i, .V2_2, .V2_3, dropped, allocator) or_return):
			drop(tag, i, .No_Equivalent, dropped, allocator) or_return
		case is_kind(f.id, {.APIC}):
			i += 1
		case:
			rename_frame(f, id) or_return
			i += 1
		}
	}
	tag.version = .V2_3
	return nil
}

// The steps after convert_from_v22 list the frames of an ID3v2.2 tag under the ID3v2.3 IDs it
// renamed them to; listed gets back the IDs of the tag the caller converts. What convert_from_v22
// listed itself already has them, 4 letters included for a frame a caller added (make_frame does
// not check the ID against the version).
@(private)
restore_v22_ids :: proc(listed: []Dropped_Frame, allocator: runtime.Allocator) -> Error {
	for &d in listed {
		if id := v23_to_v22(d.id); id != "" {
			restored := strings.clone(id, allocator) or_return
			delete(d.id, allocator)
			d.id = restored
		}
	}
	return nil
}

// ID3v2.2 frames have no flags, so the frames that cannot do without theirs (encrypted, grouped,
// or shorter than their flags announce) are dropped before the ID3v2.3 step, under their own IDs:
// that step would split a grouped TDRC into TYER, TDAT and TIME, dropped under IDs the tag does
// not have, and merge people frames of different groups, a grouped one taking the other's people
// with it or being kept in it.
@(private)
drop_flagged_for_v22 :: proc(
	tag: ^Tag,
	dropped: ^Dropped_Frames,
	allocator: runtime.Allocator,
) -> Error {
	for i := 0; i < len(tag.frames); {
		f := &tag.frames[i]
		switch {
		case f.problem == .Too_Short:
			drop(tag, i, .No_Equivalent, dropped, allocator) or_return
		case is_stored(f) || .Encryption in f.format:
			drop(tag, i, .Encrypted, dropped, allocator) or_return
		case .Grouping in f.format:
			drop(tag, i, .Grouped, dropped, allocator) or_return
		case:
			i += 1
		}
	}
	return nil
}

// Renames ID3v2.3 frames to their ID3v2.2 IDs, turns APIC into PIC, and drops the frames without
// an ID3v2.2 ID; drop_flagged_for_v22 has dropped those whose flags ID3v2.2 has no room for.
@(private)
convert_to_v22 :: proc(
	tag: ^Tag,
	dropped: ^Dropped_Frames,
	allocator: runtime.Allocator,
) -> Error {
	for i := 0; i < len(tag.frames); {
		f := &tag.frames[i]
		id := v23_to_v22(f.id)
		switch {
		case id == "":
			drop(tag, i, .No_Equivalent, dropped, allocator) or_return
		case is_kind(f.id, {.APIC}) &&
		     !(change_picture_layout(tag, i, .V2_3, .V2_2, dropped, allocator) or_return):
			drop(tag, i, .No_Equivalent, dropped, allocator) or_return
		case is_kind(f.id, {.APIC}):
			i += 1
		case:
			if is_kind(f.id, {.RVAD}) && (stereo_volume_only(f) or_return) {
				note(dropped, f.id, .Partly_Converted, allocator) or_return
			}
			rename_frame(f, id) or_return
			// ID3v2.2 frames have no flags.
			f.status, f.format = {}, {}
			i += 1
		}
	}
	tag.version = .V2_2
	return nil
}

// ID3v2.2's RVA holds the volume of the right and left channels; ID3v2.3's RVAD can add the back,
// centre and bass channels after them, which are cut. cut is true when there were some.
@(private)
stereo_volume_only :: proc(f: ^Frame) -> (cut: bool, err: Error) {
	if len(f.data) < 2 || f.problem != .None {
		return false, nil
	}
	stereo := 2 + 4 * ((int(f.data[1]) + 7) / 8)
	if len(f.data) <= stereo {
		return false, nil
	}
	f.data = shrink(f.data, stereo, f.allocator) or_return
	return true, nil
}

@(private)
rename_frame :: proc(f: ^Frame, id: string) -> runtime.Allocator_Error {
	renamed := strings.clone(id, f.allocator) or_return
	delete(f.id, f.allocator)
	f.id = renamed
	return nil
}

// APIC holds a MIME type where PIC holds a 3 character image format: the picture is decoded and
// encoded again, in its encoding and byte order when the target version has that encoding, and
// listed when its description does not decode whole. ok is false when it cannot be decoded, or
// when ID3v2.2 has no image format for its MIME type.
@(private)
change_picture_layout :: proc(
	tag: ^Tag,
	index: int,
	from, to: V2_Version,
	dropped: ^Dropped_Frames,
	allocator: runtime.Allocator,
) -> (
	ok: bool,
	err: Error,
) {
	f := &tag.frames[index]
	if f.problem == .Skipped_Picture {
		return false, .Incomplete_Tag
	}
	content, decode_err := decode_frame(f, from, tag.allocator)
	defer destroy_content(&content, tag.allocator)
	if alloc, is_alloc := decode_err.(runtime.Allocator_Error); is_alloc {
		return false, alloc
	}
	picture, is_picture := content.(Picture)
	if decode_err != nil || !is_picture {
		return false, nil
	}
	format := keep_format(text_format(picture.encoding, f), to, picture.description)
	picture.encoding = format.encoding
	replacement, encode_err := encode_frame_in(
		picture,
		id_in_tag(.APIC, to),
		to,
		format.order,
		tag.allocator,
	)
	if encode_err == Error(Format_Error.Not_In_Version) {
		// A MIME type ID3v2.2 has no 3 letter name for.
		return false, nil
	}
	if encode_err != nil {
		return false, encode_err
	}
	if !text_survives(f, &content) {
		if err = note(dropped, f.id, .Partly_Converted, allocator); err != nil {
			destroy_frame(&replacement)
			return false, err
		}
	}
	if to != .V2_2 {
		replacement.status = f.status
	}
	destroy_frame(f)
	f^ = replacement
	return true, nil
}

// The ID3v2.3 ID of an ID3v2.2 frame, "" for one ID3v2.3 has no counterpart for (CRM, LNK).
@(private)
v22_to_v23 :: proc(id: string) -> string {
	return counterpart(id, .V2_2, .V2_3)
}

@(private)
v23_to_v22 :: proc(id: string) -> string {
	return counterpart(id, .V2_3, .V2_2)
}

@(private = "file")
counterpart :: proc(id: string, from, to: V2_Version) -> string {
	kind, known := frame_kind(id, from)
	if !known {
		return ""
	}
	target, _ := frame_id(kind, to)
	return target
}

// Frees the IDs of dropped frames and the list, with the allocator given to convert.
destroy_dropped :: proc(dropped: ^Dropped_Frames, allocator := context.allocator) {
	for d in dropped {
		delete(d.id, allocator)
	}
	delete(dropped^)
	dropped^ = nil
}

// Frames whose binary layout changed between ID3v2.3 and 2.4.
@(private, rodata)
V23_ONLY := Frame_Kinds{.EQUA, .RVAD}
@(private, rodata)
V24_ONLY := Frame_Kinds{.EQU2, .RVA2, .ASPI, .SEEK, .SIGN}

@(private)
conversion_drop :: proc(f: ^Frame, from, to: V2_Version) -> (reason: Drop_Reason, drop_it: bool) {
	kind, known := frame_kind(f.id, from)
	if known && (to == .V2_3 && kind in V24_ONLY || to == .V2_4 && kind in V23_ONLY) {
		return .No_Equivalent, true
	}
	if .Discard_On_Tag_Alter in f.status && !known {
		return .Discard_On_Tag_Alter, true
	}
	// A frame shorter than the bytes its flags announce would have other bytes taken for them in
	// another version's layout.
	if f.problem == .Too_Short {
		return .No_Equivalent, true
	}
	as_stored := is_stored(f)
	// Before ID3v2.4, a compressed frame states its decompressed size, which an encrypted or
	// badly compressed frame from ID3v2.4 may not have given.
	lacks_size := .Compression in f.format && f.data_length < 0
	// ID3v2.3 has no room for the data length indicator of an encrypted frame that is not
	// compressed, which its method may need.
	loses_indicator :=
		to == .V2_3 && .Compression not_in f.format && .Data_Length_Indicator in f.format
	// ID3v2.4's data length indicator is syncsafe, so it holds less than ID3v2.3's size.
	too_large := to == .V2_4 && f.data_length > MAX_TAG_SIZE
	if as_stored && (lacks_size || loses_indicator || too_large) {
		return .Encrypted, true
	}
	// The frames inside a chapter are laid out in the source version: one that cannot be decoded
	// cannot be converted.
	if is_kind(f.id, {.CHAP, .CTOC}) && f.problem != .None && f.problem != .Bad_Data_Length {
		return .Encrypted if as_stored else .No_Equivalent, true
	}
	return {}, false
}

@(private)
drop :: proc(
	tag: ^Tag,
	index: int,
	reason: Drop_Reason,
	dropped: ^Dropped_Frames,
	allocator: runtime.Allocator,
) -> Error {
	id := strings.clone(tag.frames[index].id, allocator) or_return
	if _, err := append(dropped, Dropped_Frame{id, reason}); err != nil {
		delete(id, allocator)
		return err
	}
	remove_frame(tag, index)
	return nil
}


// ID3v2.3 parts of a date that go nowhere, listed and removed, with the frame that replaces them
// put in the place of the first.
@(private)
replace_date_parts :: proc(tag: ^Tag, remove: ^[dynamic]int, frames: []Frame) -> Error {
	slice.sort(remove[:])
	return edit_frames(tag, remove[:], frames)
}

@(private)
date_to_v24 :: proc(
	tag: ^Tag,
	first: [4]int,
	dropped: ^Dropped_Frames,
	allocator: runtime.Allocator,
) -> Error {
	remove := make([dynamic]int, tag.allocator)
	defer delete(remove)
	year, day_month, hours: string
	defer delete(year, tag.allocator)
	defer delete(day_month, tag.allocator)
	defer delete(hours, tag.allocator)
	partly: [4]bool
	year_ok, day_ok, time_ok: bool
	// A TDRC already there wins over the ID3v2.3 parts.
	if first[0] < 0 {
		if first[1] >= 0 {
			year, partly[1], year_ok = first_value(tag, &tag.frames[first[1]]) or_return
		}
		if first[2] >= 0 {
			day_month, partly[2], day_ok = first_value(tag, &tag.frames[first[2]]) or_return
		}
		if first[3] >= 0 {
			hours, partly[3], time_ok = first_value(tag, &tag.frames[first[3]]) or_return
		}
	}
	full_year := year_ok && len(year) == 4 && is_number(year)
	day_ok = day_ok && full_year && is_pair_within(day_month, 31, 12, 1)
	time_ok = time_ok && day_ok && is_pair_within(hours, 23, 59, 0)
	used := [4]bool{false, year_ok, day_ok, time_ok}
	for k in 1 ..= 3 {
		if first[k] < 0 {
			continue
		}
		append(&remove, first[k]) or_return
		if !used[k] {
			note(dropped, tag.frames[first[k]].id, .No_Equivalent, allocator) or_return
		}
	}
	if !year_ok {
		return replace_date_parts(tag, &remove, nil)
	}
	buf: [16]u8
	date := strings.builder_from_bytes(buf[:])
	strings.write_string(&date, year if full_year else "")
	if day_ok {
		fmt_parts := [?]string{"-", day_month[2:4], "-", day_month[0:2]}
		for part in fmt_parts {
			strings.write_string(&date, part)
		}
	}
	if time_ok {
		fmt_parts := [?]string{"T", hours[0:2], ":", hours[2:4]}
		for part in fmt_parts {
			strings.write_string(&date, part)
		}
	}
	value := strings.to_string(date) if full_year else year
	for k in 1 ..= 3 {
		if used[k] && (partly[k] || !same_group(&tag.frames[first[k]], &tag.frames[first[1]])) {
			note(dropped, tag.frames[first[k]].id, .Partly_Converted, allocator) or_return
		}
	}
	frame := text_frame(tag, .TDRC, {value}, format_of(&tag.frames[first[1]])) or_return
	carry_format(&frame, &tag.frames[first[1]])
	return replace_date_parts(tag, &remove, {frame})
}

@(private)
date_to_v23 :: proc(
	tag: ^Tag,
	first: [4]int,
	dropped: ^Dropped_Frames,
	allocator: runtime.Allocator,
) -> Error {
	if first[0] < 0 {
		return nil
	}
	remove := make([dynamic]int, tag.allocator)
	defer delete(remove)
	append(&remove, first[0]) or_return
	// A TDRC wins over ID3v2.3 parts that were already there.
	for k in 1 ..= 3 {
		if first[k] >= 0 {
			append(&remove, first[k]) or_return
			note(dropped, tag.frames[first[k]].id, .No_Equivalent, allocator) or_return
		}
	}
	value, partly, ok := first_value(tag, &tag.frames[first[0]]) or_return
	defer delete(value, tag.allocator)
	if !ok || len(value) < 4 || !is_number(value[:4]) {
		note(dropped, tag.frames[first[0]].id, .No_Equivalent, allocator) or_return
		return replace_date_parts(tag, &remove, nil)
	}
	digits :: proc(s: string, at: int) -> bool {
		return at + 2 <= len(s) && is_number(s[at:at + 2])
	}
	month := len(value) >= 7 && value[4] == '-' && digits(value, 5)
	day := month && len(value) >= 10 && value[7] == '-' && digits(value, 8)
	hour := day && len(value) >= 13 && (value[10] == 'T' || value[10] == ' ') && digits(value, 11)
	minute := hour && len(value) >= 16 && value[13] == ':' && digits(value, 14)
	day_month := [4]u8{value[8], value[9], value[5], value[6]} if day else {}
	hours := [4]u8{value[11], value[12], value[14], value[15]} if minute else {}
	day = day && is_pair_within(string(day_month[:]), 31, 12, 1)
	minute = minute && day && is_pair_within(string(hours[:]), 23, 59, 0)
	carried := 16 if minute else 10 if day else 4

	previous := format_of(&tag.frames[first[0]])
	texts := [3]struct {
		kind:  Frame_Kind,
		value: string,
		keep:  bool,
	} {
		{.TYER, value[:4], true},
		{.TDAT, string(day_month[:]), day},
		{.TIME, string(hours[:]), minute},
	}
	frames: [3]Frame
	n := 0
	for text in texts {
		if !text.keep {
			continue
		}
		frame, err := text_frame(tag, text.kind, {text.value}, previous)
		if err != nil {
			for &f in frames[:n] {
				destroy_frame(&f)
			}
			return err
		}
		carry_format(&frame, &tag.frames[first[0]])
		frames[n] = frame
		n += 1
	}
	if partly || len(value) > carried {
		if err := note(dropped, tag.frames[first[0]].id, .Partly_Converted, allocator);
		   err != nil {
			for &f in frames[:n] {
				destroy_frame(&f)
			}
			return err
		}
	}
	return replace_date_parts(tag, &remove, frames[:n])
}

// Re-encodes a text frame its new version cannot hold as it is: an encoding the version lacks,
// or, before ID3v2.4, several values, which ID3v2.3 joins with "/" (genre references go in
// parentheses before the rest); a frame whose encoding the version has keeps it, with its byte
// order. ok is false when such a frame cannot be decoded and encoded again; one whose text does
// not decode whole is re-encoded without what is lost, and listed.
@(private)
convert_text :: proc(
	tag: ^Tag,
	index: int,
	dropped: ^Dropped_Frames,
	allocator: runtime.Allocator,
) -> (
	ok: bool,
	err: Error,
) {
	f := &tag.frames[index]
	if is_stored(f) || !has_encoding_byte(f.id) || len(f.data) == 0 {
		return true, nil
	}
	encoding, known := encoding_of(f.data[0])
	if !known {
		return true, nil
	}
	holds := encoding_holds(encoding, tag.version)
	if holds && (tag.version == .V2_4 || f.id[0] != 'T') {
		return true, nil
	}
	content, decode_err := decode_frame(f, .V2_4, tag.allocator)
	defer destroy_content(&content, tag.allocator)
	if decode_err != nil {
		if alloc, is_alloc := decode_err.(runtime.Allocator_Error); is_alloc {
			return false, alloc
		}
		return holds, nil
	}
	changed := !holds
	previous := text_format(encoding, f)
	format: Text_Format
	switch &c in content {
	case Text:
		if len(c.values) > 1 {
			join_values(&c.values, is_kind_in(f.id, {.TCON}, tag.version), tag.allocator) or_return
			changed = true
		}
		format = keep_format(previous, tag.version, ..c.values)
		c.encoding = format.encoding
	case User_Text:
		if len(c.values) > 1 {
			join_values(&c.values, false, tag.allocator) or_return
			changed = true
		}
		format = keep_format(
			keep_format(previous, tag.version, ..c.values),
			tag.version,
			c.description,
		)
		c.encoding = format.encoding
	case User_Url:
		format = keep_format(previous, tag.version, c.description)
		c.encoding = format.encoding
	case Comment:
		format = keep_format(previous, tag.version, c.description, c.text)
		c.encoding = format.encoding
	case Picture:
		format = keep_format(previous, tag.version, c.description)
		c.encoding = format.encoding
	case Url,
	     Unique_File_Id,
	     Popularimeter,
	     Play_Counter,
	     Private,
	     Chapter,
	     Table_Of_Contents,
	     Binary:
		return holds, nil
	}
	if !changed {
		return true, nil
	}
	if !text_survives(f, &content) {
		note(dropped, f.id, .Partly_Converted, allocator) or_return
	}
	replacement := encode_frame_in(
		content,
		f.id,
		tag.version,
		format.order,
		tag.allocator,
	) or_return
	replacement.status = f.status
	carry_format(&replacement, f)
	destroy_frame(f)
	f^ = replacement
	return true, nil
}

// Joins several values into one with "/"; genre references ("17", "RX") go first in parentheses,
// as ID3v2.3 writes them, and text that starts with a parenthesis is escaped with another. Empty
// values, which extra terminators give, are dropped.
@(private)
join_values :: proc(values: ^[]string, genres: bool, allocator: runtime.Allocator) -> Error {
	reference :: proc(genres: bool, value: string) -> bool {
		return genres && genre_reference(value) != ""
	}
	escaped :: proc(genres: bool, value: string) -> bool {
		return genres && strings.has_prefix(value, "(")
	}
	size, texts := 0, 0
	for value in values {
		switch {
		case value == "":
		case reference(genres, value):
			size += len(value) + 2
		case:
			size += len(value) + (1 if texts > 0 else 0) + (1 if escaped(genres, value) else 0)
			texts += 1
		}
	}
	out := make([]u8, size, allocator) or_return
	at := 0
	for value in values {
		if reference(genres, value) {
			at += copy(out[at:], "(")
			at += copy(out[at:], value)
			at += copy(out[at:], ")")
		}
	}
	texts = 0
	for value in values {
		if value == "" || reference(genres, value) {
			continue
		}
		if texts > 0 {
			at += copy(out[at:], "/")
		}
		if escaped(genres, value) {
			at += copy(out[at:], "(")
		}
		at += copy(out[at:], value)
		texts += 1
	}
	one, err := make([]string, 1, allocator)
	if err != nil {
		delete(out, allocator)
		return err
	}
	one[0] = string(out)
	delete_strings(values^, allocator)
	values^ = one
	return nil
}
