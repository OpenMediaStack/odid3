package odid3

import "core:os"

// Windows keeps no owner a program can copy, and flushes a rename with the file.
@(private)
keep_owner :: proc(original, temp: ^os.File) {}

@(private)
sync_directory :: proc(dir: string) {}
