package main

import "core:net"
import "core:fmt"
import "core:mem"
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
                        Hello there!
                    </h1>
                </body>
            </html>
        `
        )
    }));

    endpoints := net.Endpoint {
        address = net.IP4_Any,
        port    = PORT,
    };

    fmt.printf("Server started on port: %d \n", PORT);
    http.listen_and_serve(&server, http.router_handler(&router), endpoints);
}
