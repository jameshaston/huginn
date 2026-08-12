#+build darwin, linux
#+private
package metrics

import "core:sys/posix"

/*
Disk usage for a single mount point.

Uses POSIX statvfs to retrieve filesystem statistics for the root
mount point "/". Works on both macOS and Linux.

Returns:
- disk: A Disk_Stats struct with populated fields
- ok: true when statvfs succeeded
*/
_disk_snapshot :: proc() -> (disk: Disk_Stats, ok: bool) {
	sv: posix.statvfs_t
	if posix.statvfs("/", &sv) != .OK {
		return {}, false
	}

	total := i64(sv.f_blocks) * i64(sv.f_frsize)
	available := i64(sv.f_bavail) * i64(sv.f_frsize)
	used := total - available

	used_pct := f64(0)
	if total > 0 {
		used_pct = f64(used) / f64(total) * 100.0
	}

	return Disk_Stats {
			mount_point = "/",
			total = total,
			available = available,
			used = used,
			used_percentage = used_pct,
		},
		true
}
