#+build linux
#+private
package metrics

import "core:strconv"
import "core:strings"
import "core:sync"

/*
CPU tick field indices from /proc/stat aggregate cpu line.
*/
_CPU_FIELD_USER :: 0
_CPU_FIELD_NICE :: 1
_CPU_FIELD_SYSTEM :: 2
_CPU_FIELD_IDLE :: 3
_CPU_FIELD_IOWAIT :: 4
_CPU_FIELD_IRQ :: 5
_CPU_FIELD_SOFTIRQ :: 6
_CPU_FIELD_STEAL :: 7
_CPU_FIELD_COUNT :: 8

/*
Previous CPU tick counts for delta computation.

Written under _cpu_mutex. _prev_cpu_valid is false on the
first call, causing all percentages to return 0.0.
*/
_prev_cpu_ticks: [_CPU_FIELD_COUNT]u64
_prev_cpu_valid: bool

/*
Mutex guarding the CPU delta state: _prev_cpu_ticks and
_prev_cpu_valid.
*/
_cpu_mutex: sync.Mutex

/*
Cached CPU identity fields.
*/
_cpu_name_buf: [256]u8
_cpu_name: string
_cpu_physical: int
_cpu_logical: int
_cpu_identity_once: sync.Once

/*
Populate CPU identity cache on first call.

Guarded by _cpu_identity_once (sync.Once). The fast path
after init is a lock-free atomic load - no mutex
acquisition.
*/
_cpu_identity :: proc() {
	sync.once_do_without_data(&_cpu_identity_once, _cpu_identity_init)
}

/*
Initialize CPU identity cache from /proc/cpuinfo.
Called exactly once by _cpu_identity via sync.Once.
*/
_cpu_identity_init :: proc() {
	data, ok := _read_file("/proc/cpuinfo")
	if !ok {
		return
	}
	content := string(data)

	processor_count := 0
	physical_ok := false
	logical_ok := false

	// Track seen physical_id -> cores pairs for multi-socket summing.
	seen_physical_ids: [32]int
	seen_cores: [32]int
	seen_count := 0

	current_physical_id := -1

	for line in strings.split_lines_iterator(&content) {
		key, _, value := strings.partition(line, ":")
		key = strings.trim_space(key)
		value = strings.trim_space(value)

		if len(key) == 0 {
			continue
		}

		switch key {
		case "model name":
			if len(_cpu_name) == 0 {
				n := min(len(value), len(_cpu_name_buf))
				copy(_cpu_name_buf[:n], value[:n])
				_cpu_name = string(_cpu_name_buf[:n])
			}
		case "Hardware":
			if len(_cpu_name) == 0 {
				n := min(len(value), len(_cpu_name_buf))
				copy(_cpu_name_buf[:n], value[:n])
				_cpu_name = string(_cpu_name_buf[:n])
			}
		case "physical id":
			current_physical_id, _ = strconv.parse_int(value)
		case "cpu cores":
			if current_physical_id >= 0 {
				cores, _ := strconv.parse_int(value)
				already_seen := false
				for i in 0 ..< seen_count {
					if seen_physical_ids[i] == current_physical_id {
						already_seen = true
						break
					}
				}
				if !already_seen && seen_count < len(seen_physical_ids) {
					seen_physical_ids[seen_count] = current_physical_id
					seen_cores[seen_count] = cores
					seen_count += 1
				}
			}
		case "siblings":
			if !logical_ok {
				_cpu_logical, logical_ok = strconv.parse_int(value)
			}
		case "processor":
			processor_count += 1
		case:
		// Ignore other /proc/cpuinfo keys
		}
	}

	// Sum physical cores across all sockets.
	if seen_count > 0 {
		total_physical := 0
		for i in 0 ..< seen_count {
			total_physical += seen_cores[i]
		}
		_cpu_physical = total_physical
		physical_ok = true
	}

	// ARM fallback: count "processor" lines for logical cores
	if !logical_ok && processor_count > 0 {
		_cpu_logical = processor_count
		logical_ok = true
	}

	// ARM fallback: if no "cpu cores" field, assume physical == logical
	if !physical_ok && logical_ok {
		_cpu_physical = _cpu_logical
		physical_ok = true
	}
}

/*
Retrieve CPU usage statistics over the last polling interval.

Reads /proc/stat via _read_file and parses the aggregate cpu
line for user, nice, system, idle, iowait, irq, softirq, and
steal tick counts. Computes interval percentages by taking
deltas between consecutive calls. First call returns 0 for
all percentages (no previous data to delta against).

CPU identity (name, core counts) is cached on the first call
via _cpu_identity (sync.Once-guarded, lock-free fast path
after init) and read from cache on subsequent calls.

The /proc/stat file read is outside the lock (read-only
kernel file). The identity cache init is outside the lock
(sync.Once-guarded). Only the delta computation and prev
state update are inside the lock to prevent concurrent races
on _prev_cpu_ticks and _prev_cpu_valid.

Returns:
- cpu: A CPU_Stats struct with interval-based percentages
- ok: true when CPU data was successfully retrieved
*/
_cpu_snapshot :: proc() -> (cpu: CPU_Stats, ok: bool) {
	data, read_ok := _read_file("/proc/stat")
	if !read_ok {
		return {}, false
	}
	content := string(data)

	// Parse the aggregate "cpu" line (first line of /proc/stat)
	ticks: [_CPU_FIELD_COUNT]u64
	parsed := false

	for line in strings.split_lines_iterator(&content) {
		// The aggregate line starts with "cpu " (not "cpu0", "cpu1", etc.)
		if len(line) < 4 || line[:3] != "cpu" || line[3] != ' ' {
			continue
		}

		// Split the rest of the line by whitespace and parse tick counts
		rest := strings.trim_space(line[4:])
		field_idx := 0
		for field in strings.split_iterator(&rest, " ") {
			if field_idx >= _CPU_FIELD_COUNT {
				break
			}
			if len(field) == 0 {
				continue
			}
			val, parse_ok := strconv.parse_i64(field, 10)
			if !parse_ok {
				break
			}
			ticks[field_idx] = u64(val)
			field_idx += 1
		}
		if field_idx == _CPU_FIELD_COUNT {
			parsed = true
		}
		break
	}

	if !parsed {
		return {}, false
	}

	_cpu_identity()

	used_pct := f64(0)
	user_pct := f64(0)
	nice_pct := f64(0)
	system_pct := f64(0)
	idle_pct := f64(0)
	iowait_pct := f64(0)
	irq_pct := f64(0)
	softirq_pct := f64(0)
	steal_pct := f64(0)

	sync.lock(&_cpu_mutex)

	if _prev_cpu_valid {
		// Guard against u64 counter wraparound or kernel reset.
		// If any current value is less than previous, treat as a reset:
		// store the new snapshot and return zeros for this interval.
		// This can happen in virtualized/cloud environments due to
		// container restarts, VM migration, or hypervisor counter resets.
		wrapped := false
		for i in 0 ..< _CPU_FIELD_COUNT {
			if ticks[i] < _prev_cpu_ticks[i] {
				wrapped = true
				break
			}
		}

		if !wrapped {
			d_user := ticks[_CPU_FIELD_USER] - _prev_cpu_ticks[_CPU_FIELD_USER]
			d_nice := ticks[_CPU_FIELD_NICE] - _prev_cpu_ticks[_CPU_FIELD_NICE]
			d_system := ticks[_CPU_FIELD_SYSTEM] - _prev_cpu_ticks[_CPU_FIELD_SYSTEM]
			d_idle := ticks[_CPU_FIELD_IDLE] - _prev_cpu_ticks[_CPU_FIELD_IDLE]
			d_iowait := ticks[_CPU_FIELD_IOWAIT] - _prev_cpu_ticks[_CPU_FIELD_IOWAIT]
			d_irq := ticks[_CPU_FIELD_IRQ] - _prev_cpu_ticks[_CPU_FIELD_IRQ]
			d_softirq := ticks[_CPU_FIELD_SOFTIRQ] - _prev_cpu_ticks[_CPU_FIELD_SOFTIRQ]
			d_steal := ticks[_CPU_FIELD_STEAL] - _prev_cpu_ticks[_CPU_FIELD_STEAL]

			d_used := d_user + d_nice + d_system + d_iowait + d_irq + d_softirq + d_steal
			d_total := d_used + d_idle

			if d_total > 0 {
				used_pct = f64(d_used) / f64(d_total) * 100.0
				user_pct = f64(d_user) / f64(d_total) * 100.0
				nice_pct = f64(d_nice) / f64(d_total) * 100.0
				system_pct = f64(d_system) / f64(d_total) * 100.0
				idle_pct = f64(d_idle) / f64(d_total) * 100.0
				iowait_pct = f64(d_iowait) / f64(d_total) * 100.0
				irq_pct = f64(d_irq) / f64(d_total) * 100.0
				softirq_pct = f64(d_softirq) / f64(d_total) * 100.0
				steal_pct = f64(d_steal) / f64(d_total) * 100.0
			}
		}
	}

	_prev_cpu_ticks = ticks
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
			iowait_percent = iowait_pct,
			irq_percent = irq_pct,
			softirq_percent = softirq_pct,
			steal_percent = steal_pct,
		},
		true
}
