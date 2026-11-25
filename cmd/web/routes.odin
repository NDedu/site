package main

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import http "../../odin-http"

// TODO: HEAD responses still send the body (odin-http's respond_with_none doesn't drop it)
// Workaround: for req.is_head, set content-length to the body's length and respond without a body
routes :: proc(router: ^http.Router) {
	http.route_get(router, "/", http.handler(home))
	http.route_get(router, "/login", http.handler(login))
	http.route_get(router, "/register", http.handler(register))
	http.route_get(router, "/version", http.handler(version))
	http.route_get(router, "/static/.*", http.handler(static))
	http.route_all(router, ".*", http.handler(not_found))
}

home :: proc(req: ^http.Request, res: ^http.Response) {
	render(req, res, Page{
		description = "Home page",
		content     = #load("templates/home.html", string),
	})
}

version :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set_unsafe(&res.headers, "cache-control", "no-store")
	http.respond_plain(res, GIT_SHA)
}

Static_Folder :: struct {
	url:   string,
	files: []runtime.Load_Directory_File, // embedded at compile time
}

// New files are picked up on the next build, a new folder needs a line here
static_folders := [?]Static_Folder{
	{"/static/css/",   #load_directory("../../static/css")},
	{"/static/js/",    #load_directory("../../static/js")},
	{"/static/fonts/", #load_directory("../../static/fonts")},
}

Static_File :: struct {
	path:         string,
	content_type: string,
	data:         []byte,
	version:      u32, // crc32 of data, the ?v= in links
}

static_files: []Static_File

@(init)
load_static_files :: proc "contextless" () {
	context = runtime.default_context()
	files: [dynamic]Static_File
	for folder in static_folders {
		for file in folder.files {
			if ignored_static_file(file.name) {
				continue
			}
			content_type, ok := static_content_type(file.name)
			if !ok {
				fmt.panicf("%s%s: no content type for this kind of file: add one to static_content_type", folder.url, file.name)
			}
			append(&files, Static_File{
				path         = strings.concatenate({folder.url, file.name}),
				content_type = content_type,
				data         = file.data,
				version      = hash.crc32(file.data),
			})
		}
	}
	static_files = files[:]
}

// Hidden files and editor backups, like .forms.js.swp and forms.js~
ignored_static_file :: proc(name: string) -> bool {
	return strings.has_prefix(name, ".") || strings.has_suffix(name, "~")
}

static_content_type :: proc(name: string) -> (content_type: string, ok: bool) {
	switch filepath.ext(name) {
	case ".css":   return "text/css; charset=utf-8", true
	case ".js":    return "text/javascript; charset=utf-8", true
	case ".woff2": return "font/woff2", true
	case ".svg":   return "image/svg+xml", true
	case ".png":   return "image/png", true
	case ".jpg":   return "image/jpeg", true
	case ".webp":  return "image/webp", true
	}
	return "", false
}

static_version :: proc(path: string) -> (version: u32, ok: bool) {
	for file in static_files {
		if file.path == path {
			return file.version, true
		}
	}
	return
}

static :: proc(req: ^http.Request, res: ^http.Response) {
	for file in static_files {
		if file.path != req.url.path {
			continue
		}
		res.status = .OK
		http.headers_set_content_type(&res.headers, file.content_type)
		http.headers_set_unsafe(&res.headers, "cache-control", static_cache_control(req.url, file))
		http.body_set(res, file.data)
		http.respond(res)
		return
	}
	http.respond(res, http.Status.Not_Found)
}

// A year when ?v= matches the file's hash (that URL never changes), else 4 hours like Cloudflare's default
static_cache_control :: proc(url: http.URL, file: Static_File) -> string {
	buf: [16]byte
	version, _ := http.query_get(url, "v")
	if version == strconv.write_uint(buf[:], u64(file.version), 16) {
		return "public, max-age=31536000, immutable"
	}
	return "public, max-age=14400"
}

// Instead of the router's 404, which logs an extra line besides the access log
not_found :: proc(req: ^http.Request, res: ^http.Response) {
	render(req, res, Page{
		description = "Page not found",
		status      = .Warn,
		content     = #load("templates/not_found.html", string),
	}, .Not_Found)
}

login :: proc(req: ^http.Request, res: ^http.Response) {
	render(req, res, Page{
		description = "Login page",
		content     = #load("templates/login.html", string),
	})
}

register :: proc(req: ^http.Request, res: ^http.Response) {
	render(req, res, Page{
		description = "Register page",
		content     = #load("templates/register.html", string),
	})
}
