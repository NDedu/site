package main

import "core:fmt"
import "core:hash"
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
test_form_pages :: proc(t: ^testing.T) {
	site: Test_Site;
	defer test_site_stop(&site);
	if !test_site_start(t, &site) {
		return;
	}
	Case :: struct {
		path, script: string,
	};
	cases := [?]Case{
		{"/login", "/static/js/login.js"},
		{"/register", "/static/js/register.js"},
	};
	for c in cases {
		res, ok := send_request(t, site.port, "GET", c.path);
		if !ok {
			continue;
		}
		testing.expectf(t, res.status == 200, "%s: status %d", c.path, res.status);
		testing.expectf(t, res.headers["content-type"] == "text/html", "%s: content type %q", c.path, res.headers["content-type"]);
		testing.expectf(t, strings.contains(res.body, strings.concatenate({`action="`, c.path, `"`}, context.temp_allocator)), "%s: its form isn't in the page", c.path);
		testing.expectf(t, !strings.contains(res.body, "{{"), "%s: a placeholder is left in the page", c.path);

		// Each script uses the ones before it
		scripts := [?]string{"/static/js/template.js", "/static/js/forms.js", c.script};
		last := -1;
		for script in scripts {
			idx := strings.index(res.body, strings.concatenate({`<script defer src="`, script, "?v="}, context.temp_allocator));
			testing.expectf(t, idx > last, "%s: %s is missing, or comes before a script it uses", c.path, script);
			last = idx;
		}
	}
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
	for file in static_files {
		// With a query string, like real links
		res, ok := send_request(t, site.port, "GET", strings.concatenate({file.path, "?v=1"}, context.temp_allocator));
		if !ok {
			continue;
		}
		testing.expectf(t, res.status == 200, "%s: status %d", file.path, res.status);
		testing.expectf(t, res.headers["content-type"] == file.content_type, "%s: content type %q, want %q", file.path, res.headers["content-type"], file.content_type);

		// Same bytes as on disk, catches a static_folders line with the wrong folder
		on_disk, read_err := os.read_entire_file(strings.concatenate({#directory + "../..", file.path}, context.temp_allocator), context.temp_allocator);
		testing.expectf(t, read_err == nil && res.body == string(on_disk), "%s: got %d bytes that aren't the file's (%v)", file.path, len(res.body), read_err);
	}
}

@(test)
test_static_cache_control :: proc(t: ^testing.T) {
	site: Test_Site;
	defer test_site_stop(&site);
	if !test_site_start(t, &site) {
		return;
	}
	version, _ := static_version("/static/css/style.css");
	YEAR :: "public, max-age=31536000, immutable";
	HOURS :: "public, max-age=14400";
	Case :: struct {
		target, want: string,
	};
	cases := [?]Case{
		{fmt.tprintf("/static/css/style.css?v=%x", version), YEAR},
		{fmt.tprintf("/static/css/style.css?v=%x", version + 1), HOURS}, // an old ?v=
		{"/static/css/style.css", HOURS},
		{"/static/fonts/jbmono-nl-nerd-regular.woff2", HOURS},
	};
	for c in cases {
		if res, ok := send_request(t, site.port, "GET", c.target); ok {
			testing.expectf(t, res.headers["cache-control"] == c.want, "%s: cache-control %q, want %q", c.target, res.headers["cache-control"], c.want);
		}
	}
}

// Catches a new folder in static/ that's missing from static_folders
@(test)
test_static_folder_is_all_served :: proc(t: ^testing.T) {
	expect_folder_served(t, "/static");
}

expect_folder_served :: proc(t: ^testing.T, folder: string) {
	infos, err := os.read_all_directory_by_path(strings.concatenate({#directory + "../..", folder}, context.temp_allocator), context.temp_allocator);
	if !testing.expectf(t, err == nil, "%s: %v", folder, err) {
		return;
	}
	for info in infos {
		path := strings.concatenate({folder, "/", info.name}, context.temp_allocator);
		if info.type == .Directory {
			expect_folder_served(t, path);
			continue;
		}
		if ignored_static_file(info.name) {
			continue;
		}
		_, served := static_version(path);
		testing.expectf(t, served, "%s isn't served: add its folder to static_folders in routes.odin", path);
	}
}

@(test)
test_static_file_names :: proc(t: ^testing.T) {
	ignored := [?]string{".forms.js.swp", ".DS_Store", "forms.js~"};
	for name in ignored {
		testing.expectf(t, ignored_static_file(name), "%s: served, want it left out", name);
	}
	testing.expect(t, !ignored_static_file("forms.js"), "forms.js: left out, want it served");
	// No content type, load_static_files panics on these
	_, ok := static_content_type("notes.txt");
	testing.expect(t, !ok, "notes.txt: has a content type, want none");
}

// Every static link works and has the file's hash as ?v=. Every script is deferred,
// so they run in order (one without defer would run before the scripts it needs)
@(test)
test_pages_link_to_static_files :: proc(t: ^testing.T) {
	site: Test_Site;
	defer test_site_stop(&site);
	if !test_site_start(t, &site) {
		return;
	}
	pages := [?]string{"/", "/login", "/register", "/nope"};
	for page in pages {
		res, ok := send_request(t, site.port, "GET", page);
		if !ok {
			continue;
		}
		rest := res.body;
		for {
			start := strings.index(rest, `"/static/`);
			if start < 0 {
				break;
			}
			rest = rest[start + 1:];
			end := strings.index_byte(rest, '"');
			if end < 0 {
				break;
			}
			url := rest[:end];
			rest = rest[end:];

			file, file_ok := send_request(t, site.port, "GET", url);
			if !file_ok {
				continue;
			}
			testing.expectf(t, file.status == 200, "%s links to %s: status %d", page, url, file.status);
			path, _, version := strings.partition(url, "?v=");
			if filepath.ext(path) == ".woff2" {
				continue; // style.css links fonts without ?v= too, a changed font needs a new name
			}
			want := fmt.tprintf("%x", hash.crc32(transmute([]byte)file.body));
			testing.expectf(t, version == want, "%s links to %s, want ?v=%s: the file's hash", page, url, want);
		}

		tags := res.body;
		for {
			start := strings.index(tags, "<script");
			if start < 0 {
				break;
			}
			tags = tags[start:];
			end := strings.index_byte(tags, '>');
			if end < 0 {
				break;
			}
			tag := tags[:end + 1];
			tags = tags[end + 1:];
			testing.expectf(t, !strings.contains(tag, " src=") || strings.contains(tag, " defer"), "%s: %s isn't deferred", page, tag);
		}
	}
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
		{"GET", "/static/../../.env"}, // matched by name, nothing is read from disk
		{"POST", "/"},
	};
	for c in cases {
		if res, ok := send_request(t, site.port, c.method, c.target); ok {
			testing.expectf(t, res.status == 404, "%s %s: status %d, want 404", c.method, c.target, res.status);
		}
	}
}

@(test)
test_not_found_page :: proc(t: ^testing.T) {
	site: Test_Site;
	defer test_site_stop(&site);
	if !test_site_start(t, &site) {
		return;
	}
	res, ok := send_request(t, site.port, "GET", "/nope");
	if !ok {
		return;
	}
	testing.expect_value(t, res.status, 404);
	testing.expect_value(t, res.headers["content-type"], "text/html");
	testing.expect(t, strings.contains(res.body, `data-status="warn"`), "the status isn't warn");
	testing.expect(t, strings.contains(res.body, "narcis@dedu:~/nope$"), "the path isn't in the status line");
	testing.expect(t, !strings.contains(res.body, "{{"), "a placeholder is left in the page");
}
