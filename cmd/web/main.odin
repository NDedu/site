package main

import "core:net"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:log"
import "core:strconv"
import http "../../odin-http"
import dotenv "../../internal/dotenv"

VERSION :: "1.0.0"
CSS_VERSION :: "1"

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

    dotenv_line, dotenv_err := dotenv.load(".env", context.temp_allocator);
    free_all(context.temp_allocator);
    if dotenv_err != .None && dotenv_err != .Not_Found {
        log.fatalf("loading .env: %v (line %d)", dotenv_err, dotenv_line);
        os.exit(1);
    }

    cfg: Config;
	cfg.host = os.get_env("APP_HOST", context.allocator);
    port_str := os.get_env("APP_PORT", context.allocator);
	port, port_ok := strconv.parse_int(port_str, 10);
	if !port_ok || port == 0 {
		log.fatalf("invalid APP_PORT %q", port_str);
		os.exit(1);
	}
	cfg.port = port;

    server: http.Server;
    http.server_shutdown_on_interrupt(&server);

    router: http.Router;
    http.router_init(&router);
    defer http.router_destroy(&router);

    http.route_get(&router, "/", http.handler(proc(req: ^http.Request, res: ^http.Response) {
        http.respond_html(res, `
            <!DOCTYPE html>
            <html>
                <head>
                    <meta charset="UTF-8">
                    <title>Hello</title>
                    <style>
                        body {
                            background-color: black;
                            color: white;
                            margin: 0;
                            min-height: 100vh;
                            display: flex;
                            justify-content: center;
                            align-items: center;
                        }
                    </style>
                </head>
                <body>
                    <h1>
                        Hello there
                    </h1>
                </body>
            </html>
        `
        )
    }));

    endpoints := net.Endpoint {
        address = net.IP4_Loopback,
        port    = cfg.port,
    };

    listen_err := http.listen(&server, endpoints);
    if listen_err != nil {
        fmt.eprintfln("Could not listen on port %d: %v", cfg.port, listen_err);
        os.exit(1);
    }

    fmt.printfln("Server started on port: %d", cfg.port);

    serve_err := http.serve(&server, http.router_handler(&router));
    if serve_err != nil {
        fmt.eprintfln("Server stopped with an error: %v", serve_err);
        os.exit(1);
    }
}
