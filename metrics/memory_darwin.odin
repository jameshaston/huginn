#+build darwin
#+private
package metrics

import darwin "core:sys/darwin"
import si "core:sys/info"

_HOST_VM_INFO64 :: 4

/*
Field types match the macOS Mach header (mach/vm_statistics.h):
natural_t fields are u32 (4 bytes), uint64_t fields are u64.
All count fields represent page counts, not bytes.
*/
_vm_statistics64 :: struct #align (8) {
	free_count:                             u32,
	active_count:                           u32,
	inactive_count:                         u32,
	wire_count:                             u32,
	zero_fill_count:                        u64,
	reactivations:                          u64,
	pageins:                                u64,
	pageouts:                               u64,
	faults:                                 u64,
	cow_faults:                             u64,
	lookups:                                u64,
	hits:                                   u64,
	purges:                                 u64,
	purgeable_count:                        u32,
	speculative_count:                      u32,
	decompressions:                         u64,
	compressions:                           u64,
	swapins:                                u64,
	swapouts:                               u64,
	compressor_page_count:                  u32,
	throttled_count:                        u32,
	external_page_count:                    u32,
	internal_page_count:                    u32,
	total_uncompressed_pages_in_compressor: u64,
	swapped_count:                          u64,
	total_tag_storage_pages:                u64,
	nontag_pageable_tag_storage_pages:      u64,
	nontag_wired_tag_storage_pages:         u64,
	free_tag_storage_pages:                 u64,
	tag_storing_tag_storage_pages:          u64,
	total_tagged_pages:                     u64,
	resident_tagged_pages:                  u64,
	compressed_tagged_pages:                u64,
	tagged_compressions:                    u64,
	tagged_decompressions:                  u64,
	compressed_tag_storage_bytes:           u64,
}

/*
Call the Mach host_statistics64 API with HOST_VM_INFO64 flavor.

Returns:
- stats: A _vm_statistics64 struct populated by the kernel
- ok: true when the Mach call returned Kern_Return.Success
*/
_fetch_vm_stats :: proc() -> (stats: _vm_statistics64, ok: bool) {
	host_port := _get_host_port()
	if host_port == 0 {
		return {}, false
	}
	count := u32(size_of(_vm_statistics64) / size_of(i32))
	ret := _host_statistics64(host_port, _HOST_VM_INFO64, &stats, &count)
	return stats, ret == .Success
}

/*
Convert a Mach page count to bytes using the system page size.

Each term is cast to u64 individually before addition to avoid
u32 overflow when summing multiple page counts.

Returns:
- bytes: Page count multiplied by darwin.vm_page_size, as i64
*/
_pages_to_bytes :: proc(pages: u64) -> i64 {
	return i64(pages) * i64(darwin.vm_page_size)
}

/*
Compute available memory from Mach VM statistics.

available = (free + inactive + speculative + purgeable) * page_size

Each field is cast to u64 before addition to prevent u32 overflow.
Purgeable pages are resident pages marked by applications as
reclaimable under memory pressure.

Returns:
- bytes: Available memory in bytes as i64
*/
_ram_available :: proc(stats: _vm_statistics64) -> i64 {
	free := u64(stats.free_count)
	inactive := u64(stats.inactive_count)
	speculative := u64(stats.speculative_count)
	purgeable := u64(stats.purgeable_count)
	return _pages_to_bytes(free + inactive + speculative + purgeable)
}

/*
Compute used memory as a percentage of total.

Returns 0 if total is 0 to avoid division by zero.

Returns:
- percentage: Used memory as a percentage (0.0 - 100.0)
*/
_ram_percentage_used :: proc(used, total: i64) -> f64 {
	if total == 0 {
		return 0
	}
	return f64(used) / f64(total) * 100.0
}

/*
Retrieve current memory statistics.

Calls si.ram_stats for total RAM and uses Mach host_statistics64
for available memory computation. si.ram_stats does not provide
swap on macOS, so swap_total and swap_free are 0.

Returns:
- mem: A Memory_Stats struct with all fields populated
- ok: true when both Mach VM stats and system RAM stats succeeded
*/
_memory_snapshot :: proc() -> (mem: Memory_Stats, ok: bool) {
	stats, vm_ok := _fetch_vm_stats()
	if !vm_ok {
		return {}, false
	}

	total, _, swap_tot, swap_free, ram_ok := si.ram_stats()
	if !ram_ok {
		return {}, false
	}

	avail := _ram_available(stats)
	used := total - avail

	return Memory_Stats {
			total = total,
			available = avail,
			used = used,
			swap_total = swap_tot,
			swap_free = swap_free,
			used_percentage = _ram_percentage_used(used, total),
		},
		true
}
