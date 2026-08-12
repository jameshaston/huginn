#+build darwin, linux
#+private
package metrics

import "core:os"
import "core:time"

/*
Compute elapsed seconds between two monotonic ticks.

Inputs:
- prev: The earlier tick (from a previous snapshot)
- now:  The later tick (from the current snapshot)

Returns:
- seconds: Elapsed time in seconds as f64, or 0 if now <= prev
*/
_delta_seconds :: proc(prev, now: time.Tick) -> f64 {
	return max(0.0, time.duration_seconds(time.tick_diff(prev, now)))
}

/*
Compute a per-second rate from two cumulative counters.

Inputs:
- current:    Cumulative counter value at the current snapshot
- previous:   Cumulative counter value at the previous snapshot
- delta_time: Elapsed time in seconds (from _delta_seconds)

Returns:
- rate: Per-second rate as i64, or 0 when delta_time <= 0
*/
_rate_per_sec :: proc(current, previous: u64, delta_time: f64) -> i64 {
	if delta_time <= 0 {
		return 0
	}
	return i64(f64(current - previous) / delta_time)
}

/*
Read an entire file into a []u8 using context.temp_allocator.

Returns:
- data: File contents, or nil on error
- ok:   true on success, false on error
*/
_read_file :: proc(path: string) -> ([]u8, bool) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return nil, false
	}
	return data, true
}
