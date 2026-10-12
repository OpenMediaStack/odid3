# Public API (proposal)

The public API of odid3 as designed, before any library code exists. It is the reference for the slices of the [roadmap](../AGENTS.md#roadmap) until `odin doc` replaces it at the v1 tag. Declarations are sketches: names and shapes are what matter, and each slice may refine them in its pull request, saying so.

## Principles

- **The model is exact.** A `Tag` holds every frame as read, unknown ones included, with its flags and its content bytes. Writing a tag writes the model as it is: an untouched frame comes out byte for byte when the version is unchanged. Nothing is dropped except by an explicit call (`convert`, `remove_frame`, `set` with an empty value), and those return what they dropped.
- **Typed accessors sit on top of the frames.** `get` and `set` cover the common fields; `decode_frame` and `encode_frame` turn any frame's bytes into a typed value and back.
- **Damage is not an error.** Reading returns an error only when nothing can be read (the file cannot be opened, a read fails, memory runs out). A damaged tag gives what could be read, plus warnings.
- **Ownership is explicit.** Everything a procedure allocates comes from its `allocator` parameter, and its doc comment says how to free it: `destroy` for the library's types, or freeing the whole allocator when it is an arena.
- **No global state.** Every procedure can run on several threads at once, on different values.

## Example

```odin
import id3 "odid3"

retitle :: proc(path: string) -> id3.Error {
	tags := id3.read_file(path) or_return
	defer id3.destroy(&tags)

	if tags.v2.version == .None {
		id3.convert(&tags.v2, .V2_4) or_return
	}
	id3.set(&tags.v2, .Title, "Paper Satellites") or_return
	overflow := id3.sync_v1(&tags, .Keep)
	if .Title in overflow {
		// The ID3v1 title will be cut to 30 Latin-1 characters.
	}
	return id3.write_file(path, &tags)
}
```

Developer mode, writing an ID3v2.2 tag and an ID3v1.0 tag, unsynchronised and without padding:

```odin
dropped := id3.convert(&tags.v2, .V2_2) or_return
defer id3.destroy(&dropped)
id3.sync_v1(&tags, .Always, .V1_0)
id3.write_file(path, &tags, {padding = 0, unsynchronisation = true}) or_return
```

The raw frame view:

```odin
for &frame in tags.v2.frames {
	content, _ := id3.decode_frame(&frame, tags.v2.version, context.temp_allocator)
	fmt.println(frame.id, frame.offset, frame.size, frame.status, frame.format, content)
}
```

## Versions and encodings

```odin
V2_Version :: enum u8 {
	None,
	V2_2,
	V2_3,
	V2_4,
}

V1_Version :: enum u8 {
	None,
	V1_0,
	V1_1,
}

// The values are the encoding byte of a frame.
Encoding :: enum u8 {
	Latin1  = 0, // ISO-8859-1
	UTF16   = 1, // UTF-16 with a byte order mark
	UTF16BE = 2, // ID3v2.4 only
	UTF8    = 3, // ID3v2.4 only
}
```

## Reading

```odin
read_bytes :: proc(data: []u8, options := Read_Options{}, allocator := context.allocator) -> (tags: Tags, err: Error)

// Reads the head and the tail of the file only, never the audio.
read_file :: proc(path: string, options := Read_Options{}, allocator := context.allocator) -> (tags: Tags, err: Error)

Read_Options :: struct {
	// For fast scans: picture frames are kept without their data, and the result cannot be
	// written (write_file returns .Incomplete_Tag).
	skip_picture_data: bool,
}

// Everything a file holds, owned by the allocator given to read_*. Free with destroy.
Tags :: struct {
	v2:       Tag, // version .None when the file has no ID3v2 tag
	v1:       V1_Tag, // version .None when the file has no ID3v1 tag
	layout:   Layout,
	warnings: Warnings,
}

Range :: struct {
	offset: i64,
	size:   i64, // 0 when absent
}

// Where each part of the file is, in bytes from its start.
Layout :: struct {
	file_size:   i64,
	v2:          Range, // the leading ID3v2 tag, header, padding and footer included
	v2_stacked:  Range, // ID3v2 tags right after the first one, replaced by it on write
	v2_appended: Range, // an ID3v2.4 tag found at the end through its footer
	audio:       Range, // the MPEG data, between the tags
	ape:         Range, // found, never parsed, always kept
	lyrics3:     Range, // found, never parsed, always kept
	v1_enhanced: Range, // the Enhanced TAG ("TAG+"), 227 bytes before ID3v1
	v1:          Range, // the last 128 bytes ("TAG")
}

Warning :: enum u8 {
	Bad_Header, // "ID3" then a version below 2 or 0xFF, or a size that is not syncsafe: kept as unknown bytes
	Truncated_Tag, // the ID3v2 tag claims more bytes than the file holds
	Damaged_Frames, // a frame header cannot be right: the frames after it are lost
	Bad_Extended_Header,
	Data_In_Padding, // non-zero bytes after the frames
	Plain_Frame_Sizes, // ID3v2.4 frame sizes written as plain integers, as old iTunes did
	Bad_Frame_Ids, // frame IDs with characters other than A to Z and 0 to 9: the frames are kept
	Bad_Unsynchronisation, // the tag says it is unsynchronised but cannot be: read as stored
	Compressed_V22_Tag, // no scheme was ever defined: the frames cannot be read
	Unsupported_Version, // ID3v2.5 or later: kept as unknown bytes
	Second_V2_Tag, // a second ID3v2 tag, appended or right after the first
	Bad_Footer,
	Frame_Problems, // at least one frame has a problem, see Frame.problem
	Too_Many_Frames, // more than 65536 frames: the frames after them are not read
}
Warnings :: bit_set[Warning; u16]
```

`Truncated_Tag`, `Damaged_Frames`, `Bad_Extended_Header`, `Data_In_Padding`, `Compressed_V22_Tag` and `Too_Many_Frames` mean that bytes of the tag could not be read: rewriting it would lose them, so `write_file` refuses unless `Write_Options.replace_damaged` is set.

## The ID3v2 model

```odin
Tag :: struct {
	version:   V2_Version,
	revision:  u8,
	flags:     Tag_Flags, // as read; render sets them from the write options
	extended:  Extended_Header,
	frames:    [dynamic]Frame,
	padding:   int, // bytes of padding read
	allocator: runtime.Allocator,
}

Tag_Flag :: enum u8 {
	Unsynchronisation,
	Extended_Header, // ID3v2.3 and 2.4
	Experimental,
	Footer, // ID3v2.4
	Compression, // ID3v2.2
}
Tag_Flags :: bit_set[Tag_Flag; u8]

// Read only in v1: dropped on write.
Extended_Header :: struct {
	present:      bool,
	crc:          Maybe(u32), // ID3v2.3 and 2.4
	padding_size: u32, // ID3v2.3
	update:       bool, // ID3v2.4: this tag updates an earlier one
	restrictions: Maybe(u8), // ID3v2.4, the raw byte
}

Frame :: struct {
	id:      string, // "TIT2", or "TT2" in an ID3v2.2 tag
	status:  Frame_Status,
	format:  Frame_Format, // compression and unsynchronisation are applied by render
	group:   u8, // when format has .Grouping
	method:  u8, // the encryption method, when format has .Encryption
	data:    []u8, // the content, extra bytes, unsynchronisation and compression removed
	problem: Frame_Problem,

	// Where the frame was read, for the raw frame view. offset is -1 for a new frame.
	offset:       i64, // of the frame header in the file
	size:         int, // the size field of the frame header
	stored_flags: [2]u8, // the flag bytes of the frame header (none in ID3v2.2)
	data_length:  int, // the data length indicator (ID3v2.4) or decompressed size (ID3v2.3); -1 if none
	allocator:    runtime.Allocator, // what id and data are allocated with
}

Frame_Status_Flag :: enum u8 {
	Discard_On_Tag_Alter,
	Discard_On_File_Alter,
	Read_Only,
}
Frame_Status :: bit_set[Frame_Status_Flag; u8]

Frame_Format_Flag :: enum u8 {
	Grouping,
	Compression,
	Encryption,
	Unsynchronisation, // ID3v2.4
	Data_Length_Indicator, // ID3v2.4
}
Frame_Format :: bit_set[Frame_Format_Flag; u8]

Frame_Problem :: enum u8 {
	None,
	Too_Short, // shorter than the bytes its format flags add: data holds the bytes as stored
	Encrypted, // data holds the bytes as stored
	Bad_Compression, // data holds the bytes as stored
	Bad_Data_Length,
	Skipped_Picture, // read with skip_picture_data: data is nil
	Bad_Unsynchronisation, // said to be unsynchronised but cannot be: data holds the bytes as stored
	Nested_Chapter, // a CHAP or CTOC inside another: kept, not decoded
}

// Copies id and data.
make_frame :: proc(id: string, data: []u8, allocator := context.allocator) -> (frame: Frame, err: Error)
// The tag takes ownership of frame.
add_frame :: proc(tag: ^Tag, frame: Frame) -> Error
remove_frame :: proc(tag: ^Tag, index: int)
find_frame :: proc(tag: ^Tag, id: string, start := 0) -> (index: int, ok: bool)
```

`Frame_Status` and `Frame_Format` name the same flags in every version; the bit layout of each version is the library's business, and `stored_flags` keeps the bytes as read for the raw frame view. The sizes are in the units of the tag's version: syncsafe in ID3v2.4, plain in ID3v2.3, 24 bits in ID3v2.2.

## Frame contents

```odin
Frame_Content :: union {
	Text, // T*** except TXXX
	User_Text, // TXXX, TXX
	Url, // W*** except WXXX
	User_Url, // WXXX, WXX
	Comment, // COMM, COM, USLT, ULT
	Picture, // APIC, PIC
	Unique_File_Id, // UFID, UFI
	Popularimeter, // POPM, POP
	Play_Counter, // PCNT, CNT
	Private, // PRIV
	Chapter, // CHAP
	Table_Of_Contents, // CTOC
	Binary, // anything else
}

Text :: struct {
	encoding: Encoding,
	values:   []string, // several only in ID3v2.4, where NUL separates them
}

Comment :: struct {
	encoding:    Encoding,
	language:    [3]u8,
	description: string,
	text:        string,
}

Picture :: struct {
	encoding:    Encoding,
	mime:        string, // ID3v2.2's "JPG" and "PNG" read as "image/jpeg" and "image/png"
	type:        Picture_Type,
	description: string,
	data:        []u8,
}

Picture_Type :: enum u8 {
	Other,
	File_Icon,
	Other_File_Icon,
	Front_Cover,
	Back_Cover,
	Leaflet,
	Media,
	Lead_Artist,
	Artist,
	Conductor,
	Band,
	Composer,
	Lyricist,
	Recording_Location,
	During_Recording,
	During_Performance,
	Screen_Capture,
	Bright_Coloured_Fish,
	Illustration,
	Band_Logo,
	Publisher_Logo,
}

Chapter :: struct {
	element_id:   string,
	start_ms:     u32,
	end_ms:       u32,
	start_offset: u32, // 0xFFFFFFFF when unused
	end_offset:   u32,
	frames:       [dynamic]Frame, // the embedded frames, with offset -1
	warnings:     Warnings, // what reading them found wrong
}

Table_Of_Contents :: struct {
	element_id: string,
	top_level:  bool,
	ordered:    bool,
	children:   []string, // element IDs
	frames:     [dynamic]Frame, // the embedded frames, with offset -1
	warnings:   Warnings,
}

// User_Text, Url, User_Url, Unique_File_Id, Popularimeter, Play_Counter, Private and Binary
// follow their frame's layout in the spec.

// Everything in content is allocated with allocator. Free with destroy.
decode_frame :: proc(frame: ^Frame, version: V2_Version, allocator := context.allocator) -> (content: Frame_Content, err: Error)
encode_frame :: proc(content: Frame_Content, id: string, version: V2_Version, allocator := context.allocator) -> (frame: Frame, err: Error)

// Re-encodes the text of a frame, or of every text frame of a tag.
set_encoding :: proc{set_frame_encoding, set_tag_encoding}
```

## Typed accessors

```odin
Field :: enum u8 {
	Title, // TIT2, TT2
	Artist, // TPE1, TP1
	Album_Artist, // TPE2, TP2
	Album, // TALB, TAL
	Date, // TDRC; TYER, TDAT, TIME; TYE, TDA, TIM. "2019", "2019-05-03", "2019-05-03T10:20"
	Track, // TRCK, TRK, before the slash
	Track_Total, // after the slash
	Disc, // TPOS, TPA
	Disc_Total,
	Genre, // TCON, TCO, ID3v1 references resolved then their refinement, several joined with "; "
	Comment, // COMM with an empty description, else the first one that is not iTunes' own, else ffmpeg's TXXX "comment"
}
Fields :: bit_set[Field; u16]

// "" when absent. On Tags, falls back to ID3v1 for the fields it has. Allocation errors are
// optional results (#optional_allocator_error), so `title := get(&tags, .Title)` is fine.
get :: proc{get_tag_field, get_file_field}
// An empty value removes the field. The new frame takes the version's default encoding, an
// existing one keeps its own when it can hold the value.
set :: proc(tag: ^Tag, field: Field, value: string) -> Error

// On Tags, year and track fall back to ID3v1. They allocate nothing.
year :: proc{tag_year, file_year} // -> (year: int, ok: bool)
track :: proc{tag_track, file_track} // -> (number, total: int), 0 when absent
disc :: proc{tag_disc, file_disc}
set_track :: proc(tag: ^Tag, number, total: int) -> Error
set_disc :: proc(tag: ^Tag, number, total: int) -> Error
genres :: proc(tag: ^Tag, allocator := context.allocator) -> ([]string, runtime.Allocator_Error) #optional_allocator_error
set_genres :: proc(tag: ^Tag, genres: []string) -> Error

pictures :: proc(tag: ^Tag, allocator := context.allocator) -> ([]Picture, runtime.Allocator_Error) #optional_allocator_error
front_cover :: proc(tag: ^Tag, allocator := context.allocator) -> (picture: Picture, found: bool, err: runtime.Allocator_Error) // else the first picture
set_picture :: proc(tag: ^Tag, picture: Picture) -> Error // replaces the pictures of the same type
remove_pictures :: proc(tag: ^Tag, type: Maybe(Picture_Type) = nil)

user_text :: proc(tag: ^Tag, description: string, allocator := context.allocator) -> (value: string, found: bool, err: runtime.Allocator_Error)
set_user_text :: proc(tag: ^Tag, description, value: string) -> Error
comments :: proc(tag: ^Tag, allocator := context.allocator) -> ([]Comment, runtime.Allocator_Error) #optional_allocator_error
set_comment :: proc(tag: ^Tag, text: string, description := "", language := "eng") -> Error

// What the accessors return is freed with destroy and the same allocator: destroy_picture,
// destroy_pictures, destroy_comments, destroy_strings.

genre_name :: proc(index: u8) -> string // "" past the table
genre_index :: proc(name: string) -> (index: u8, ok: bool)
```

## ID3v1

```odin
// Text is UTF-8 in the model, Latin-1 in the file.
V1_Tag :: struct {
	version:   V1_Version,
	title:     string, // 30 characters, 90 with the Enhanced TAG
	artist:    string, // the same
	album:     string, // the same
	year:      string, // 4 characters
	comment:   string, // 30 characters, 28 in ID3v1.1
	track:     u8, // ID3v1.1 only, 0 when absent
	genre:     u8, // 255 when absent
	enhanced:  Maybe(V1_Enhanced),
	allocator: runtime.Allocator,
}

V1_Enhanced :: struct {
	speed:      u8, // 0 unset, 1 slow, 2 medium, 3 fast, 4 hardcore
	genre:      string, // 30 characters, free text
	start_time: string, // "mmm:ss"
	end_time:   string,
}

V1_Policy :: enum u8 {
	Keep, // rewrite ID3v1 where the file has one, never add one
	Always,
	Never,
}

// Rebuilds tags.v1 from the file's fields (ID3v2, else ID3v1) following the policy, and returns
// the fields that do not fit. A nil version means ID3v1.1 when the track is a number from 1 to 255,
// else ID3v1.0; a nil enhanced keeps the Enhanced TAG when the file has one.
sync_v1 :: proc(tags: ^Tags, policy: V1_Policy, version: Maybe(V1_Version) = nil, enhanced: Maybe(bool) = nil) -> (Fields, runtime.Allocator_Error) #optional_allocator_error
v1_from_tag :: proc(tag: ^Tag, version: V1_Version, enhanced := false, allocator := context.allocator) -> (v1: V1_Tag, overflow: Fields, err: runtime.Allocator_Error)
```

## Converting between versions

```odin
// Converts the tag in place. From .None, only sets the version; to .None, drops every frame.
// The frames that the target version cannot hold are removed and returned.
convert :: proc(tag: ^Tag, to: V2_Version, allocator := context.allocator) -> (dropped: Dropped_Frames, err: Error)

Dropped_Frames :: [dynamic]Dropped_Frame
Dropped_Frame :: struct {
	id:     string,
	reason: Drop_Reason,
}
Drop_Reason :: enum u8 {
	No_Equivalent, // RVA2 in ID3v2.3, CHAP in ID3v2.2...
	Encrypted, // cannot be converted without its key
	Discard_On_Tag_Alter, // an unknown frame that asks to be dropped when its tag changes
}

// A deep copy, to preview a conversion without touching the original.
clone :: proc{clone_tag, clone_tags}
```

## Writing

```odin
Write_Options :: struct {
	padding:           Maybe(int), // bytes of zeros after the frames; nil means DEFAULT_PADDING
	footer:            bool, // ID3v2.4 only; the spec forbids padding with a footer
	unsynchronisation: bool, // the whole tag
	compression:       bool, // every frame, on top of frames whose format asks for it
	replace_damaged:   bool, // allow rewriting a tag read with damage warnings
}

DEFAULT_PADDING :: 1024

// The bytes of the ID3v2 tag alone.
render :: proc(tag: ^Tag, options := Write_Options{}, allocator := context.allocator) -> (bytes: []u8, err: Error)
// 128 bytes, or 355 with the Enhanced TAG, which comes first.
render_v1 :: proc(v1: ^V1_Tag, allocator := context.allocator) -> ([]u8, runtime.Allocator_Error) #optional_allocator_error

// The whole file rebuilt in memory: the new tags around the kept bytes of file.
write_bytes :: proc(file: []u8, tags: ^Tags, options := Write_Options{}, allocator := context.allocator) -> (out: []u8, err: Error)
// Locates the tags of the file as it is now, writes the new file next to it, then renames it
// over the original. On any error the original is untouched.
write_file :: proc(path: string, tags: ^Tags, options := Write_Options{}, allocator := context.allocator) -> Error
```

A tag is written in its own version (`tags.v2.version`), and ID3v1 in `tags.v1.version`: `.None` removes them. The version of each frame's flags and sizes follows the tag.

## Errors and freeing

```odin
Error :: union #shared_nil {
	Format_Error,
	os.Error, // opening, reading, writing or renaming a file
	runtime.Allocator_Error,
}

Format_Error :: enum u8 {
	None,
	No_Version, // rendering a tag whose version is .None
	Tag_Too_Large, // over 256 MB, the largest syncsafe size, or a frame over its version's limit
	Bad_Frame_Id, // not 3 (ID3v2.2) or 4 (ID3v2.3, 2.4) characters from A to Z and 0 to 9
	Encoding_Not_In_Version, // UTF-16BE or UTF-8 below ID3v2.4
	Not_Encodable, // Latin-1 cannot hold the text
	Not_In_Version, // a frame flag or a write option the version does not have
	Not_Decodable, // decode_frame on an encrypted, damaged or skipped frame
	Bad_Content, // frame bytes that do not follow the frame's layout
	Damaged_Tag, // writing over a damaged tag without replace_damaged
	Incomplete_Tag, // writing tags read with skip_picture_data
}

destroy :: proc{destroy_tags, destroy_tag, destroy_v1, destroy_frame, destroy_content, destroy_dropped}
```
