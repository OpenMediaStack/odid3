package odid3

import "core:os"
import "core:time"

// Windows keeps no owner a program can copy, and flushes a rename with the file.
@(private)
keep_owner :: proc(original, temp: ^os.File) {}

@(private)
sync_directory :: proc(dir: string) {}

// An antivirus or the indexer may hold a file that was just written for a moment, during which
// Windows refuses to delete it.
@(private)
remove_file :: proc(path: string) {
	for _ in 0 ..< 50 {
		if os.remove(path) == nil {
			return
		}
		time.sleep(20 * time.Millisecond)
	}
}
