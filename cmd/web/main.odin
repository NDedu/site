package main

import "core:net"
import "core:fmt"
import "core:mem"
import "core:os"
import http "../../odin-http"

VERSION :: "1.0.0"
CSS_VERSION :: "1"
PORT :: 8080

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
        port    = PORT,
    };

    listen_err := http.listen(&server, endpoints);
    if listen_err != nil {
        fmt.eprintfln("Could not listen on port %d: %v", PORT, listen_err);
        os.exit(1);
    }

    fmt.printfln("Server started on port: %d", PORT);

    serve_err := http.serve(&server, http.router_handler(&router));
    if serve_err != nil {
        fmt.eprintfln("Server stopped with an error: %v", serve_err);
        os.exit(1);
    }
}
