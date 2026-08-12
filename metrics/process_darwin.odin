#+build darwin
#+private
package metrics

import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/darwin"
import "core:sys/posix"
import "core:time"

_MAX_PROCS :: 1024
_MAX_PREV_PROCS :: 1024

/*
Previous snapshot state for a single process.

Used by the delta computation to store cumulative CPU time
and the monotonic tick from the previous
_process_snapshot call. One entry per PID is kept in the
_prev_proc_data fixed array.
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
of live PIDs returned by proc_listallpids for the current poll.
Dead entries are reclaimed so their slots can be reused by new
live PIDs, which prevents the fixed array from filling with
stale data and silently dropping new processes.

Must be called with _proc_mutex held. Uses swap-with-last for
O(1) per eviction, which reorders the array but does not affect
correctness since _find_prev_proc looks up by PID value, not
by position. The swapped-in entry is re-checked in-place by not
advancing the index, so every element is evaluated exactly once.

Inputs:
- pid_buf:   The buffer of live PIDs from proc_listallpids
- pid_count: The number of valid entries in pid_buf
*/
_sweep_dead_procs :: proc(pid_buf: []i32, pid_count: i32) {
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
Extract a string from a null-terminated byte array.

The pbi_comm field in proc_bsdinfo is [16]u8 with a null
terminator. This converts it to an Odin string, cloned via
context.temp_allocator.

Inputs:
- buf: A byte array with a null terminator

Returns:
- A string cloned via context.temp_allocator
*/
_comm_to_string :: proc(buf: ^[darwin.MAXCOMLEN]u8) -> string {
	for i in 0 ..< len(buf^) {
		if buf[i] == 0 {
			s, _ := strings.clone(string(buf[:i]), context.temp_allocator)
			return s
		}
	}
	s, _ := strings.clone(string(buf[:]), context.temp_allocator)
	return s
}

/*
Look up a username from a UID.

Uses posix.getpwuid to get the password entry, then returns
the pw_name field. Returns "unknown" if the lookup fails.

No allocation: the returned string is a view into the static
buffer used by getpwuid. The caller must clone it if it needs
to persist beyond the next getpwuid call.

Inputs:
- uid: The user ID to look up

Returns:
- The username as a string (view into static buffer, or "unknown")
*/
_uid_to_username :: proc(uid: posix.uid_t) -> string {
	pw := posix.getpwuid(uid)
	if pw == nil {
		return "unknown"
	}
	return string(pw.pw_name)
}

/*
Retrieve top N processes sorted by the specified metric.

Two-phase collection:
- Phase 1 (all PIDs): proc_listallpids + proc_pidinfo(.TASKALLINFO)
- Phase 2 (top N only): proc_pid_rusage(.V0) + getpwuid

Inputs:
- count: Maximum number of processes to return
- sort_by: Sort metric (.Cpu or .Mem)

Returns:
- processes: Slice of Process_Snapshot with top N entries
- ok: true when process data was successfully retrieved
*/
_process_snapshot :: proc(count: int, sort_by: Sort_By) -> (processes: []Process_Snapshot, ok: bool) {
	// Phase 1: Get all PIDs
	pid_buf: [_MAX_PROCS]i32
	pid_count := darwin.proc_listallpids(&pid_buf[0], i32(len(pid_buf) * size_of(i32)))
	if pid_count <= 0 {
		return nil, false
	}

	now := time.tick_now()

	results, res_err := make([dynamic]Process_Snapshot, 0, 64, context.temp_allocator)
	if res_err != nil {
		return nil, false
	}
	uid_buf, uid_err := make([dynamic]posix.uid_t, 0, 64, context.temp_allocator)
	if uid_err != nil {
		return nil, false
	}

	for i in 0 ..< pid_count {
		pid := pid_buf[i]

		info: darwin.proc_taskallinfo
		ret := darwin.proc_pidinfo(posix.pid_t(pid), .TASKALLINFO, 0, &info, size_of(info))
		if ret <= 0 {
			continue
		}

		cpu_time := info.ptinfo.pti_total_user + info.ptinfo.pti_total_system

		// Compute CPU% via delta
		cpu_percent := f64(0)

		sync.lock(&_proc_mutex)

		prev := _find_prev_proc(pid)
		if prev != nil {
			delta_time := _delta_seconds(prev.timestamp, now)
			if delta_time > 0 {
				delta_ticks := f64(cpu_time - prev.cpu_time)
				numer, denom := _get_timebase()
				delta_ns := delta_ticks * f64(numer) / f64(denom)
				cpu_percent = delta_ns / 1e9 / delta_time * 100.0
				cpu_percent = max(0.0, cpu_percent)
			}
		}

		// Store for next delta
		_store_prev_proc(pid, cpu_time, now)

		sync.unlock(&_proc_mutex)

		_, append_err := append(
			&results,
			Process_Snapshot {
				pid = int(pid),
				name = _comm_to_string(&info.pbsd.pbi_comm),
				cpu_percent = cpu_percent,
				mem_rss = i64(info.ptinfo.pti_resident_size),
				thread_count = int(info.ptinfo.pti_threadnum),
				ppid = int(info.pbsd.pbi_ppid),
			},
		)
		if append_err != nil {
			return nil, false
		}
		_, uid_append_err := append(&uid_buf, info.pbsd.pbi_uid)
		if uid_append_err != nil {
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
	_proc_entry :: struct {
		snap: Process_Snapshot,
		uid:  posix.uid_t,
	}
	entries, entries_err := make([dynamic]_proc_entry, 0, len(results), context.temp_allocator)
	if entries_err != nil {
		return nil, false
	}
	for i in 0 ..< len(results) {
		_, append_err := append(&entries, _proc_entry{snap = results[i], uid = uid_buf[i]})
		if append_err != nil {
			return nil, false
		}
	}

	switch sort_by {
	case .Cpu:
		slice.sort_by(entries[:], proc(a, b: _proc_entry) -> bool {
			return a.snap.cpu_percent > b.snap.cpu_percent
		})
	case .Mem:
		slice.sort_by(entries[:], proc(a, b: _proc_entry) -> bool {
			return a.snap.mem_rss > b.snap.mem_rss
		})
	}

	// Split the sorted combined array back into results and uid_buf.
	for i in 0 ..< len(entries) {
		results[i] = entries[i].snap
		uid_buf[i] = entries[i].uid
	}

	// Phase 2: Enrich top N with phys_footprint and username.
	top_count := min(count, len(results))

	for i in 0 ..< top_count {
		p := &results[i]

		// Get phys_footprint via proc_pid_rusage
		rusage: darwin.rusage_info_v0
		if darwin.proc_pid_rusage(posix.pid_t(p.pid), .V0, &rusage) == 0 {
			p.mem_phys = i64(rusage.ri_phys_footprint)
		}

		// Get username via getpwuid using the UID captured in Phase 1.
		uid_str := _uid_to_username(uid_buf[i])
		p.username, _ = strings.clone(uid_str, context.temp_allocator)
	}

	// Truncate to top N
	return results[:top_count], true
}
