#+build linux
#+private
package metrics

import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

_MAX_IFACES :: 32
_IFACE_NAME_LEN :: 16 // IFNAMSIZ on Linux

/*
Previous snapshot state for a single network interface.

Used by the delta computation to store cumulative counter values
and the monotonic tick from the previous _network_snapshot
call. One entry per interface is kept in the _prev_iface_data
fixed array.
*/
_prev_iface_snapshot :: struct {
	name:        [_IFACE_NAME_LEN]u8,
	name_len:    int,
	bytes_in:    u64,
	bytes_out:   u64,
	packets_in:  u64,
	packets_out: u64,
	timestamp:   time.Tick,
}

_prev_iface_count: int
_prev_iface_data: [_MAX_IFACES]_prev_iface_snapshot

/*
Mutex guarding _prev_iface_count and _prev_iface_data.
Matches the sync.Mutex pattern used by network_darwin.odin.
*/
_net_mutex: sync.Mutex

/*
Compare an interface name against a prev snapshot entry.
Returns true if the name matches the snapshot's stored name.
*/
_iface_name_eq :: proc(name: string, snap: ^_prev_iface_snapshot) -> bool {
	if len(name) != snap.name_len {
		return false
	}
	for i in 0 ..< snap.name_len {
		if name[i] != snap.name[i] {
			return false
		}
	}
	return true
}

/*
Find previous snapshot for a given interface name.
Returns:
- snapshot: Pointer to the previous snapshot entry, or nil
*/
_find_prev_iface :: proc(name: string) -> ^_prev_iface_snapshot {
	for i in 0 ..< _prev_iface_count {
		if _iface_name_eq(name, &_prev_iface_data[i]) {
			return &_prev_iface_data[i]
		}
	}
	return nil
}

/*
Store or update a previous snapshot entry for an interface.
*/
_store_prev_iface :: proc(
	name: string,
	bytes_in, bytes_out, packets_in, packets_out: u64,
	timestamp: time.Tick,
) {
	prev := _find_prev_iface(name)
	if prev != nil {
		prev.bytes_in = bytes_in
		prev.bytes_out = bytes_out
		prev.packets_in = packets_in
		prev.packets_out = packets_out
		prev.timestamp = timestamp
	} else if _prev_iface_count < _MAX_IFACES {
		snap := &_prev_iface_data[_prev_iface_count]
		n := min(len(name), _IFACE_NAME_LEN)
		copy(snap.name[:n], name[:n])
		snap.name_len = n
		snap.bytes_in = bytes_in
		snap.bytes_out = bytes_out
		snap.packets_in = packets_in
		snap.packets_out = packets_out
		snap.timestamp = timestamp
		_prev_iface_count += 1
	}
}

/*
Evict dead interfaces from _prev_iface_data.
Inputs:
- live_names: The buffer of live interface name strings from the current poll
- live_count: The number of valid entries in live_names
*/
_sweep_dead_ifaces :: proc(live_names: []string, live_count: int) {
	i := 0
	for i < _prev_iface_count {
		snap := &_prev_iface_data[i]
		alive := false
		for j in 0 ..< live_count {
			if _iface_name_eq(live_names[j], snap) {
				alive = true
				break
			}
		}
		if !alive {
			last := _prev_iface_count - 1
			if i != last {
				_prev_iface_data[i] = _prev_iface_data[last]
			}
			_prev_iface_count -= 1
		} else {
			i += 1
		}
	}
}

/*
Retrieve network I/O statistics for all active interfaces.

Reads /proc/net/dev via _read_file and parses per-interface
cumulative byte and packet counters. Computes per-second rates
by taking deltas between consecutive calls. First call returns
zeros.

Returns:
- stats: Slice of Network_Stats with one entry per interface
- ok: true when network data was successfully retrieved
*/
_network_snapshot :: proc() -> (stats: []Network_Stats, ok: bool) {
	data, read_ok := _read_file("/proc/net/dev")
	if !read_ok {
		return nil, false
	}
	content := string(data)

	now := time.tick_now()

	results, res_err := make([dynamic]Network_Stats, 0, 16, context.temp_allocator)
	if res_err != nil {
		return nil, false
	}

	// Collect live interface names during iteration for the
	// post-loop eviction sweep. Sized to _MAX_IFACES to avoid
	// heap allocation; matches the prev state array capacity.
	live_names: [_MAX_IFACES]string
	live_count: int = 0

	line_idx := 0
	for line in strings.split_lines_iterator(&content) {
		line_idx += 1
		// Skip the two header lines
		if line_idx <= 2 {
			continue
		}

		// Split at the colon: "  eth0: 1234 5678 ..."
		colon_pos := strings.index_byte(line, ':')
		if colon_pos < 0 {
			continue
		}

		iface_name := strings.trim_space(line[:colon_pos])
		if len(iface_name) == 0 {
			continue
		}

		// Record this interface as live for the eviction sweep
		if live_count < _MAX_IFACES {
			live_names[live_count] = iface_name
			live_count += 1
		}

		// Parse the counter fields after the colon
		counters_str := strings.trim_space(line[colon_pos + 1:])
		field_idx := 0
		cur_bytes_in: u64
		cur_packets_in: u64
		cur_bytes_out: u64
		cur_packets_out: u64

		for field in strings.split_by_byte_iterator(&counters_str, ' ') {
			if len(field) == 0 {
				continue
			}
			val, parse_ok := strconv.parse_i64(field, 10)
			if !parse_ok {
				break
			}
			switch field_idx {
			case 0:
				// rx bytes
				cur_bytes_in = u64(val)
			case 1:
				// rx packets
				cur_packets_in = u64(val)
			case 8:
				// tx bytes
				cur_bytes_out = u64(val)
			case 9:
				// tx packets
				cur_packets_out = u64(val)
			case:
			}
			field_idx += 1
		}

		sync.lock(&_net_mutex)

		prev := _find_prev_iface(iface_name)
		prev_bytes_in: u64
		prev_bytes_out: u64
		prev_packets_in: u64
		prev_packets_out: u64
		delta_time: f64 = 0

		if prev != nil {
			prev_bytes_in = prev.bytes_in
			prev_bytes_out = prev.bytes_out
			prev_packets_in = prev.packets_in
			prev_packets_out = prev.packets_out
			delta_time = _delta_seconds(prev.timestamp, now)
		}

		_store_prev_iface(iface_name, cur_bytes_in, cur_bytes_out, cur_packets_in, cur_packets_out, now)

		sync.unlock(&_net_mutex)

		rate_in_bytes := _rate_per_sec(cur_bytes_in, prev_bytes_in, delta_time)
		rate_out_bytes := _rate_per_sec(cur_bytes_out, prev_bytes_out, delta_time)
		rate_in_pkts := _rate_per_sec(cur_packets_in, prev_packets_in, delta_time)
		rate_out_pkts := _rate_per_sec(cur_packets_out, prev_packets_out, delta_time)

		// Clone the interface name for the result slice
		name_clone, clone_err := strings.clone(iface_name, context.temp_allocator)
		if clone_err != nil {
			return nil, false
		}

		_, append_err := append(
			&results,
			Network_Stats {
				name = name_clone,
				bytes_in_per_sec = rate_in_bytes,
				bytes_out_per_sec = rate_out_bytes,
				packets_in_per_sec = rate_in_pkts,
				packets_out_per_sec = rate_out_pkts,
			},
		)
		if append_err != nil {
			return nil, false
		}
	}

	// Evict dead interfaces from the prev state. Any interface in
	// _prev_iface_data that is not in live_names has been removed
	// since the last poll (e.g. USB ethernet unplugged); reclaim its
	// slot so new interfaces can be stored without overflowing.
	sync.lock(&_net_mutex)
	_sweep_dead_ifaces(live_names[:], live_count)
	sync.unlock(&_net_mutex)

	if len(results) == 0 {
		delete(results)
		return nil, false
	}

	return results[:], true
}
