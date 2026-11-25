package main

import http "../../odin-http"

Cors_Options :: struct {
	allowed_origins: []string, // exact, like "https://example.com" without a trailing slash, or "*"
	allowed_methods: string,   // this and below are only sent on preflights
	allowed_headers: string,
	max_age:         string,   // seconds a browser caches the preflight response
}

// No origins, so other sites can't read the responses
cors_options := Cors_Options{
	allowed_origins = {},
	allowed_methods = "GET, POST",
	allowed_headers = "Content-Type",
	max_age         = "600",
}

// Other origins pass through unchanged, so their preflights get a 404 from the router
cors :: proc(next: ^http.Handler, opts: ^Cors_Options) -> http.Handler {
	h := http.middleware_proc(next, proc(self: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		if cors_set_headers((^Cors_Options)(self.user_data), req, res) {
			http.respond(res, http.Status.No_Content)
			return
		}
		next := self.next.(^http.Handler)
		next.handle(next, req, res)
	})
	h.user_data = opts
	return h
}

// True for a preflight from an allowed origin, which cors answers with a 204
cors_set_headers :: proc(opts: ^Cors_Options, req: ^http.Request, res: ^http.Response) -> (preflight: bool) {
	if len(opts.allowed_origins) == 0 {
		return false
	}
	// The response depends on Origin, caches need one copy per origin
	http.headers_set_unsafe(&res.headers, "vary", "Origin")

	origin, has_origin := http.headers_get_unsafe(req.headers, "origin")
	if !has_origin {
		return false
	}
	allow_origin, allowed := cors_allow_origin(opts.allowed_origins, origin)
	if !allowed {
		return false
	}
	http.headers_set_unsafe(&res.headers, "access-control-allow-origin", allow_origin)

	if req.line.(http.Requestline).method != .Options || !http.headers_has_unsafe(req.headers, "access-control-request-method") {
		return false
	}
	http.headers_set_unsafe(&res.headers, "access-control-allow-methods", opts.allowed_methods)
	http.headers_set_unsafe(&res.headers, "access-control-allow-headers", opts.allowed_headers)
	http.headers_set_unsafe(&res.headers, "access-control-max-age", opts.max_age)
	return true
}

cors_allow_origin :: proc(allowed_origins: []string, origin: string) -> (value: string, ok: bool) {
	for allowed in allowed_origins {
		if allowed == "*" {
			return "*", true
		}
		if allowed == origin {
			return origin, true
		}
	}
	return "", false
}
