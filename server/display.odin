package main

/*
Display-ready memory statistics for frontend consumption.

All byte values are converted to GiB as f64 and rounded to
DEFAULT_DISPLAY_DECIMALS. Percentages are rounded the same way.
*/
Memory_Stats_Display :: struct {
	total:           f64,
	available:       f64,
	used:            f64,
	swap_total:      f64,
	swap_free:       f64,
	used_percentage: f64,
}

/*
Display-ready disk statistics for frontend consumption.

All byte values are converted to GiB as f64 and rounded to
DEFAULT_DISPLAY_DECIMALS. Percentages are rounded the same way.
*/
Disk_Stats_Display :: struct {
	mount_point:     string,
	total:           f64,
	available:       f64,
	used:            f64,
	used_percentage: f64,
}

/*
Display-ready CPU statistics for frontend consumption.

Core counts are kept as int. used_percentage is the load shown
on the bar.
*/
CPU_Stats_Display :: struct {
	name:            string,
	physical:        int,
	logical:         int,
	used_percentage: f64,
}

/*
Display-ready network I/O statistics for a single interface.

Byte rates are converted to KiB/s as f64 and rounded to
DEFAULT_DISPLAY_DECIMALS. Packet rates are kept as i64.
*/
Network_Stats_Display :: struct {
	name:                string,
	bytes_in_per_sec:    f64,
	bytes_out_per_sec:   f64,
	packets_in_per_sec:  i64,
	packets_out_per_sec: i64,
}

/*
Display-ready per-process snapshot for the process listing.

Memory values are converted to MiB as f64 and rounded to
DEFAULT_DISPLAY_DECIMALS. CPU percentage is rounded the same way.
*/
Process_Snapshot_Display :: struct {
	pid:          int,
	name:         string,
	cpu_percent:  f64,
	mem_phys:     f64,
	mem_rss:      f64,
	thread_count: int,
	ppid:         int,
	username:     string,
}

/*
Display-ready bundle for GET /api/metrics.

Contains display versions of cpu, memory, disk, and network stats.
Host info has its own endpoint; processes have their own endpoint.
*/
Metrics_Snapshot_Display :: struct {
	cpu:     CPU_Stats_Display,
	memory:  Memory_Stats_Display,
	disk:    Disk_Stats_Display,
	network: []Network_Stats_Display,
}
