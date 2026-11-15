package main

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import http "../../odin-http"

// Helpers for this package's tests

// A request as the server hands it to a handler, to call one without a server.
// Only for handlers that don't respond: http.respond needs a real connection.
fake_request :: proc(method: http.Method, target: string, headers: ..[2]string) -> (req: http.Request) {
	http.request_init(&req, context.temp_allocator);
	req.line = http.Requestline{method = method, target = target, version = {1, 1}};
	req.url = http.url_parse(target);
	for header in headers {
		http.headers_set(&req.headers, header[0], header[1]);
	}
	return;
}

fake_response :: proc() -> (res: http.Response) {
	http.response_init(&res, context.temp_allocator);
	return;
}

// Stands in for the handler a middleware wraps
Fake_Next :: struct {
	calls:        int,
	headers_seen: int, // response headers already set when it ran
}

fake_next :: proc(fake: ^Fake_Next) -> http.Handler {
	return http.Handler{
		user_data = fake,
		handle    = proc(self: ^http.Handler, req: ^http.Request, res: ^http.Response) {
			fake := (^Fake_Next)(self.user_data);
			fake.calls += 1;
			fake.headers_seen = http.headers_count(res.headers);
		},
	};
}

// A real server on a free port, on a thread of its own
Test_Server :: struct {
	server:    http.Server,
	handler:   http.Handler,
	port:      int,
	err:       net.Network_Error,
	ready:     sync.Sema,
	thread:    ^thread.Thread,
	allocator: runtime.Allocator,
}

// Returns once the server accepts connections. Call test_server_stop even when it fails.
test_server_start :: proc(t: ^testing.T, ts: ^Test_Server, handler: http.Handler) -> bool {
	testing.set_fail_timeout(t, 30 * time.Second);
	ts.handler = handler;
	ts.allocator = context.allocator; // the test's, so its memory report covers the server too
	ts.thread = thread.create_and_start_with_poly_data(ts, proc(ts: ^Test_Server) {
		// Otherwise a context of its own: the test's logger and temp allocator aren't safe to share
		context.allocator = ts.allocator;

		opts := http.Default_Server_Opts;
		opts.thread_count = 1;
		ts.err = http.listen(&ts.server, net.Endpoint{address = net.IP4_Loopback, port = 0}, opts);
		if ts.err == nil {
			endpoint, _ := net.bound_endpoint(ts.server.tcp_sock);
			ts.port = endpoint.port;
		}
		sync.sema_post(&ts.ready);
		if ts.err == nil {
			http.serve(&ts.server, ts.handler);
		}
	});
	sync.sema_wait(&ts.ready);
	return testing.expectf(t, ts.err == nil, "the test server didn't start: %v", ts.err);
}

test_server_stop :: proc(ts: ^Test_Server) {
	if ts.err == nil {
		http.server_shutdown(&ts.server);
	}
	thread.destroy(ts.thread);
}

// The site as it runs: its routes behind every middleware
Test_Site :: struct {
	using test_server: Test_Server,
	router:            http.Router,
	middleware:        Middleware,
}

test_site_start :: proc(t: ^testing.T, site: ^Test_Site) -> bool {
	http.router_init(&site.router);
	routes(&site.router);
	return test_server_start(t, &site.test_server, middleware_init(&site.middleware, &site.router));
}

test_site_stop :: proc(site: ^Test_Site) {
	test_server_stop(&site.test_server);
	http.router_destroy(&site.router);
}

Test_Response :: struct {
	status:  int,
	headers: map[string]string, // names in lowercase
	body:    string,
}

// Sends one request on a new connection and reads all of the response
send_request :: proc(t: ^testing.T, port: int, method, target: string, headers: ..[2]string, loc := #caller_location) -> (res: Test_Response, ok: bool) {
	socket, dial_err := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = port});
	if !testing.expectf(t, dial_err == nil, "%s %s: connecting: %v", method, target, dial_err, loc = loc) {
		return;
	}
	defer net.close(socket);
	net.set_option(socket, .Receive_Timeout, 5 * time.Second);

	// Connection: close, so the server closes the connection once it has answered, and reading stops there
	request := strings.builder_make(context.temp_allocator);
	fmt.sbprintf(&request, "%s %s HTTP/1.1\r\nHost: test\r\nConnection: close\r\n", method, target);
	for header in headers {
		fmt.sbprintf(&request, "%s: %s\r\n", header[0], header[1]);
	}
	strings.write_string(&request, "\r\n");

	for unsent := request.buf[:]; len(unsent) > 0; {
		sent, send_err := net.send_tcp(socket, unsent);
		if !testing.expectf(t, send_err == nil, "%s %s: sending: %v", method, target, send_err, loc = loc) {
			return;
		}
		unsent = unsent[sent:];
	}

	received := make([dynamic]byte, context.temp_allocator);
	buf: [4096]byte;
	for {
		n, recv_err := net.recv_tcp(socket, buf[:]);
		if !testing.expectf(t, recv_err == nil, "%s %s: receiving: %v", method, target, recv_err, loc = loc) {
			return;
		}
		if n == 0 {
			break;
		}
		append(&received, ..buf[:n]);
	}

	// "HTTP/1.1 200 " then a line per header, a blank line and the body
	head, _, body := strings.partition(string(received[:]), "\r\n\r\n");
	status_line, _ := strings.split_iterator(&head, "\r\n");
	if !testing.expectf(t, len(status_line) >= 12 && strings.has_prefix(status_line, "HTTP/1.1 "), "%s %s: not an HTTP response: %q", method, target, string(received[:]), loc = loc) {
		return;
	}
	res.status, _ = strconv.parse_int(status_line[9:12], 10);
	res.body = body;
	res.headers = make(map[string]string, context.temp_allocator);
	for line in strings.split_iterator(&head, "\r\n") {
		name, _, value := strings.partition(line, ":");
		res.headers[strings.to_lower(name, context.temp_allocator)] = strings.trim_space(value);
	}
	return res, true;
}
