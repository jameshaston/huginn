#+build darwin
#+private
package metrics

import "core:sync"
import darwin "core:sys/darwin"

/*
Mirrors the C mach_timebase_info struct from mach/mach_time.h.

`struct mach_timebase_info { uint32_t numer; uint32_t denom; };`

Used by the mach_timebase_info foreign proc and by process_darwin.odin
for converting Mach absolute time to nanoseconds.
*/
_mach_timebase_info_t :: struct {
	numer: u32,
	denom: u32,
}

foreign import system "system:System"

foreign system {
	/*
    Mach kernel IPC primitive for host statistics.

    mach_host_self returns the Mach port for the current host.
    Used by platform_darwin.odin (_get_host_port) to cache the host
    port for all darwin metric snapshots.
    */
	@(link_name = "mach_host_self")
	_mach_host_self :: proc() -> darwin.mach_port_t ---

	/*
    Mach timebase info for converting absolute time to nanoseconds from 
    mach/mach_time.h:
    `struct mach_timebase_info { uint32_t numer; uint32_t denom; };`
    `kern_return_t mach_timebase_info(mach_timebase_info_t info);`
    */
	@(link_name = "mach_timebase_info")
	_mach_timebase_info :: proc(info: ^_mach_timebase_info_t) -> darwin.Kern_Return ---

	/*
    Mach kernel IPC primitive for CPU statistics.

    host_statistics retrieves 32-bit kernel statistics
    (e.g. HOST_CPU_LOAD_INFO). Used by cpu_darwin.odin.
    */
	@(link_name = "host_statistics")
	_host_statistics :: proc(host: darwin.mach_port_t, flavor: i32, info: rawptr, count: ^u32) -> darwin.Kern_Return ---

	/*
    Mach kernel IPC primitive for memory statistics.

    host_statistics64 retrieves 64-bit kernel statistics
    (e.g. HOST_VM_INFO64). Used by memory_darwin.odin.
    */
	@(link_name = "host_statistics64")
	_host_statistics64 :: proc(host: darwin.mach_port_t, flavor: i32, info: rawptr, count: ^u32) -> darwin.Kern_Return ---

	/*
    Deallocates a Mach port send right.

    Used by _release_host_port for optional shutdown cleanup of the
    cached host port.

    mach/mach_port.h:
    `kern_return_t mach_port_deallocate(ipc_space_t task, mach_port_t name);`
    */
	@(link_name = "mach_port_deallocate")
	_mach_port_deallocate :: proc(task: darwin.task_t, name: u32) -> darwin.Kern_Return ---
}

/*
Cached Mach host port for all darwin metric snapshots.

The host port is a process-stable kernel resource: the kernel does not
change which host you are on. mach_host_self() is a Mach trap that
returns a fresh send right each call, so we acquire it once via
_init_host_port (guarded by _host_port_once) and reuse the cached port
for the process lifetime.
*/
_host_port: darwin.mach_port_t

/*
sync.Once guarding _host_port initialization.

The fast path (after first init) is a lock-free atomic load with
Acquire semantics. The slow path acquires the internal mutex, checks
done, runs _init_host_port, and sets done with Release semantics.
*/
_host_port_once: sync.Once

/*
Initialize _host_port via mach_host_self().
Called exactly once by _get_host_port via sync.Once.
*/
_init_host_port :: proc "contextless" () {
	_host_port = _mach_host_self()
}

/*
Return the cached Mach host port, initializing it on first call.

First call performs the mach_host_self() Mach trap and caches the
result. Subsequent calls return the cached port via a lock-free atomic
load (the sync.Once fast path).
*/
_get_host_port :: proc "contextless" () -> darwin.mach_port_t {
	sync.once_do_without_data_contextless(&_host_port_once, _init_host_port)
	return _host_port
}

/*
For optional shutdown cleanup. For a daemon that runs forever and
exits via signal, the kernel reclaims all port rights on process exit,
so calling this is not strictly required. It exists to signal intent
for trustworthy, resource-conscious code.
*/
_release_host_port :: proc "contextless" () {
	_mach_port_deallocate(darwin.mach_task_self(), u32(_host_port))
}

/*
Cached Mach timebase ratio for converting Mach absolute time to
nanoseconds.
*/
_timebase: _mach_timebase_info_t

/*
sync.Once guarding _timebase initialization.

The fast path (after first init) is a lock-free atomic load with
Acquire semantics. The slow path acquires the internal mutex, checks
done, runs _init_timebase, and sets done with Release semantics.
*/
_timebase_once: sync.Once

/*
Initialize _timebase via mach_timebase_info().

Called exactly once by _get_timebase via sync.Once. Marked
"contextless" to match the _init_host_port pattern: no context
dependency, safe to call from any thread.
*/
_init_timebase :: proc "contextless" () {
	_mach_timebase_info(&_timebase)
}

/*
Return the cached Mach timebase ratio, initializing it on first call.

First call performs the mach_timebase_info() Mach call and caches the
result. Subsequent calls return the cached ratio via a lock-free atomic
load (the sync.Once fast path). Used by process_darwin.odin for Mach
absolute time conversion.

Returns:
- numer, denom: The timebase ratio. 1 unit = numer/denom ns.
*/
_get_timebase :: proc "contextless" () -> (numer: u32, denom: u32) {
	sync.once_do_without_data_contextless(&_timebase_once, _init_timebase)
	return _timebase.numer, _timebase.denom
}
