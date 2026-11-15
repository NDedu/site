package main

import http "../../odin-http"
import "../../internal/accesslog"

Middleware :: struct {
	access_log: http.Handler,
	headers:    http.Handler,
	cors:       http.Handler,
	router:     http.Handler,
}

// Returns the outermost handler, for http.serve
middleware_init :: proc(m: ^Middleware, router: ^http.Router) -> http.Handler {
	m.router     = http.router_handler(router);
	m.cors       = cors(&m.router, &cors_options);
	m.headers    = common_headers(&m.cors);
	m.access_log = accesslog.handler(&m.headers);
	return m.access_log;
}

// Headers every response gets
common_headers :: proc(next: ^http.Handler) -> http.Handler {
	return http.middleware_proc(next, proc(self: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		// Only what can't break the page: default-src 'self' would also block the inline theme script in template.html
		http.headers_set_unsafe(&res.headers, "content-security-policy", "base-uri 'self'; object-src 'none'; frame-ancestors 'none'");
		http.headers_set_unsafe(&res.headers, "referrer-policy", "strict-origin-when-cross-origin");
		http.headers_set_unsafe(&res.headers, "x-content-type-options", "nosniff");

		next := self.next.(^http.Handler);
		next.handle(next, req, res);
	});
}
