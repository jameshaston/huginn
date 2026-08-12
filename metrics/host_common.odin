#+build darwin, linux
#+private
package metrics

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import si "core:sys/info"

_host_info: Host_Info
_host_info_cached: bool
_host_once: sync.Once

/*
Populate _host_info with host OS version information.
*/
_init_host :: proc "contextless" () {
	context = runtime.default_context()

	osv, ok := si.os_version(context.allocator)
	if !ok {
		return
	}
	defer si.destroy_os_version(osv, context.allocator)

	release_clone, err := strings.clone(osv.release, context.allocator)
	if err != nil {
		return
	}

	_host_info = Host_Info {
		os_name    = _os_name(osv),
		os_version = fmt.aprintf("%d.%d.%d", osv.os.major, osv.os.minor, osv.os.patch),
		release    = release_clone,
		kernel     = fmt.aprintf("%d.%d.%d", osv.kernel.major, osv.kernel.minor, osv.kernel.patch),
	}
	_host_info_cached = true
}

/*
Return the cached host OS version information.

On the first call, triggers _init_host via sync.Once to
populate _host_info. Subsequent calls return the cache with a
lock-free atomic-load fast path (no mutex acquisition).

Zero allocation per call after the first init.

Returns:
- host: The cached Host_Info struct
- ok: true when host info was successfully cached at init
*/
_host_snapshot :: proc() -> (host: Host_Info, ok: bool) {
	sync.once_do_without_data_contextless(&_host_once, _init_host)
	return _host_info, _host_info_cached
}
