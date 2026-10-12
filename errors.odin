package odid3

import "base:runtime"
import "core:os"

// What can stop a procedure of this package. A damaged tag is not an error: reading returns what
// it could read, with Warnings.
Error :: union #shared_nil {
	os.Error, // opening or reading a file
	runtime.Allocator_Error,
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
	// Another ID3v2 tag right after the first one. Writing replaces both with a single tag.
	Second_V2_Tag,
}

// Every warning reading raised.
Warnings :: bit_set[Warning;u16]
