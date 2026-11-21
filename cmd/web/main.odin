package main

import "core:net"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:log"
import "core:strconv"
import http "../../odin-http"
import "../../internal/dotenv"

VERSION :: "1.0.0"

GIT_SHA :: #config(GIT_SHA, "dev")

Config :: struct {
	host:        string,
	port:        int,
	env:         string,
	csrf_secret: string,
	secret_key:  string,
	db:          struct {
		dsn: string,
	},
	tls:         struct {
		cert: string,
		key:  string,
	},
}

main :: proc() {

    when ODIN_DEBUG {
        track: mem.Tracking_Allocator;
        mem.tracking_allocator_init(&track, context.allocator);
        context.allocator = mem.tracking_allocator(&track);

        defer {
            if len(track.allocation_map) > 0 {
                fmt.eprintfln("=== %v allocations not freed: ===", len(track.allocation_map));
                for _, entry in track.allocation_map {
                    fmt.eprintfln("- %v bytes @ %v", entry.size, entry.location);
                }
            }
            mem.tracking_allocator_destroy(&track);
        }
    }

    context.logger = log.create_console_logger(lowest = .Debug when ODIN_DEBUG else .Info, opt = {.Level, .Terminal_Color, .Short_File_Path, .Line}, allocator = context.allocator);
	defer log.destroy_console_logger(context.logger, context.allocator);

    dotenv_line, dotenv_err := dotenv.load(".env", context.temp_allocator);
    free_all(context.temp_allocator);
    if dotenv_err != .None && dotenv_err != .Not_Found {
        log.fatalf("loading .env: %v (line %d)", dotenv_err, dotenv_line);
        os.exit(1);
    }

    cfg := Config{port = 8080};

	env_scratch: [64]u8;
	port_str, port_err := os.lookup_env(env_scratch[:], "APP_PORT");
	if port_err == .Buffer_Full {
		log.fatal("APP_PORT is longer than 64 bytes");
		os.exit(1);
	}
	if port_str != "" {
		port_num, port_ok := strconv.parse_uint(port_str, 10);
		if !port_ok || len(port_str) > 5 || port_num < 1 || port_num > 65535 {
			log.fatalf("invalid APP_PORT %q", port_str);
			os.exit(1);
		}
		cfg.port = int(port_num);
	}

    server: http.Server;
    http.server_shutdown_on_interrupt(&server);

    router: http.Router;
    http.router_init(&router);
    defer http.router_destroy(&router);

    routes(&router);

    endpoints := net.Endpoint {
        address = net.IP4_Loopback,
        port    = cfg.port,
    };

    listen_err := http.listen(&server, endpoints);
    if listen_err != nil {
        log.errorf("could not listen on port %d: %v", cfg.port, listen_err);
        os.exit(1);
    }

    log.infof("site %s (odin version %s) listening on 127.0.0.1:%d", GIT_SHA, ODIN_VERSION, cfg.port);

    middleware: Middleware;
    serve_err := http.serve(&server, middleware_init(&middleware, &router));
    if serve_err != nil {
        log.errorf("server stopped with an error: %v", serve_err);
        os.exit(1);
    }
}
