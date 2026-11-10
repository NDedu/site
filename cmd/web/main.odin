package main

import "core:net"
import "core:fmt"
import http "../../odin-http"

PORT :: 8080

main :: proc() {

    server: http.Server;
    http.server_shutdown_on_interrupt(&server);

    router: http.Router;
    http.router_init(&router);
    defer http.router_destroy(&router);

    http.route_get(&router, "/", http.handler(proc(req: ^http.Request, res: ^http.Response) {
        http.respond_html(res, `
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
        address = net.IP4_Any,
        port    = PORT,
    };

    fmt.printf("Server started on port: %d", PORT);
    http.listen_and_serve(&server, http.router_handler(&router), endpoints);
}
