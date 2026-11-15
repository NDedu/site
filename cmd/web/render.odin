package main

import "core:encoding/entity"
import "core:strings"
import http "../../odin-http"

LAYOUT :: #load("templates/template.html", string)

// What goes into the layout's {{placeholders}}
Page :: struct {
	title:       string, // text: escaped
	description: string, // text: escaped
	content:     string, // HTML: goes in as it is
	scripts:     string, // HTML for the end of <body>: goes in as it is
}

render :: proc(req: ^http.Request, res: ^http.Response, page: Page) {
	// The request's temp allocator, freed once the response is sent
	out := strings.builder_make(0, len(LAYOUT) + len(page.content) + len(page.scripts) + 256, context.temp_allocator);

	rest := LAYOUT;
	for {
		open_idx := strings.index(rest, "{{");
		if open_idx < 0 {
			break;
		}
		close_idx := strings.index(rest[open_idx:], "}}");
		if close_idx < 0 {
			break;
		}
		close_idx += open_idx;

		strings.write_string(&out, rest[:open_idx]);
		name := rest[open_idx + 2:close_idx];
		switch name {
		case "title":       write_text(&out, page.title);
		case "description": write_text(&out, page.description);
		case "css_version": strings.write_string(&out, CSS_VERSION);
		case "content":     strings.write_string(&out, page.content);
		case "scripts":     strings.write_string(&out, page.scripts);
		case "path":
			// The URL as a shell path
			strings.write_byte(&out, '~');
			write_text(&out, strings.trim_right(req.url.path, "/"));
		case:
			strings.write_string(&out, rest[open_idx:close_idx + 2]); // unknown: left in, typo shows on the page
		}
		rest = rest[close_idx + 2:];
	}
	strings.write_string(&out, rest);

	http.respond_html(res, strings.to_string(out));
}

// Escapes & < > " '
write_text :: proc(out: ^strings.Builder, text: string) {
	escaped, _ := entity.escape_html(text, context.temp_allocator);
	strings.write_string(out, escaped);
}
