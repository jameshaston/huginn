package main

import "core:log"
import "core:net"

import http "../external/odin-http"
import metrics "../metrics"

/*
Single place to change the server binding.
Default: IP4_Any (0.0.0.0) -- network-accessible.
For localhost-only, change to net.IP4_Loopback.
For a different port, change the port number.
*/
BIND_ENDPOINT :: net.Endpoint {
	address = net.IP4_Any,
	port    = 8080,
}

main :: proc() {
	context.logger = log.create_console_logger(
		.Info,
		log.Options{.Level, .Time, .Short_File_Path, .Line, .Terminal_Color, .Thread_Id},
	)

	s: http.Server
	http.server_shutdown_on_interrupt(&s)

	router: http.Router
	http.router_init(&router)
	defer http.router_destroy(&router)

	http.route_get(&router, "/api/host", http.handler(handle_host))
	http.route_get(&router, "/api/metrics", http.handler(handle_metrics))
	http.route_get(&router, "/api/processes", http.handler(handle_processes))
	http.route_get(&router, "/", http.handler(handle_dashboard))
	http.route_get(&router, "/dashboard.css", http.handler(handle_dashboard_css))
	http.route_get(&router, "/dashboard.js", http.handler(handle_dashboard_js))
	http.route_get(&router, "/logos/logo.svg", http.handler(handle_logo_svg))

	handler := http.router_handler(&router)

	log.infof("Listening on http://%s:%d", "0.0.0.0", BIND_ENDPOINT.port)
	err := http.listen_and_serve(&s, handler, BIND_ENDPOINT)
	log.infof("Server stopped: %s", err)
}

handle_host :: proc(req: ^http.Request, res: ^http.Response) {
	host, ok := metrics.host_snapshot()
	if !ok {
		log.error("host_snapshot failed")
		http.respond(res, http.Status.Internal_Server_Error)
		return
	}

	if err := http.respond_json(res, host); err != nil {
		log.errorf("could not respond with JSON: %s", err)
	}
}

handle_dashboard :: proc(req: ^http.Request, res: ^http.Response) {
	http.respond_file_content(res, "dashboard.html", #load("../static/dashboard.html"))
}

handle_dashboard_css :: proc(req: ^http.Request, res: ^http.Response) {
	http.respond_file_content(res, "dashboard.css", #load("../static/dashboard.css"))
}

handle_dashboard_js :: proc(req: ^http.Request, res: ^http.Response) {
	http.respond_file_content(res, "dashboard.js", #load("../static/dashboard.js"))
}

handle_logo_svg :: proc(req: ^http.Request, res: ^http.Response) {
	http.respond_file_content(res, "logo.svg", #load("../static/logos/logo.svg"))
}

handle_metrics :: proc(req: ^http.Request, res: ^http.Response) {
	cpu_raw, cpu_ok := metrics.cpu_snapshot()
	if !cpu_ok { log.error("cpu_snapshot failed") }

	mem_raw, mem_ok := metrics.memory_snapshot()
	if !mem_ok { log.error("memory_snapshot failed") }

	disk_raw, disk_ok := metrics.disk_snapshot()
	if !disk_ok { log.error("disk_snapshot failed") }

	net_raw, net_ok := metrics.network_snapshot()
	if !net_ok { log.error("network_snapshot failed") }

	cpu_display := CPU_Stats_Display {
		name            = cpu_raw.name,
		physical        = cpu_raw.physical,
		logical         = cpu_raw.logical,
		used_percentage = round_to(
			cpu_raw.user_percent +
			cpu_raw.nice_percent +
			cpu_raw.system_percent +
			cpu_raw.iowait_percent +
			cpu_raw.irq_percent +
			cpu_raw.softirq_percent +
			cpu_raw.steal_percent,
		),
	}

	mem_display := Memory_Stats_Display {
		total           = round_to(bytes_to_gib(mem_raw.total)),
		available       = round_to(bytes_to_gib(mem_raw.available)),
		used            = round_to(bytes_to_gib(mem_raw.used)),
		swap_total      = round_to(bytes_to_gib(mem_raw.swap_total)),
		swap_free       = round_to(bytes_to_gib(mem_raw.swap_free)),
		used_percentage = round_to(mem_raw.used_percentage),
	}

	disk_display := Disk_Stats_Display {
		mount_point     = disk_raw.mount_point,
		total           = round_to(bytes_to_gib(disk_raw.total)),
		available       = round_to(bytes_to_gib(disk_raw.available)),
		used            = round_to(bytes_to_gib(disk_raw.used)),
		used_percentage = round_to(disk_raw.used_percentage),
	}

	net_display: []Network_Stats_Display
	if net_ok {
		net_display = make([]Network_Stats_Display, len(net_raw), allocator = context.temp_allocator)
		for iface, i in net_raw {
			net_display[i] = Network_Stats_Display {
				name                = iface.name,
				bytes_in_per_sec    = round_to(bytes_to_kib(iface.bytes_in_per_sec)),
				bytes_out_per_sec   = round_to(bytes_to_kib(iface.bytes_out_per_sec)),
				packets_in_per_sec  = iface.packets_in_per_sec,
				packets_out_per_sec = iface.packets_out_per_sec,
			}
		}
	}

	snapshot := Metrics_Snapshot_Display {
		cpu     = cpu_display,
		memory  = mem_display,
		disk    = disk_display,
		network = net_display,
	}

	if err := http.respond_json(res, snapshot); err != nil {
		log.errorf("could not respond with JSON: %s", err)
	}
}

handle_processes :: proc(req: ^http.Request, res: ^http.Response) {
	sort_by := metrics.Sort_By.Cpu

	if sort_str, ok := http.query_get(req.url, "sort"); ok {
		switch sort_str {
		case "mem":
			sort_by = .Mem
		case "cpu":
			sort_by = .Cpu
		case:
			log.infof("unknown sort value %q, defaulting to cpu", sort_str)
		}
	}

	procs_raw, procs_ok := metrics.process_snapshot(sort_by = sort_by)
	if !procs_ok { log.error("process_snapshot failed") }

	displays := make([]Process_Snapshot_Display, len(procs_raw), allocator = context.temp_allocator)
	for p, i in procs_raw {
		displays[i] = Process_Snapshot_Display {
			pid          = p.pid,
			name         = p.name,
			cpu_percent  = round_to(p.cpu_percent),
			mem_phys     = round_to(bytes_to_mib(p.mem_phys)),
			mem_rss      = round_to(bytes_to_mib(p.mem_rss)),
			thread_count = p.thread_count,
			ppid         = p.ppid,
			username     = p.username,
		}
	}

	if err := http.respond_json(res, displays); err != nil {
		log.errorf("could not respond with JSON: %s", err)
	}
}
