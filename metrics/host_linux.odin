#+build linux
#+private
package metrics

import si "core:sys/info"

/*
Map an OS_Version struct to its OS display name on Linux.

Example:
	_os_name({platform = .Linux, ...}) -> "Linux"
*/
_os_name :: proc(osv: si.OS_Version) -> string {
	return _os_name_from_platform(osv.platform)
}

/*
Map an OS_Version_Platform enum value to its display name.

Example:
	_os_name_from_platform(.Linux) -> "Linux"
*/
_os_name_from_platform :: proc(platform: si.OS_Version_Platform) -> string {
	#partial switch platform {
	case .Linux:
		return "Linux"
	case:
		return "Unknown"
	}
}
