package odid3

import "base:runtime"
import "core:os"

// What can stop a procedure of this package. A damaged tag is not an error: reading returns what
// it could read, with Warnings.
Error :: union #shared_nil {
	Format_Error,
	os.Error, // opening or reading a file
	runtime.Allocator_Error,
}

// What a procedure cannot do with the data or the values it was given.
Format_Error :: enum u8 {
	None,
	// decode_frame on a frame whose data is not its content: encrypted, badly compressed, skipped,
	// or shorter than its flags announce.
	Not_Decodable,
	// Frame data that does not follow the layout of its frame.
	Bad_Content,
	// Rendering a tag whose version is .None.
	No_Version,
	// A tag over 256 MB (the largest size a syncsafe integer holds), or a frame over the largest
	// size its version can write.
	Tag_Too_Large,
	// A frame ID that does not have the length of its version's IDs: 3 in ID3v2.2, 4 after.
	Bad_Frame_Id,
	// Text in UTF-16BE or UTF-8, which only ID3v2.4 has.
	Encoding_Not_In_Version,
	// A write option the version does not have, such as a footer before ID3v2.4.
	Not_In_Version,
	// Writing tags read with skip_picture_data: their pictures were not read.
	Incomplete_Tag,
	// Writing over a tag read with damage warnings (DAMAGE_WARNINGS) without
	// Write_Options.replace_damaged: the bytes that could not be read would be lost.
	Damaged_Tag,
}

// What reading found wrong in a file. The result holds what could be read despite it.
Warning :: enum u8 {
	// "ID3" followed by bytes that cannot be an ID3v2 header (a version below 2 or 0xFF, a size
	// that is not syncsafe): they are kept as unknown bytes.
	Bad_Header,
	// The ID3v2 tag claims more bytes than the file holds.
	Truncated_Tag,
	// An ID3v2 version after 2.4: the tag is kept as unknown bytes.
	Unsupported_Version,
	// Another ID3v2 tag, right after the first one or appended at the end. Writing replaces both
	// with a single tag.
	Second_V2_Tag,
	// An ID3v2.4 footer that does not repeat the tag header.
	Bad_Footer,
	// A frame header that cannot be right: the frames after it are lost.
	Damaged_Frames,
	// An extended header that cannot be right. When its size cannot be trusted either, the frames
	// are lost.
	Bad_Extended_Header,
	// Bytes other than zeros after the last frame, where the padding is.
	Data_In_Padding,
	// ID3v2.4 frame sizes written as plain integers rather than syncsafe ones, as old iTunes did.
	Plain_Frame_Sizes,
	// Frame IDs with characters other than A to Z and 0 to 9: the frames are kept.
	Bad_Frame_Ids,
	// The tag says it is unsynchronised, but its bytes cannot be: they are read as stored.
	Bad_Unsynchronisation,
	// At least one frame has a problem that is not of its own choosing: see Frame.problem.
	Frame_Problems,
	// More than 65536 frames: the frames after them are not read.
	Too_Many_Frames,
	// An ID3v2.2 tag with its compression flag set: no compression scheme was ever defined for it,
	// so its frames cannot be read.
	Compressed_V22_Tag,
}

// Every warning reading raised.
Warnings :: bit_set[Warning;u16]
