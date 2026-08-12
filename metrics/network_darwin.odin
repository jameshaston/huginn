#+build darwin
#+private
package metrics

import "core:strings"
import "core:sync"
import "core:sys/darwin"
import "core:sys/posix"
import "core:time"

_PF_ROUTE :: 17
_NET_RT_IFLIST2 :: 6
_RTM_IFINFO2 :: 0x12
_MAX_IFACES :: 32

/*
Previous snapshot state for a single network interface.

Used by the delta computation to store cumulative counter values
and the monotonic tick from the previous _network_snapshot
call. One entry per interface is kept in the _prev_iface_data
fixed array.

iface_index is the kernel's stable interface index (ifm_index),
used as the key instead of the name string. The name is looked
up via if_indextoname only during delta computation.
*/
_prev_iface_snapshot :: struct {
	iface_index: u16,
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
*/
_net_mutex: sync.Mutex

/*
Used by if_data64 to record the last-change timestamp for an
interface. Fields are 32-bit on Darwin.
*/
_timeval32 :: struct {
	tv_sec:  i32,
	tv_usec: i32,
}

/*
Mirrors the macOS if_data64 struct from net/if.h.

Contains per-interface cumulative counters for bytes, packets,
and errors since system boot. Used by if_msghdr2 to report
interface statistics via the routing socket.
*/
_if_data64 :: struct {
	ifi_type:       u8,
	ifi_typelen:    u8,
	ifi_physical:   u8,
	ifi_addrlen:    u8,
	ifi_hdrlen:     u8,
	ifi_recvquota:  u8,
	ifi_xmitquota:  u8,
	ifi_unused1:    u8,
	ifi_mtu:        u32,
	ifi_metric:     u32,
	ifi_baudrate:   u64,
	ifi_ipackets:   u64,
	ifi_ierrors:    u64,
	ifi_opackets:   u64,
	ifi_oerrors:    u64,
	ifi_collisions: u64,
	ifi_ibytes:     u64,
	ifi_obytes:     u64,
	ifi_imcasts:    u64,
	ifi_omcasts:    u64,
	ifi_iqdrops:    u64,
	ifi_noproto:    u64,
	ifi_recvtiming: u32,
	ifi_xmittiming: u32,
	ifi_lastchange: _timeval32,
}

/*
Mirrors the macOS if_msghdr2 struct from net/route.h.

Routing socket message header for interface information (type
RTM_IFINFO2). Contains the interface index and an embedded
if_data64 struct with cumulative I/O counters.
*/
_if_msghdr2 :: struct {
	ifm_msglen:     u16,
	ifm_version:    u8,
	ifm_type:       u8,
	ifm_addrs:      i32,
	ifm_flags:      i32,
	ifm_index:      u16,
	_pad:           u16,
	ifm_snd_len:    i32,
	ifm_snd_maxlen: i32,
	ifm_snd_drops:  i32,
	ifm_timer:      i32,
	ifm_data:       _if_data64,
}

/*
Find previous snapshot for a given interface index.
Returns:
- snapshot: Pointer to the previous snapshot entry, or nil
*/
_find_prev_iface :: proc(idx: u16) -> ^_prev_iface_snapshot {
	for i in 0 ..< _prev_iface_count {
		if _prev_iface_data[i].iface_index == idx {
			return &_prev_iface_data[i]
		}
	}
	return nil
}

/*
Store or update a previous snapshot entry for an interface.
*/
_store_prev_iface :: proc(
	idx: u16,
	bytes_in, bytes_out, packets_in, packets_out: u64,
	timestamp: time.Tick,
) {
	prev := _find_prev_iface(idx)
	if prev != nil {
		prev.bytes_in = bytes_in
		prev.bytes_out = bytes_out
		prev.packets_in = packets_in
		prev.packets_out = packets_out
		prev.timestamp = timestamp
	} else if _prev_iface_count < _MAX_IFACES {
		_prev_iface_data[_prev_iface_count] = _prev_iface_snapshot {
			iface_index = idx,
			bytes_in    = bytes_in,
			bytes_out   = bytes_out,
			packets_in  = packets_in,
			packets_out = packets_out,
			timestamp   = timestamp,
		}
		_prev_iface_count += 1
	}
}

/*
Evict dead interfaces from _prev_iface_data.

An interface is dead if it is not present in live_indices, the
complete set of interface indices discovered during the current
poll's sysctl iteration. Dead entries are reclaimed so their
slots can be reused by new interfaces, which prevents the fixed
array from filling with stale data and silently dropping new
interfaces.

Must be called with _net_mutex held. Uses swap-with-last for
O(1) per eviction, which reorders the array but does not affect
correctness since _find_prev_iface looks up by index value, not
by position. The swapped-in entry is re-checked in-place by not
advancing the index, so every element is evaluated exactly once.

Inputs:
- live_indices: The buffer of live interface indices from the current poll
- live_count:   The number of valid entries in live_indices
*/
_sweep_dead_ifaces :: proc(live_indices: []u16, live_count: int) {
	i := 0
	for i < _prev_iface_count {
		idx := _prev_iface_data[i].iface_index
		alive := false
		for j in 0 ..< live_count {
			if live_indices[j] == idx {
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

Uses sysctl with PF_ROUTE/NET_RT_IFLIST2 to query cumulative
kernel counters. Computes per-second rates by taking deltas
between consecutive calls. First call returns zeros.

Returns:
- stats: Dynamic array of Network_Stats with one entry per interface
- ok: true when network data was successfully retrieved
*/
_network_snapshot :: proc() -> (stats: []Network_Stats, ok: bool) {
	mib := [6]i32{4, i32(_PF_ROUTE), 0, 0, i32(_NET_RT_IFLIST2), 0}

	buf_len: uint = 0
	if darwin.syscall_sysctl(&mib[0], uint(len(mib)), nil, &buf_len, nil, 0) != 0 {
		return nil, false
	}
	if buf_len == 0 {
		return nil, false
	}

	buf, buf_err := make([]u8, int(buf_len), context.temp_allocator)
	if buf_err != nil {
		return nil, false
	}
	if darwin.syscall_sysctl(&mib[0], uint(len(mib)), raw_data(buf), &buf_len, nil, 0) != 0 {
		return nil, false
	}

	now := time.tick_now()

	results, res_err := make([dynamic]Network_Stats, 0, 16, context.temp_allocator)
	if res_err != nil {
		return nil, false
	}

	// Collect live interface indices during iteration for the
	// post-loop eviction sweep. Sized to _MAX_IFACES to avoid
	// heap allocation; matches the prev state array capacity.
	live_indices: [_MAX_IFACES]u16
	live_count: int = 0

	offset := 0
	for offset < int(buf_len) {
		msg := cast(^_if_msghdr2)&buf[offset]
		if msg.ifm_msglen == 0 {
			break
		}

		if msg.ifm_type == _RTM_IFINFO2 {
			name_buf: [posix.IF_NAMESIZE]u8
			name_cstr := posix.if_indextoname(u32(msg.ifm_index), &name_buf[0])
			if name_cstr != nil {
				name_clone, clone_err := strings.clone(string(name_cstr), context.temp_allocator)
				if clone_err != nil {
					return nil, false
				}

				if name_clone != "" {
					// Record this interface as live for the eviction sweep
					if live_count < _MAX_IFACES {
						live_indices[live_count] = msg.ifm_index
						live_count += 1
					}

					cur_ibytes := msg.ifm_data.ifi_ibytes
					cur_obytes := msg.ifm_data.ifi_obytes
					cur_ipkts := msg.ifm_data.ifi_ipackets
					cur_opkts := msg.ifm_data.ifi_opackets

					sync.lock(&_net_mutex)

					prev := _find_prev_iface(msg.ifm_index)
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

					_store_prev_iface(msg.ifm_index, cur_ibytes, cur_obytes, cur_ipkts, cur_opkts, now)

					sync.unlock(&_net_mutex)

					rate_in_bytes := _rate_per_sec(cur_ibytes, prev_bytes_in, delta_time)
					rate_out_bytes := _rate_per_sec(cur_obytes, prev_bytes_out, delta_time)
					rate_in_pkts := _rate_per_sec(cur_ipkts, prev_packets_in, delta_time)
					rate_out_pkts := _rate_per_sec(cur_opkts, prev_packets_out, delta_time)

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
			}
		}

		offset += int(msg.ifm_msglen)
	}

	// Evict dead interfaces from the prev state. Any interface in
	// _prev_iface_data that is not in live_indices has been removed
	// since the last poll (e.g. USB ethernet unplugged); reclaim its
	// slot so new interfaces can be stored without overflowing.
	sync.lock(&_net_mutex)
	_sweep_dead_ifaces(live_indices[:], live_count)
	sync.unlock(&_net_mutex)

	if len(results) == 0 {
		delete(results)
		return nil, false
	}

	return results[:], true
}
