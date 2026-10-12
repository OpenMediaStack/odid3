/*
Package odid3 reads and writes the ID3 tags of MP3 files: ID3v1, ID3v1.1 and the Enhanced TAG,
ID3v2.2, ID3v2.3 and ID3v2.4.

Reading: read_file reads the head and the tail of a file, never the audio; read_bytes reads bytes in
memory. Both give Tags: the ID3v2 tag, ID3v1, where each part of the file is (Layout), and warnings.
A damaged file is not an error: the result holds what could be read, and the warnings say what was
wrong.

The model is exact: a Tag holds every frame as read, unknown ones included, with its flags and its
content bytes. get and set cover the common fields, decode_frame and encode_frame any frame's
content. Writing a tag writes the model as it is, so an untouched frame keeps its bytes when the
version is unchanged (a compressed one its content, compressed again); the extended header and
ID3v2.4's SEEK are not written. convert changes the version and returns the frames it drops or
carries only in part. ID3v1 holds Latin-1 only: it is written from Tags.v1 on every write.

Writing: write_file writes the new file next to the original, then renames it over it; the audio,
APE and Lyrics3 bytes are copied untouched, and on any error the original is left as it was.
write_bytes rebuilds a file in memory, render builds the bytes of an ID3v2 tag alone.

Ownership: what a procedure returns is allocated with its allocator parameter and freed with the
same allocator: strings and byte slices with delete, the rest with destroy. The setters,
set_encoding, convert and sync_v1 change a tag in place with the tag's own allocator, the one it
was read or cloned with.

Threads: there is no global mutable state, so any number of threads can read and write different
values at once. A tag keeps using the allocator it was read with: clone it to hand it to a thread
that must not use that allocator.

odin doc prints each declaration with its doc comment, but not the comments on struct fields and
enum values (each Warning, Format_Error and Write_Options field): read those in the source, or
through OLS.
*/
package odid3
