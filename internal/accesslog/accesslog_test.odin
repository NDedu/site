package accesslog

import "core:log"
import "core:strings"
import "core:testing"
import http "../../odin-http"

// What the wrapped handler does
Inner :: struct {
	calls:  int,
	status: http.Status,
	sent:   bool,
}

// The logged line, instead of printing it
Captured :: struct {
	count: int,
	level: log.Level,
	text:  string, // copied to buf, logf frees the original after the logger returns
	buf:   [256]byte,
}

run :: proc(captured: ^Captured, inner: ^Inner, method: http.Method, target: string, visitor_ip := "", is_head := false) {
	context.logger = log.Logger{
		procedure = proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
			captured := (^Captured)(data);
			captured.count += 1;
			captured.level = level;
			captured.text = string(captured.buf[:copy(captured.buf[:], text)]);
		},
		data         = captured,
		lowest_level = .Debug,
	};

	req: http.Request;
	http.request_init(&req, context.temp_allocator);
	req.line = http.Requestline{method = method, target = target, version = {1, 1}};
	req.url = http.url_parse(target);
	req.is_head = is_head;
	if visitor_ip != "" {
		http.headers_set_unsafe(&req.headers, "cf-connecting-ip", visitor_ip);
	}
	res: http.Response;
	http.response_init(&res, context.temp_allocator);

	next := http.Handler{
		user_data = inner,
		handle    = proc(self: ^http.Handler, req: ^http.Request, res: ^http.Response) {
			inner := (^Inner)(self.user_data);
			inner.calls += 1;
			res.status = inner.status;
			res.sent = inner.sent; // what http.respond would set
		},
	};
	logged := handler(&next);
	logged.handle(&logged, &req, &res);
}

// Fields: method, path, status, duration, visitor IP
expect_fields :: proc(t: ^testing.T, captured: ^Captured, method, path, status, visitor_ip: string, loc := #caller_location) {
	fields := strings.fields(captured.text, context.temp_allocator);
	if !testing.expectf(t, len(fields) == 5, "logged %q", captured.text, loc = loc) {
		return;
	}
	testing.expectf(t, fields[0] == method && fields[1] == path && fields[2] == status && fields[4] == visitor_ip,
		"logged %q, want %s %s %s <time> %s", captured.text, method, path, status, visitor_ip, loc = loc);
	testing.expectf(t, strings.has_suffix(fields[3], "s"), "logged %q: %q isn't a duration", captured.text, fields[3], loc = loc);
}

@(test)
test_logs_one_line_per_request :: proc(t: ^testing.T) {
	inner := Inner{status = .OK, sent = true};
	captured: Captured;
	run(&captured, &inner, .Get, "/about?utm_source=x", "203.0.113.7");

	testing.expect_value(t, inner.calls, 1);
	testing.expect_value(t, captured.count, 1);
	testing.expect_value(t, captured.level, log.Level.Info);
	expect_fields(t, &captured, "GET", "/about", "200", "203.0.113.7"); // no query string
}

@(test)
test_logs_a_dash_without_a_visitor_ip :: proc(t: ^testing.T) {
	inner := Inner{status = .OK, sent = true};
	captured: Captured;
	run(&captured, &inner, .Post, "/");
	expect_fields(t, &captured, "POST", "/", "200", "-");
}

@(test)
test_logs_head_requests_as_head :: proc(t: ^testing.T) {
	inner := Inner{status = .OK, sent = true};
	captured: Captured;
	run(&captured, &inner, .Get, "/", is_head = true); // odin-http passes HEAD as GET
	expect_fields(t, &captured, "HEAD", "/", "200", "-");
}

@(test)
test_server_errors_are_logged_as_errors :: proc(t: ^testing.T) {
	not_found := Inner{status = .Not_Found, sent = true};
	captured_404: Captured;
	run(&captured_404, &not_found, .Get, "/nope");
	testing.expect_value(t, captured_404.level, log.Level.Info);
	expect_fields(t, &captured_404, "GET", "/nope", "404", "-");

	broken := Inner{status = .Internal_Server_Error, sent = true};
	captured_500: Captured;
	run(&captured_500, &broken, .Get, "/broken");
	testing.expect_value(t, captured_500.level, log.Level.Error);
	expect_fields(t, &captured_500, "GET", "/broken", "500", "-");
}

@(test)
test_logs_pending_when_the_handler_has_not_responded :: proc(t: ^testing.T) {
	inner := Inner{status = .OK, sent = false};
	captured: Captured;
	run(&captured, &inner, .Get, "/slow");
	testing.expect_value(t, captured.level, log.Level.Info);
	expect_fields(t, &captured, "GET", "/slow", "pending", "-");
}
