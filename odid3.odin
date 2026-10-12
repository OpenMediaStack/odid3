/*
Package odid3 reads and writes the ID3 tags of MP3 files: ID3v1, ID3v1.1 and the Enhanced TAG,
ID3v2.2, ID3v2.3 and ID3v2.4.

The package is under construction: see docs/api.md for the planned API.

Ownership: every procedure that allocates takes an allocator and says how to free what it returns.

Threads: there is no global mutable state, so any number of threads can read and write different
values at once.
*/
package odid3
