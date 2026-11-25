package main

import "core:testing"
import http "../../odin-http"

@(test)
test_common_headers :: proc(t: ^testing.T) {
	fake: Fake_Next
	next := fake_next(&fake)
	handler := common_headers(&next)
	req := fake_request(.Get, "/")
	res := fake_response()

	handler.handle(&handler, &req, &res)

	testing.expect_value(t, fake.calls, 1)
	testing.expect_value(t, fake.headers_seen, http.headers_count(res.headers)) // all set before calling next
	testing.expect_value(t, http.headers_get_unsafe(res.headers, "content-security-policy"), "base-uri 'self'; object-src 'none'; frame-ancestors 'none'")
	testing.expect_value(t, http.headers_get_unsafe(res.headers, "referrer-policy"), "strict-origin-when-cross-origin")
	testing.expect_value(t, http.headers_get_unsafe(res.headers, "x-content-type-options"), "nosniff")
}

@(test)
test_middleware_init_covers_every_response :: proc(t: ^testing.T) {
	site: Test_Site
	defer test_site_stop(&site)
	if !test_site_start(t, &site) {
		return
	}
	targets := []string{"/", "/version", "/static/css/style.css", "/nope"}
	for target in targets {
		if res, ok := send_request(t, site.port, "GET", target); ok {
			testing.expectf(t, res.headers["x-content-type-options"] == "nosniff", "GET %s: no common headers in %v", target, res.headers)
		}
	}
}
