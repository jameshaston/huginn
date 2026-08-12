#+build linux
#+private
package metrics

import si "core:sys/info"

/*
Retrieve current memory statistics.

Returns:
- mem: A Memory_Stats struct with all fields populated
- ok: true when RAM stats were successfully retrieved
*/
_memory_snapshot :: proc() -> (mem: Memory_Stats, ok: bool) {
	total, available, swap_total, swap_free, ram_ok := si.ram_stats()
	if !ram_ok {
		return {}, false
	}

	used := total - available

	used_percentage: f64
	if total > 0 {
		used_percentage = f64(used) / f64(total) * 100.0
	}

	return Memory_Stats {
			total = total,
			available = available,
			used = used,
			swap_total = swap_total,
			swap_free = swap_free,
			used_percentage = used_percentage,
		},
		true
}
