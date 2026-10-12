/*
Package odid3 reads and writes the ID3 tags of MP3 files: ID3v1, ID3v1.1 and the Enhanced TAG,
ID3v2.2, ID3v2.3 and ID3v2.4.

Reading: read_file reads the head and the tail of a file, never the audio; read_bytes reads bytes in
memory. Both give Tags: the ID3v2 tag, ID3v1, where each part of the file is (Layout), and warnings.
A damaged file is not an error: the result holds what could be read, and the warnings say what was
wrong.

The model is exact: a Tag holds every frame as read, unknown ones included, with its flags and its
content bytes. get and set cover the common fields, decode_frame and encode_frame any frame's
content. Writing a tag writes the model as it is, so an untouched frame comes out byte for byte when
the version is unchanged. convert changes the version and returns the frames it drops.

Writing: write_file writes the new file next to the original, then renames it over it; the audio,
APE and Lyrics3 bytes are copied untouched, and on any error the original is left as it was.
write_bytes rebuilds a file in memory, render builds the bytes of an ID3v2 tag alone.

Ownership: every procedure that allocates takes an allocator and says how to free what it returns,
usually with destroy and the same allocator.

Threads: there is no global mutable state, so any number of threads can read and write different
values at once.
*/
package odid3
