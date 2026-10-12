#+build !windows
package odid3

import "core:os"
import "core:sys/posix"

// Gives the new file the owner and group of the original, as far as the process may: any user can
// give a file a group they belong to, only root another owner.
@(private)
keep_owner :: proc(original, temp: ^os.File) {
	st: posix.stat_t
	if posix.fstat(posix.FD(os.fd(original)), &st) != .OK {
		return
	}
	if posix.fchown(posix.FD(os.fd(temp)), st.st_uid, st.st_gid) != .OK {
		posix.fchown(posix.FD(os.fd(temp)), ~posix.uid_t(0), st.st_gid)
	}
}

// A rename is only durable once the directory that holds it reaches the disk.
@(private)
sync_directory :: proc(dir: string) {
	f, err := os.open(dir)
	if err != nil {
		return
	}
	os.sync(f)
	os.close(f)
}
