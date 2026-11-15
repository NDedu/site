package main

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

@(test)
test_home_page :: proc(t: ^testing.T) {
	site: Test_Site;
	defer test_site_stop(&site);
	if !test_site_start(t, &site) {
		return;
	}
	res, ok := send_request(t, site.port, "GET", "/");
	if !ok {
		return;
	}
	testing.expect_value(t, res.status, 200);
	testing.expect_value(t, res.headers["content-type"], "text/html");
	testing.expect(t, strings.contains(res.body, #load("templates/home.html", string)), "home.html isn't in the page");
	testing.expect(t, !strings.contains(res.body, "{{"), "a placeholder is left in the page");
}

@(test)
test_home_page_head :: proc(t: ^testing.T) {
	site: Test_Site;
	defer test_site_stop(&site);
	if !test_site_start(t, &site) {
		return;
	}
	get, get_ok := send_request(t, site.port, "GET", "/");
	head, head_ok := send_request(t, site.port, "HEAD", "/");
	if !get_ok || !head_ok {
		return;
	}
	testing.expect_value(t, head.status, 200);
	testing.expect_value(t, head.headers["content-type"], "text/html");
	// TODO: once HEAD is fixed (see routes.odin), check the body is empty: testing.expect_value(t, head.body, "")
	length, _ := strconv.parse_int(head.headers["content-length"], 10);
	testing.expect_value(t, length, len(get.body));
}

@(test)
test_version :: proc(t: ^testing.T) {
	site: Test_Site;
	defer test_site_stop(&site);
	if !test_site_start(t, &site) {
		return;
	}
	res, ok := send_request(t, site.port, "GET", "/version");
	if !ok {
		return;
	}
	testing.expect_value(t, res.status, 200);
	testing.expect_value(t, res.headers["content-type"], "text/plain");
	testing.expect_value(t, res.headers["cache-control"], "no-store");
	testing.expect_value(t, res.body, GIT_SHA);
}

@(test)
test_static_files :: proc(t: ^testing.T) {
	site: Test_Site;
	defer test_site_stop(&site);
	if !test_site_start(t, &site) {
		return;
	}
	for file in STATIC_FILES {
		// With a query string, like the ?v= on the stylesheet
		res, ok := send_request(t, site.port, "GET", strings.concatenate({file.path, "?v=1"}, context.temp_allocator));
		if !ok {
			continue;
		}
		testing.expectf(t, res.status == 200, "%s: status %d", file.path, res.status);

		want_type := expected_content_type(file.path);
		testing.expectf(t, res.headers["content-type"] == want_type, "%s: content type %q, want %q (a new kind of file? add it to expected_content_type)", file.path, res.headers["content-type"], want_type);

		// The file at that path in the repo, which catches a STATIC_FILES line with the wrong #load
		on_disk, read_err := os.read_entire_file(strings.concatenate({#directory + "../..", file.path}, context.temp_allocator), context.temp_allocator);
		testing.expectf(t, read_err == nil && res.body == string(on_disk), "%s: got %d bytes that aren't the file's (%v)", file.path, len(res.body), read_err);
	}
}

// What browsers need each kind of file served as: a stylesheet that isn't text/css is ignored
expected_content_type :: proc(path: string) -> string {
	switch filepath.ext(path) {
	case ".css":   return "text/css; charset=utf-8";
	case ".woff2": return "font/woff2";
	}
	return "";
}

@(test)
test_unknown_paths_are_not_found :: proc(t: ^testing.T) {
	site: Test_Site;
	defer test_site_stop(&site);
	if !test_site_start(t, &site) {
		return;
	}
	Case :: struct {
		method, target: string,
	};
	cases := [?]Case{
		{"GET", "/nope"},
		{"GET", "/static/"},
		{"GET", "/static/nope.css"},
		{"GET", "/static/../../.env"}, // static files are looked up by name, nothing is read from disk
		{"POST", "/"},
	};
	for c in cases {
		if res, ok := send_request(t, site.port, c.method, c.target); ok {
			testing.expectf(t, res.status == 404, "%s %s: status %d, want 404", c.method, c.target, res.status);
		}
	}
}
