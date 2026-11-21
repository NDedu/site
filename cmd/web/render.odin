package main

import "base:runtime"
import "core:encoding/entity"
import "core:fmt"
import "core:reflect"
import "core:strings"
import http "../../odin-http"

LAYOUT :: #load("templates/template.html", string)

DEFAULT_TITLE :: "Narcis Dedu"

// What templates read. Syntax:
//   {{name}}               field, escaped (Html fields aren't). {{a.b}} for a nested field
//   {{#name}}...{{/name}}  shown if name is set: true, not empty, not 0, not nil. Repeated for each item of a list.
//                          Inside a list, pointer or struct section, names are looked up on the item first
//   {{^name}}...{{/name}}  shown if name isn't set
//   {{.}}                  the current item
//   {{content}}            the page's template
//   {{/static/...}}        static file URL with ?v=<hash>
//   {{value x}}            value of form input x, also {{error x}} and {{invalid x}}
Page :: struct {
	title:       string, // DEFAULT_TITLE if empty
	description: string,
	status:      Status,
	path:        string, // set by render_page, e.g. ~/login
	content:     string,
	form:        Form,
}

// Not escaped. Only for HTML the site generates, like rendered Markdown, never user input
Html :: distinct string

// Written lowercase in templates: none, ok, warn, error
Status :: enum {
	None, // nothing to report
	Ok,
	Warn, // partly worked, or failed but not because of bad input
	Error,
}

Form :: struct {
	message: string, // form-wide error, e.g. wrong password
	csrf:    string,
	inputs:  []Input,
}

Input :: struct {
	name:  string,
	value: string, // never set for passwords
	error: string,
}

render :: proc(req: ^http.Request, res: ^http.Response, page: Page, http_status := http.Status.OK) {
	// temp_allocator is freed after the response is sent
	http.respond_html(res, render_page(LAYOUT, page, req.url.path, context.temp_allocator), http_status);
}

render_page :: proc(layout: string, page: Page, url_path: string, allocator := context.allocator) -> string {
	page := page;
	if page.title == "" {
		page.title = DEFAULT_TITLE;
	}
	page.path = strings.concatenate({"~", strings.trim_right(url_path, "/")}, context.temp_allocator);
	return render_template(layout, page, allocator);
}

render_template :: proc(template: string, data: any, allocator := context.allocator) -> string {
	out := strings.builder_make(0, 2 * len(template) + 1024, allocator);
	root := Scope{value = data};
	write_template(&out, template, &root);
	return strings.to_string(out);
}

Scope :: struct {
	value:  any,
	parent: ^Scope,
}

// Values are never scanned for placeholders, so they can't inject one
write_template :: proc(out: ^strings.Builder, template: string, scope: ^Scope, in_content := false) {
	rest := template;
	for before, name in next_placeholder(&rest) {
		strings.write_string(out, before);
		if strings.has_prefix(name, "#") || strings.has_prefix(name, "^") {
			body, closed := cut_section(&rest, name[1:]);
			value, found, _ := lookup(scope, name[1:]);
			if !closed || !found {
				// Keep the tag and hide the body, so a typo can't leak role-only content
				write_placeholder(out, name);
				if !closed {
					return;
				}
				continue;
			}
			write_section(out, body, scope, value, name[0] == '^', in_content);
			continue;
		}
		if write_input(out, scope, name) || write_static_url(out, name) {
			continue;
		}
		value, found, at_root := lookup(scope, name);
		switch {
		case !found || !is_text(value.id):
			write_placeholder(out, name); // left in so the typo shows on the page
		case at_root && name == "content":
			if in_content {
				write_placeholder(out, name); // would recurse forever
			} else {
				write_template(out, (^string)(value.data)^, scope, in_content = true);
			}
		case:
			write_value(out, value);
		}
	}
	strings.write_string(out, rest);
}

write_section :: proc(out: ^strings.Builder, body: string, scope: ^Scope, value: any, inverted, in_content: bool) {
	items, count, stride, item, goes_in := section_items(value);
	switch {
	case inverted:
		if !is_set(value) {
			write_template(out, body, scope, in_content);
		}
	case goes_in:
		for i in 0..<count {
			inner := Scope{value = to_any(rawptr(uintptr(items) + uintptr(i * stride)), item), parent = scope};
			write_template(out, body, &inner, in_content);
		}
	case is_set(value):
		write_template(out, body, scope, in_content);
	}
}

// What a section loops over: list items, a pointer's target or the struct itself. goes_in is false for plain conditions
section_items :: proc(value: any) -> (items: rawptr, count, stride: int, item: typeid, goes_in: bool) {
	#partial switch info in reflect.type_info_base(type_info_of(value.id)).variant {
	case runtime.Type_Info_Slice:
		if raw := (^runtime.Raw_Slice)(value.data); raw != nil {
			items, count = raw.data, raw.len;
		}
		return items, count, info.elem_size, info.elem.id, true;
	case runtime.Type_Info_Dynamic_Array:
		if raw := (^runtime.Raw_Dynamic_Array)(value.data); raw != nil {
			items, count = raw.data, raw.len;
		}
		return items, count, info.elem_size, info.elem.id, true;
	case runtime.Type_Info_Pointer:
		if info.elem == nil {
			return; // rawptr has no item type
		}
		if pointer := (^rawptr)(value.data); pointer != nil && pointer^ != nil {
			items, count = pointer^, 1;
		}
		return items, count, 0, info.elem.id, true;
	case runtime.Type_Info_Struct:
		return value.data, 1 if value.data != nil else 0, 0, value.id, true;
	}
	return;
}

is_set :: proc(value: any) -> bool {
	if value.data == nil {
		return false; // behind a nil pointer
	}
	#partial switch info in reflect.type_info_base(type_info_of(value.id)).variant {
	case runtime.Type_Info_String:
		if !info.is_cstring {
			return (^runtime.Raw_String)(value.data).len > 0;
		}
	case runtime.Type_Info_Slice:
		return (^runtime.Raw_Slice)(value.data).len > 0;
	case runtime.Type_Info_Dynamic_Array:
		return (^runtime.Raw_Dynamic_Array)(value.data).len > 0;
	}
	return !reflect.is_nil(value); // is_nil is true when every byte is zero
}

// at_root: found on the page itself, not on a section's item
lookup :: proc(scope: ^Scope, name: string) -> (value: any, found, at_root: bool) {
	if name == "." {
		return scope.value, true, scope.parent == nil;
	}
	first, _, rest := strings.partition(name, ".");
	for s := scope; s != nil && !found; s = s.parent {
		value, found = field_of(s.value, first);
		at_root = s.parent == nil;
	}
	for found && rest != "" {
		next: string;
		next, _, rest = strings.partition(rest, ".");
		value, found = field_of(value, next);
	}
	return;
}

// Follows pointers. Behind a nil pointer the field is still found, with nil data
field_of :: proc(value: any, name: string) -> (field: any, found: bool) {
	value := value;
	if info, ok := reflect.type_info_base(type_info_of(value.id)).variant.(runtime.Type_Info_Pointer); ok && info.elem != nil {
		value = to_any((^rawptr)(value.data)^ if value.data != nil else nil, info.elem.id);
	}
	f := reflect.struct_field_by_name(value.id, name);
	if f.type == nil {
		return;
	}
	return to_any(rawptr(uintptr(value.data) + f.offset) if value.data != nil else nil, f.type.id), true;
}

is_text :: proc(id: typeid) -> bool {
	#partial switch info in reflect.type_info_base(type_info_of(id)).variant {
	case runtime.Type_Info_String:
		return !info.is_cstring && info.encoding == .UTF_8;
	case runtime.Type_Info_Enum, runtime.Type_Info_Integer, runtime.Type_Info_Float, runtime.Type_Info_Boolean:
		return true;
	}
	return false;
}

write_value :: proc(out: ^strings.Builder, value: any) {
	if value.data == nil {
		return;
	}
	if value.id == Html {
		strings.write_string(out, string((^Html)(value.data)^));
		return;
	}
	#partial switch _ in reflect.type_info_base(type_info_of(value.id)).variant {
	case runtime.Type_Info_String:
		write_text(out, (^string)(value.data)^);
	case runtime.Type_Info_Enum:
		for c in transmute([]byte)reflect.enum_string(value) {
			strings.write_byte(out, c + ('a' - 'A') if 'A' <= c && c <= 'Z' else c);
		}
	case:
		fmt.sbprint(out, value);
	}
}

to_any :: proc(data: rawptr, id: typeid) -> any {
	return transmute(any)runtime.Raw_Any{data = data, id = id};
}

// Iterator: the text before the next {{name}}, and name. Moves rest past it
next_placeholder :: proc(rest: ^string) -> (before, name: string, ok: bool) {
	text := rest^;
	from := 0;
	for {
		// index_byte is much faster than strings.index(text, "{{")
		brace := strings.index_byte(text[from:], '{');
		if brace < 0 {
			return;
		}
		open_idx := from + brace;
		if open_idx + 1 < len(text) && text[open_idx + 1] == '{' {
			close_idx := strings.index(text[open_idx + 2:], "}}");
			if close_idx < 0 {
				return;
			}
			close_idx += open_idx + 2;
			rest^ = text[close_idx + 2:];
			return text[:open_idx], text[open_idx + 2:close_idx], true;
		}
		from = open_idx + 1; // single {, e.g. in JS
	}
}

// Cuts the body and its {{/name}} off rest. Nested sections with the same name stay in the body
cut_section :: proc(rest: ^string, name: string) -> (body: string, closed: bool) {
	text := rest^;
	scan := text;
	depth := 1;
	for _, tag in next_placeholder(&scan) {
		if len(tag) < 2 || tag[1:] != name {
			continue;
		}
		switch tag[0] {
		case '#', '^':
			depth += 1;
		case '/':
			depth -= 1;
			if depth == 0 {
				rest^ = scan;
				return text[:len(text) - len(scan) - len(tag) - len("{{}}")], true;
			}
		}
	}
	return;
}

write_placeholder :: proc(out: ^strings.Builder, name: string) {
	strings.write_string(out, "{{");
	strings.write_string(out, name);
	strings.write_string(out, "}}");
}

// "error email" -> "error", "email"
input_placeholder :: proc(placeholder: string) -> (what, name: string, ok: bool) {
	what, _, name = strings.partition(placeholder, " ");
	ok = name != "" && (what == "value" || what == "error" || what == "invalid");
	return;
}

// An input that wasn't sent back renders empty
write_input :: proc(out: ^strings.Builder, scope: ^Scope, placeholder: string) -> bool {
	what, name, ok := input_placeholder(placeholder);
	if !ok {
		return false;
	}
	input: Input;
	if form, found, _ := lookup(scope, "form"); found && form.id == Form && form.data != nil {
		for sent in (^Form)(form.data).inputs {
			if sent.name == name {
				input = sent;
				break;
			}
		}
	}
	switch what {
	case "value":   write_text(out, input.value);
	case "error":   write_text(out, input.error);
	case "invalid": strings.write_string(out, "true" if input.error != "" else "false");
	}
	return true;
}

// /static/css/style.css -> /static/css/style.css?v=<crc32>, so the URL changes with the file
write_static_url :: proc(out: ^strings.Builder, path: string) -> bool {
	version, ok := static_version(path);
	if !ok {
		return false;
	}
	strings.write_string(out, path);
	strings.write_string(out, "?v=");
	strings.write_u64(out, u64(version), 16);
	return true;
}

write_text :: proc(out: ^strings.Builder, text: string) {
	escaped, _ := entity.escape_html(text, context.temp_allocator);
	strings.write_string(out, escaped);
}
