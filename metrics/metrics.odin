package metrics

/*
CPU identification and usage statistics.

Returned by cpu_snapshot. The name and core counts are read once at
initialization.

Percentages are interval averages computed from delta tick counts
between consecutive snapshots. All category fields sum to 100:
user + nice + system + idle + iowait + irq + softirq + steal = 100.

On macOS, iowait, irq, softirq, and steal are always 0.0 because the
Darwin Mach kernel does not expose those categories.
*/
CPU_Stats :: struct {
	name:            string,
	physical:        int,
	logical:         int,
	used_percentage: f64,
	user_percent:    f64,
	nice_percent:    f64,
	system_percent:  f64,
	idle_percent:    f64,
	iowait_percent:  f64,
	irq_percent:     f64,
	softirq_percent: f64,
	steal_percent:   f64,
}

/*
Operating system identification information.

Returned by host_snapshot. All values are read once from the OS kernel
and do not change between requests.
*/
Host_Info :: struct {
	os_name:    string,
	os_version: string,
	release:    string,
	kernel:     string,
}

/*
Memory statistics snapshot.

Returned by memory_snapshot. All byte values are in bytes. Percentage
is a point-in-time ratio and does not require delta computation.
*/
Memory_Stats :: struct {
	total:           i64,
	available:       i64,
	used:            i64,
	swap_total:      i64,
	swap_free:       i64,
	used_percentage: f64,
}

/*
Disk usage for a single mount point.

Returned by disk_snapshot. All byte values are in bytes. Percentage
is a point-in-time ratio.
*/
Disk_Stats :: struct {
	mount_point:     string,
	total:           i64,
	available:       i64,
	used:            i64,
	used_percentage: f64,
}

/*
Network I/O rates for a single interface.

Returned by network_snapshot. Values are deltas computed from
cumulative kernel counters between the last two calls, giving
per-second rates.
*/
Network_Stats :: struct {
	name:                string,
	bytes_in_per_sec:    i64,
	bytes_out_per_sec:   i64,
	packets_in_per_sec:  i64,
	packets_out_per_sec: i64,
}

/*
Sort metric for process listing.

- Cpu: Sort by CPU percentage (descending)
- Mem: Sort by physical memory footprint (descending)
*/
Sort_By :: enum {
	Cpu,
	Mem,
}

/*
Per-process snapshot for the process listing.

All fields are JSON-supported types (int, f64, string) that
serialize cleanly via core:encoding/json with no custom
marshaler.

*/
Process_Snapshot :: struct {
	pid:          int,
	name:         string,
	cpu_percent:  f64,
	mem_phys:     i64,
	mem_rss:      i64,
	thread_count: int,
	ppid:         int,
	username:     string,
}

/*
Response type for GET /api/metrics.

Contains cpu, memory, disk, and network structs. The network 
field is a slice of all active interfaces. The user selects 
which interface to display.
*/
Metrics_Snapshot :: struct {
	cpu:     CPU_Stats,
	memory:  Memory_Stats,
	disk:    Disk_Stats,
	network: []Network_Stats,
}

/*
Retrieve host OS version information.

Delegates to the platform-specific _host_snapshot() implementation.
Host info is cached on first call via sync.Once. Zero allocation
per call.
*/
host_snapshot :: proc() -> (host: Host_Info, ok: bool) {
	return _host_snapshot()
}

/*
Retrieve current memory statistics.

Delegates to the platform-specific _memory_snapshot() implementation.
On Linux, this calls si.ram_stats() directly. On Darwin, it
combines si.ram_stats() with Mach VM statistics.
*/
memory_snapshot :: proc() -> (mem: Memory_Stats, ok: bool) {
	return _memory_snapshot()
}

/*
Retrieve CPU identification and usage statistics. Delegates to the 
platform-specific _cpu_snapshot() implementation.
*/
cpu_snapshot :: proc() -> (cpu: CPU_Stats, ok: bool) {
	return _cpu_snapshot()
}

/*
Retrieve disk usage statistics. Delegates to the 
platform-specific _disk_snapshot() implementation.
*/
disk_snapshot :: proc() -> (disk: Disk_Stats, ok: bool) {
	return _disk_snapshot()
}

/*
Retrieve network I/O statistics for all active interfaces.

Delegates to the platform-specific _network_snapshot() implementation.
All allocations use context.temp_allocator. The odin-http library
resets the arena between requests.
*/
network_snapshot :: proc() -> (stats: []Network_Stats, ok: bool) {
	return _network_snapshot()
}

/*
Retrieve top N processes sorted by the specified metric.

Delegates to the platform-specific _process_snapshot()
implementation. All allocations use context.temp_allocator.
The odin-http library resets the arena between requests.
*/
process_snapshot :: proc(
	count: int = 60,
	sort_by: Sort_By = .Cpu,
) -> (
	processes: []Process_Snapshot,
	ok: bool,
) {
	return _process_snapshot(count, sort_by)
}
