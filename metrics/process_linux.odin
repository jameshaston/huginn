#+build linux
#+private
package metrics

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

_MAX_PROCS :: 1024
_MAX_PREV_PROCS :: 1024
_DIRENT_BUF_SIZE :: 8192

/*
Field indices in /proc/<pid>/stat after the last ')'.

The stat file format is: <pid> (<comm>) <state> <ppid> ...
After the last ')', fields are space-separated and 0-indexed
(field 3 in `man 5 proc_pid_stat` = index 0).
*/
_STAT_PPID :: 1
_STAT_UTIME :: 11
_STAT_STIME :: 12
_STAT_NUM_THREADS :: 17

/*
Previous snapshot state for a single process.

Used by the delta computation to store cumulative CPU time
(utime + stime in clock ticks) and the monotonic tick
from the previous _process_snapshot call. One entry per PID
is kept in the _prev_proc_data fixed array.
*/
_prev_proc_snapshot :: struct {
	pid:       i32,
	cpu_time:  u64,
	timestamp: time.Tick,
}

_prev_proc_count: int
_prev_proc_data: [_MAX_PREV_PROCS]_prev_proc_snapshot

/*
Mutex guarding the process delta state: _prev_proc_count and
_prev_proc_data.
*/
_proc_mutex: sync.Mutex

/*
Find previous snapshot for a given PID.
Returns nil if no previous snapshot exists for this PID.
*/
_find_prev_proc :: proc(pid: i32) -> ^_prev_proc_snapshot {
	for i in 0 ..< _prev_proc_count {
		if _prev_proc_data[i].pid == pid {
			return &_prev_proc_data[i]
		}
	}
	return nil
}

/*
Store or update a previous snapshot entry for a process.
*/
_store_prev_proc :: proc(pid: i32, cpu_time: u64, timestamp: time.Tick) {
	prev := _find_prev_proc(pid)
	if prev != nil {
		prev.cpu_time = cpu_time
		prev.timestamp = timestamp
	} else if _prev_proc_count < _MAX_PREV_PROCS {
		_prev_proc_data[_prev_proc_count] = _prev_proc_snapshot {
			pid       = pid,
			cpu_time  = cpu_time,
			timestamp = timestamp,
		}
		_prev_proc_count += 1
	}
}

/*
Evict dead processes from _prev_proc_data.

A PID is dead if it is not present in pid_buf, the complete set
of live PIDs from the current /proc/ listing. Dead entries are
reclaimed so their slots can be reused by new live PIDs.
*/
_sweep_dead_procs :: proc(pid_buf: []i32, pid_count: int) {
	i := 0
	for i < _prev_proc_count {
		pid := _prev_proc_data[i].pid
		alive := false
		for j in 0 ..< pid_count {
			if pid_buf[j] == pid {
				alive = true
				break
			}
		}
		if !alive {
			last := _prev_proc_count - 1
			if i != last {
				_prev_proc_data[i] = _prev_proc_data[last]
			}
			_prev_proc_count -= 1
		} else {
			i += 1
		}
	}
}

/*
Get the clock tick frequency via posix.sysconf.

Used to convert /proc/<pid>/stat tick counts to seconds for
CPU percentage computation.

Returns:
- clk_tck: Clock ticks per second as f64, fallback 100.0
*/
_get_clk_tck :: proc() -> f64 {
	clk := posix.sysconf(posix.SC._CLK_TCK)
	if clk <= 0 {
		return 100.0
	}
	return f64(clk)
}

/*
Retrieve top N processes sorted by the specified metric.

Two-phase collection, mirroring process_darwin.odin:

- Phase 1 (all PIDs): getdents + _read_file for /proc/<pid>/stat
- Phase 2 (top N only): statx + getpwuid

Inputs:
- count: Maximum number of processes to return
- sort_by: Sort metric (.Cpu or .Mem)

Returns:
- processes: Slice of Process_Snapshot with top N entries
- ok: true when process data was successfully retrieved
*/
_process_snapshot :: proc(count: int, sort_by: Sort_By) -> (processes: []Process_Snapshot, ok: bool) {
	// Phase 1: List PIDs from /proc/ via getdents
	dir_fd, open_errno := linux.open("/proc/", {})
	if open_errno != .NONE {
		return nil, false
	}
	defer linux.close(dir_fd)

	pid_buf: [_MAX_PROCS]i32
	pid_count := 0

	dirent_buf: [_DIRENT_BUF_SIZE]u8
	for {
		buflen, errno := linux.getdents(dir_fd, dirent_buf[:])
		if errno != .NONE || buflen == 0 {
			break
		}
		offset := 0
		for d in linux.dirent_iterate_buf(dirent_buf[:buflen], &offset) {
			name := linux.dirent_name(d)
			if pid, parse_ok := strconv.parse_int(name); parse_ok {
				if pid_count < _MAX_PROCS {
					pid_buf[pid_count] = i32(pid)
					pid_count += 1
				}
			}
		}
	}

	if pid_count == 0 {
		return nil, false
	}

	now := time.tick_now()
	clk_tck := _get_clk_tck()

	results, res_err := make([dynamic]Process_Snapshot, 0, 64, context.temp_allocator)
	if res_err != nil {
		return nil, false
	}

	for i in 0 ..< pid_count {
		pid := pid_buf[i]

		// Read /proc/<pid>/stat
		stat_path := fmt.tprintf("/proc/%d/stat", pid)
		stat_data, stat_ok := _read_file(stat_path)
		if !stat_ok {
			continue
		}
		stat_content := string(stat_data)

		// Find last ')' to skip past the comm field, which may
		// contain spaces and parentheses (e.g. "(chrome (helper))")
		last_paren := strings.last_index_byte(stat_content, ')')
		if last_paren < 0 {
			continue
		}

		// Extract process name from between first '(' and last ')'
		first_paren := strings.index_byte(stat_content, '(')
		proc_name := "unknown"
		if first_paren >= 0 && first_paren < last_paren {
			name_str := stat_content[first_paren + 1:last_paren]
			name_clone, _ := strings.clone(name_str, context.temp_allocator)
			proc_name = name_clone
		}

		// Parse fields after last ')' (space-separated, 0-indexed)
		fields_str := strings.trim_space(stat_content[last_paren + 2:])
		fields, _ := strings.split(fields_str, " ", context.temp_allocator)
		if len(fields) <= _STAT_NUM_THREADS {
			continue
		}

		utime, ut_ok := strconv.parse_i64(fields[_STAT_UTIME], 10)
		stime, st_ok := strconv.parse_i64(fields[_STAT_STIME], 10)
		ppid, ppid_ok := strconv.parse_int(fields[_STAT_PPID])
		nthreads, nt_ok := strconv.parse_int(fields[_STAT_NUM_THREADS])
		if !ut_ok || !st_ok || !ppid_ok || !nt_ok {
			continue
		}

		cpu_time := u64(utime) + u64(stime)

		// Read /proc/<pid>/statm for RSS (field 2, resident pages)
		statm_path := fmt.tprintf("/proc/%d/statm", pid)
		statm_data, statm_ok := _read_file(statm_path)
		if !statm_ok {
			continue
		}
		statm_content := string(statm_data)

		statm_fields, _ := strings.split(statm_content, " ", context.temp_allocator)
		if len(statm_fields) < 2 {
			continue
		}

		resident_pages, rss_ok := strconv.parse_i64(statm_fields[1], 10)
		if !rss_ok {
			continue
		}

		rss_bytes := i64(resident_pages) * i64(mem.PAGE_SIZE)

		// Compute CPU% via delta
		cpu_percent := f64(0)

		sync.lock(&_proc_mutex)

		prev := _find_prev_proc(pid)
		if prev != nil {
			delta_time := _delta_seconds(prev.timestamp, now)
			if delta_time > 0 {
				delta_ticks := f64(cpu_time - prev.cpu_time)
				cpu_percent = (delta_ticks / clk_tck) / delta_time * 100.0
				cpu_percent = max(0.0, cpu_percent)
			}
		}

		_store_prev_proc(pid, cpu_time, now)

		sync.unlock(&_proc_mutex)

		// mem_phys = mem_rss on Linux (no phys_footprint equivalent)
		_, append_err := append(
			&results,
			Process_Snapshot {
				pid = int(pid),
				name = proc_name,
				cpu_percent = cpu_percent,
				mem_phys = rss_bytes,
				mem_rss = rss_bytes,
				thread_count = nthreads,
				ppid = ppid,
			},
		)
		if append_err != nil {
			return nil, false
		}
	}

	// Evict dead processes from the prev state
	sync.lock(&_proc_mutex)
	_sweep_dead_procs(pid_buf[:], pid_count)
	sync.unlock(&_proc_mutex)

	if len(results) == 0 {
		return nil, false
	}

	// Sort by requested metric
	switch sort_by {
	case .Cpu:
		slice.sort_by(results[:], proc(a, b: Process_Snapshot) -> bool {
			return a.cpu_percent > b.cpu_percent
		})
	case .Mem:
		slice.sort_by(results[:], proc(a, b: Process_Snapshot) -> bool {
			return a.mem_rss > b.mem_rss
		})
	}

	// Phase 2: Enrich top N with username via statx + getpwuid
	top_count := min(count, len(results))

	for i in 0 ..< top_count {
		p := &results[i]

		// Open /proc/<pid> directory for statx with EMPTY_PATH
		proc_path := fmt.tprintf("/proc/%d", p.pid)
		proc_path_cstr, _ := strings.clone_to_cstring(proc_path, context.temp_allocator)
		proc_fd, proc_errno := linux.open(proc_path_cstr, {})
		if proc_errno != .NONE {
			p.username = "unknown"
			continue
		}

		// Get UID via statx with {.UID} mask and EMPTY_PATH flag
		statx_buf: linux.Statx
		statx_errno := linux.statx(proc_fd, "", {.EMPTY_PATH}, {.UID}, &statx_buf)
		linux.close(proc_fd)

		if statx_errno != .NONE {
			p.username = "unknown"
			continue
		}

		// Look up username via getpwuid, casting linux.Uid to posix.uid_t
		pw := posix.getpwuid(posix.uid_t(statx_buf.uid))
		if pw != nil {
			p.username, _ = strings.clone(string(pw.pw_name), context.temp_allocator)
		} else {
			p.username = "unknown"
		}
	}

	return results[:top_count], true
}
