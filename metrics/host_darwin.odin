#+build darwin
#+private
package metrics

import si "core:sys/info"

/*
Map an OS_Version struct to its OS marketing name on macOS.

Example:
	_os_name({os = {major = 15, ...}, ...}) -> "macOS Sequoia"
*/
_os_name :: proc(osv: si.OS_Version) -> string {
	return _os_name_from_major(osv.os.major)
}

/*
Map a macOS major version number to its marketing name.

Example:
	_os_name_from_major(15) -> "macOS Sequoia"
*/
_os_name_from_major :: proc(major: int) -> string {
	switch major {
	case 26:
		return "macOS Tahoe"
	case 15:
		return "macOS Sequoia"
	case 14:
		return "macOS Sonoma"
	case 13:
		return "macOS Ventura"
	case 12:
		return "macOS Monterey"
	case 11:
		return "macOS Big Sur"
	case:
		return "macOS Unknown"
	}
}
