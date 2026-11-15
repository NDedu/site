package main

import http "../../odin-http"

routes :: proc(router: ^http.Router) {
	http.route_get(router, "/", http.handler(home));
	http.route_get(router, "/version", http.handler(version));
	http.route_get(router, "/static/.*", http.handler(static));
}

home :: proc(req: ^http.Request, res: ^http.Response) {
	render(req, res, Page{
		title       = "Narcis Dedu",
		description = "Home page",
		content     = #load("templates/home.html", string),
	});
}

version :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set_unsafe(&res.headers, "cache-control", "no-store");
	http.respond_plain(res, GIT_SHA);
}

Static_File :: struct {
	path:         string,
	content_type: string,
	data:         []byte,
}

// A file added to static/ is served once
STATIC_FILES :: [?]Static_File{
	{"/static/css/style.css",                      "text/css; charset=utf-8", #load("../../static/css/style.css")},
	{"/static/fonts/jbmono-nl-nerd-regular.woff2", "font/woff2",              #load("../../static/fonts/jbmono-nl-nerd-regular.woff2")},
	{"/static/fonts/jbmono-nl-nerd-bold.woff2",    "font/woff2",              #load("../../static/fonts/jbmono-nl-nerd-bold.woff2")},
	{"/static/fonts/jbmono-nl-nerd-italic.woff2",  "font/woff2",              #load("../../static/fonts/jbmono-nl-nerd-italic.woff2")},
}

static :: proc(req: ^http.Request, res: ^http.Response) {
	for file in STATIC_FILES {
		if file.path != req.url.path {
			continue;
		}
		res.status = .OK;
		http.headers_set_content_type(&res.headers, file.content_type);
		http.body_set(res, file.data);
		http.respond(res);
		return;
	}
	http.respond(res, http.Status.Not_Found);
}
