package main

import "core:testing"
import http "../../odin-http"

ALLOWED_ORIGIN :: "https://allowed.test"

test_cors_options := Cors_Options{
	allowed_origins = {ALLOWED_ORIGIN},
	allowed_methods = "GET, POST",
	allowed_headers = "Content-Type",
	max_age         = "600",
}

// cors_set_headers for a request with these headers
check_cors :: proc(opts: ^Cors_Options, method: http.Method, headers: ..[2]string) -> (preflight: bool, res: http.Response) {
	req := fake_request(method, "/api", ..headers);
	res = fake_response();
	preflight = cors_set_headers(opts, &req, &res);
	return;
}

@(test)
test_cors_does_nothing_without_allowed_origins :: proc(t: ^testing.T) {
	opts := Cors_Options{};
	preflight, res := check_cors(&opts, .Options, {"Origin", ALLOWED_ORIGIN}, {"Access-Control-Request-Method", "POST"});
	testing.expect(t, !preflight, "preflight answered");
	testing.expect_value(t, http.headers_count(res.headers), 0);
}

@(test)
test_cors_allowed_origin :: proc(t: ^testing.T) {
	preflight, res := check_cors(&test_cors_options, .Get, {"Origin", ALLOWED_ORIGIN});
	testing.expect(t, !preflight, "a GET answered as a preflight");
	testing.expect_value(t, http.headers_get_unsafe(res.headers, "access-control-allow-origin"), ALLOWED_ORIGIN);
	testing.expect_value(t, http.headers_get_unsafe(res.headers, "vary"), "Origin");
	testing.expect(t, !http.headers_has_unsafe(res.headers, "access-control-allow-methods"), "allowed methods outside a preflight");
}

@(test)
test_cors_other_origins :: proc(t: ^testing.T) {
	// Only the exact origin counts
	origins := []string{"https://other.test", "http://allowed.test", "https://allowed.test:8443", "https://allowed.test.other.test", "https://allowed.test/", "null"};
	for origin in origins {
		preflight, res := check_cors(&test_cors_options, .Options, {"Origin", origin}, {"Access-Control-Request-Method", "POST"});
		testing.expectf(t, !preflight, "%s: preflight answered", origin);
		testing.expectf(t, !http.headers_has_unsafe(res.headers, "access-control-allow-origin"), "%s: allowed", origin);
		testing.expectf(t, http.headers_get_unsafe(res.headers, "vary") == "Origin", "%s: no Vary: Origin", origin);
	}
}

@(test)
test_cors_request_without_origin :: proc(t: ^testing.T) {
	preflight, res := check_cors(&test_cors_options, .Get);
	testing.expect(t, !preflight, "preflight answered");
	testing.expect(t, !http.headers_has_unsafe(res.headers, "access-control-allow-origin"), "allowed without an Origin");
	testing.expect_value(t, http.headers_get_unsafe(res.headers, "vary"), "Origin");
}

@(test)
test_cors_preflight :: proc(t: ^testing.T) {
	preflight, res := check_cors(&test_cors_options, .Options, {"Origin", ALLOWED_ORIGIN}, {"Access-Control-Request-Method", "POST"}, {"Access-Control-Request-Headers", "content-type"});
	testing.expect(t, preflight, "preflight not answered");
	testing.expect_value(t, http.headers_get_unsafe(res.headers, "access-control-allow-origin"), ALLOWED_ORIGIN);
	testing.expect_value(t, http.headers_get_unsafe(res.headers, "access-control-allow-methods"), "GET, POST");
	testing.expect_value(t, http.headers_get_unsafe(res.headers, "access-control-allow-headers"), "Content-Type");
	testing.expect_value(t, http.headers_get_unsafe(res.headers, "access-control-max-age"), "600");
}

@(test)
test_cors_options_request_that_is_not_a_preflight :: proc(t: ^testing.T) {
	// No Access-Control-Request-Method: an OPTIONS request for the router
	preflight, res := check_cors(&test_cors_options, .Options, {"Origin", ALLOWED_ORIGIN});
	testing.expect(t, !preflight, "preflight answered");
	testing.expect_value(t, http.headers_get_unsafe(res.headers, "access-control-allow-origin"), ALLOWED_ORIGIN);
}

@(test)
test_cors_any_origin :: proc(t: ^testing.T) {
	opts := test_cors_options;
	opts.allowed_origins = {"*"};
	preflight, res := check_cors(&opts, .Options, {"Origin", "https://anyone.test"}, {"Access-Control-Request-Method", "GET"});
	testing.expect(t, preflight, "preflight not answered");
	testing.expect_value(t, http.headers_get_unsafe(res.headers, "access-control-allow-origin"), "*");
}

@(test)
test_cors_passes_other_requests_on :: proc(t: ^testing.T) {
	fake: Fake_Next;
	next := fake_next(&fake);
	handler := cors(&next, &test_cors_options);

	req := fake_request(.Get, "/", {"Origin", ALLOWED_ORIGIN});
	res := fake_response();
	handler.handle(&handler, &req, &res);
	testing.expect_value(t, fake.calls, 1);
	testing.expect_value(t, fake.headers_seen, http.headers_count(res.headers)); // all set before passing the request on

	req = fake_request(.Options, "/", {"Origin", "https://other.test"}, {"Access-Control-Request-Method", "POST"});
	res = fake_response();
	handler.handle(&handler, &req, &res);
	testing.expect_value(t, fake.calls, 2);
}

@(test)
test_cors_on_a_server :: proc(t: ^testing.T) {
	router: http.Router;
	http.router_init(&router);
	defer http.router_destroy(&router);
	routes(&router);
	router_handler := http.router_handler(&router);

	ts: Test_Server;
	defer test_server_stop(&ts);
	if !test_server_start(t, &ts, cors(&router_handler, &test_cors_options)) {
		return;
	}

	// Answered before the router, which has no OPTIONS routes
	if res, ok := send_request(t, ts.port, "OPTIONS", "/anything", {"Origin", ALLOWED_ORIGIN}, {"Access-Control-Request-Method", "POST"}); ok {
		testing.expect_value(t, res.status, 204);
		testing.expect_value(t, res.headers["access-control-allow-origin"], ALLOWED_ORIGIN);
		testing.expect_value(t, res.headers["access-control-allow-methods"], "GET, POST");
		testing.expect_value(t, res.body, "");
	}
	if res, ok := send_request(t, ts.port, "OPTIONS", "/anything", {"Origin", "https://other.test"}, {"Access-Control-Request-Method", "POST"}); ok {
		testing.expect_value(t, res.status, 404);
		testing.expect(t, "access-control-allow-origin" not_in res.headers, "allowed");
	}
	if res, ok := send_request(t, ts.port, "GET", "/", {"Origin", ALLOWED_ORIGIN}); ok {
		testing.expect_value(t, res.status, 200);
		testing.expect_value(t, res.headers["access-control-allow-origin"], ALLOWED_ORIGIN);
	}
}
