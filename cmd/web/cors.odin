package main

import http "../../odin-http"

Cors_Options :: struct {
	allowed_origins: []string, // as browsers send them: "https://example.com", no trailing slash. "*" allows any
	allowed_methods: string,   // the rest are only sent in answer to a preflight
	allowed_headers: string,
	max_age:         string,   // seconds a browser may reuse a preflight answer
}

// No origins: other sites can't read the responses
cors_options := Cors_Options{
	allowed_origins = {},
	allowed_methods = "GET, POST",
	allowed_headers = "Content-Type",
	max_age         = "600",
}

// Lets the allowed origins read responses. Anything else goes on unchanged, so a preflight from another origin reaches the router and fails there
cors :: proc(next: ^http.Handler, opts: ^Cors_Options) -> http.Handler {
	h := http.middleware_proc(next, proc(self: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		if cors_set_headers((^Cors_Options)(self.user_data), req, res) {
			http.respond(res, http.Status.No_Content);
			return;
		}
		next := self.next.(^http.Handler);
		next.handle(next, req, res);
	});
	h.user_data = opts;
	return h;
}

// True for a preflight from an allowed origin: it's answered with these headers alone
cors_set_headers :: proc(opts: ^Cors_Options, req: ^http.Request, res: ^http.Response) -> (preflight: bool) {
	if len(opts.allowed_origins) == 0 {
		return false;
	}
	// The answer depends on Origin, so caches must keep one per origin
	http.headers_set_unsafe(&res.headers, "vary", "Origin");

	origin, has_origin := http.headers_get_unsafe(req.headers, "origin");
	if !has_origin {
		return false;
	}
	allow_origin, allowed := cors_allow_origin(opts.allowed_origins, origin);
	if !allowed {
		return false;
	}
	http.headers_set_unsafe(&res.headers, "access-control-allow-origin", allow_origin);

	// A preflight asks whether the real request may be sent
	if req.line.(http.Requestline).method != .Options || !http.headers_has_unsafe(req.headers, "access-control-request-method") {
		return false;
	}
	http.headers_set_unsafe(&res.headers, "access-control-allow-methods", opts.allowed_methods);
	http.headers_set_unsafe(&res.headers, "access-control-allow-headers", opts.allowed_headers);
	http.headers_set_unsafe(&res.headers, "access-control-max-age", opts.max_age);
	return true;
}

// The Access-Control-Allow-Origin value for origin, if it's allowed
cors_allow_origin :: proc(allowed_origins: []string, origin: string) -> (value: string, ok: bool) {
	for allowed in allowed_origins {
		if allowed == "*" {
			return "*", true;
		}
		if allowed == origin {
			return origin, true;
		}
	}
	return "", false;
}
