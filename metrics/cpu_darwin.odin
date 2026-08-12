#+build darwin
#+private
package metrics

import "core:sync"
import "core:sys/unix"

/*
Mach kernel CPU statistics.
*/
_HOST_CPU_LOAD_INFO :: 3
_CPU_STATE_MAX :: 4
_CPU_STATE_USER :: 0
_CPU_STATE_SYSTEM :: 1
_CPU_STATE_IDLE :: 2
_CPU_STATE_NICE :: 3

/*
Contains aggregate CPU tick counts across all CPUs.
*/
_host_cpu_load_info :: struct {
	cpu_ticks: [_CPU_STATE_MAX]u32,
}

_prev_cpu_load: _host_cpu_load_info
_prev_cpu_valid: bool

/*
Mutex guarding the CPU delta state: _prev_cpu_load and
_prev_cpu_valid.
*/
_cpu_mutex: sync.Mutex

/*
Cached CPU identity fields.

The identity cache is init-once (write-once, then read-only).
sync.Once provides a lock-free atomic-load fast path after
the first init, so subsequent _cpu_snapshot calls do not
acquire _cpu_mutex just to check the identity cache.
*/
_cpu_name_buf: [256]u8
_cpu_name: string
_cpu_physical: int
_cpu_logical: int
_cpu_identity_once: sync.Once

/*
Populate CPU identity cache on first call.

Guarded by _cpu_identity_once (sync.Once). The fast path after
init is a lock-free atomic load - no mutex acquisition.
*/
_cpu_identity :: proc() {
	sync.once_do_without_data_contextless(&_cpu_identity_once, _cpu_identity_init)
}

/*
Initialize CPU identity cache via sysctlbyname.

Called exactly once by _cpu_identity via sync.Once.
 */
_cpu_identity_init :: proc "contextless" () {
	if unix.sysctlbyname("machdep.cpu.brand_string", &_cpu_name_buf) {
		_cpu_name = string(cstring(rawptr(&_cpu_name_buf)))
	} else {
		copy(_cpu_name_buf[:], "ARM64")
		_cpu_name = string(_cpu_name_buf[:len("ARM64")])
	}

	physical, logical: i64
	unix.sysctlbyname("hw.physicalcpu", &physical)
	unix.sysctlbyname("hw.logicalcpu", &logical)
	_cpu_physical = int(physical)
	_cpu_logical = int(logical)
}

/*
Retrieve CPU usage statistics over the last polling interval.

Uses Mach host_statistics with `HOST_CPU_LOAD_INFO` for cumulative
CPU tick counts. Computes interval percentages by taking deltas
between consecutive calls. First call returns 0 for all
percentages (no previous data to delta against).

CPU identity (name, core counts) is cached on the first call
via _cpu_identity (sync.Once-guarded, lock-free fast path after
init) and read from cache on subsequent calls.

The host_statistics call is outside the lock (read-only kernel
call). The identity cache init is outside the lock (sync.Once-
guarded). Only the delta computation and prev state update are
inside the lock to prevent concurrent races on _prev_cpu_load
and _prev_cpu_valid.

Returns:
- cpu: A CPU_Stats struct with interval-based percentages
- ok: true when CPU data was successfully retrieved
*/
_cpu_snapshot :: proc() -> (cpu: CPU_Stats, ok: bool) {
	host_port := _get_host_port()
	if host_port == 0 {
		return {}, false
	}

	cpu_load: _host_cpu_load_info
	count := u32(size_of(_host_cpu_load_info) / size_of(i32))
	ret := _host_statistics(host_port, _HOST_CPU_LOAD_INFO, &cpu_load, &count)

	if ret != .Success {
		return {}, false
	}

	_cpu_identity()

	used_pct := f64(0)
	user_pct := f64(0)
	nice_pct := f64(0)
	system_pct := f64(0)
	idle_pct := f64(0)

	sync.lock(&_cpu_mutex)

	if _prev_cpu_valid {
		// Guard against u32 counter wraparound or kernel reset.
		// If any current value is less than previous, treat as a reset:
		// store the new snapshot and return zeros for this interval.
		wrapped := false
		for i in 0 ..< _CPU_STATE_MAX {
			if cpu_load.cpu_ticks[i] < _prev_cpu_load.cpu_ticks[i] {
				wrapped = true
				break
			}
		}

		if !wrapped {
			d_user := u64(cpu_load.cpu_ticks[_CPU_STATE_USER] - _prev_cpu_load.cpu_ticks[_CPU_STATE_USER])
			d_system := u64(
				cpu_load.cpu_ticks[_CPU_STATE_SYSTEM] - _prev_cpu_load.cpu_ticks[_CPU_STATE_SYSTEM],
			)
			d_idle := u64(cpu_load.cpu_ticks[_CPU_STATE_IDLE] - _prev_cpu_load.cpu_ticks[_CPU_STATE_IDLE])
			d_nice := u64(cpu_load.cpu_ticks[_CPU_STATE_NICE] - _prev_cpu_load.cpu_ticks[_CPU_STATE_NICE])
			d_total := d_user + d_system + d_idle + d_nice

			if d_total > 0 {
				used_pct = f64(d_user + d_system + d_nice) / f64(d_total) * 100.0
				user_pct = f64(d_user) / f64(d_total) * 100.0
				nice_pct = f64(d_nice) / f64(d_total) * 100.0
				system_pct = f64(d_system) / f64(d_total) * 100.0
				idle_pct = f64(d_idle) / f64(d_total) * 100.0
			}
		}
	}

	_prev_cpu_load = cpu_load
	_prev_cpu_valid = true

	sync.unlock(&_cpu_mutex)

	return CPU_Stats {
			name = _cpu_name,
			physical = _cpu_physical,
			logical = _cpu_logical,
			used_percentage = used_pct,
			user_percent = user_pct,
			nice_percent = nice_pct,
			system_percent = system_pct,
			idle_percent = idle_pct,
			iowait_percent = 0.0,
			irq_percent = 0.0,
			softirq_percent = 0.0,
			steal_percent = 0.0,
		},
		true
}
