package main

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_render_page_fills_the_placeholders :: proc(t: ^testing.T) {
	layout := `<title>{{title}}</title><meta content="{{description}}"><main>{{content}}</main>{{path}}`;
	page := Page{title = "T", description = "D", content = "<p>C</p>"};
	testing.expect_value(t, render_page(layout, page, "/", context.temp_allocator), `<title>T</title><meta content="D"><main><p>C</p></main>~`);
}

@(test)
test_render_page_defaults_the_title :: proc(t: ^testing.T) {
	testing.expect_value(t, render_page("{{title}}", Page{}, "/", context.temp_allocator), DEFAULT_TITLE);
	testing.expect_value(t, render_page("{{title}}", Page{title = "cv"}, "/", context.temp_allocator), "cv");
}

@(test)
test_render_page_escapes_text_but_not_html :: proc(t: ^testing.T) {
	page := Page{
		title       = `<b>"Tom" & 'Jerry'</b>`,
		description = `a "quote"`,
		content     = `<p class="x">&amp;</p><script>if (a < b) {}</script>`,
	};
	got := render_page("{{title}}|{{description}}|{{content}}", page, "/", context.temp_allocator);
	testing.expect_value(t, got, `&lt;b&gt;&#34;Tom&#34; &amp; &#39;Jerry&#39;&lt;/b&gt;|a &#34;quote&#34;|<p class="x">&amp;</p><script>if (a < b) {}</script>`);
}

@(test)
test_render_page_shows_the_path_as_a_shell_path :: proc(t: ^testing.T) {
	Case :: struct {
		url_path, want: string,
	};
	cases := [?]Case{
		{"/", "~"},
		{"", "~"},
		{"/cv", "~/cv"},
		{"/cv/", "~/cv"},
		{"/blog/<i>", "~/blog/&lt;i&gt;"},
	};
	for c in cases {
		got := render_page("{{path}}", Page{}, c.url_path, context.temp_allocator);
		testing.expectf(t, got == c.want, "%q: got %q, want %q", c.url_path, got, c.want);
	}
}

@(test)
test_render_page_shows_the_status :: proc(t: ^testing.T) {
	testing.expect_value(t, render_page("{{status}}", Page{}, "/", context.temp_allocator), "none");
	testing.expect_value(t, render_page("{{status}}", Page{status = .Ok}, "/", context.temp_allocator), "ok");
	testing.expect_value(t, render_page("{{status}}", Page{status = .Warn}, "/", context.temp_allocator), "warn");
	testing.expect_value(t, render_page("{{status}}", Page{status = .Error}, "/", context.temp_allocator), "error");
}

// The startup hash against the compiler's #load_hash
@(test)
test_render_page_versions_static_files :: proc(t: ^testing.T) {
	got := render_page(`<script defer src="{{/static/js/template.js}}"></script>`, Page{}, "/", context.temp_allocator);
	want := fmt.tprintf(`<script defer src="/static/js/template.js?v=%x"></script>`, #load_hash("../../static/js/template.js", "crc32"));
	testing.expect_value(t, got, want);
	// Unknown file, left in like a typo
	testing.expect_value(t, render_page("{{/static/js/nope.js}}", Page{}, "/", context.temp_allocator), "{{/static/js/nope.js}}");
}

// Values aren't scanned again, and the content can't include itself
@(test)
test_render_page_fills_the_content :: proc(t: ^testing.T) {
	page := Page{title = "{{status}}", content = "<h1>{{title}}</h1>{{content}}"};
	testing.expect_value(t, render_page("<main>{{content}}</main>", page, "/", context.temp_allocator), "<main><h1>{{status}}</h1>{{content}}</main>");
}

// The page's template reads data's names before the page's, the layout doesn't see them
@(test)
test_render_page_reads_data_in_the_content :: proc(t: ^testing.T) {
	page := Page{
		title   = "T",
		status  = .Ok,
		content = "{{title}} {{status}}{{#posts}} {{title}}{{/posts}}",
		data    = struct { title: string, posts: []Test_Post }{title = "D", posts = {{title = "p"}}},
	};
	testing.expect_value(t, render_page("{{title}} {{posts}}|{{content}}", page, "/", context.temp_allocator), "T {{posts}}|D ok p");
	// Behind a nil pointer it's all empty
	user: ^Test_User;
	page = Page{content = "[{{name}}]{{#name}}x{{/name}}", data = user};
	testing.expect_value(t, render_page("{{content}}", page, "/", context.temp_allocator), "[]");
}

@(test)
test_render_page_leaves_unknown_and_unclosed_placeholders :: proc(t: ^testing.T) {
	page := Page{title = "T"};
	testing.expect_value(t, render_page("a {{nope}} b", page, "/", context.temp_allocator), "a {{nope}} b");
	testing.expect_value(t, render_page("{{title}} {{title", page, "/", context.temp_allocator), "T {{title");
	testing.expect_value(t, render_page("{{value}} {{nope email}}", page, "/", context.temp_allocator), "{{value}} {{nope email}}");
}

// Single braces, like in JS
@(test)
test_render_page_leaves_single_braces :: proc(t: ^testing.T) {
	page := Page{title = "T"};
	testing.expect_value(t, render_page("if (a) { b(); } {{title}} {c} {", page, "/", context.temp_allocator), "if (a) { b(); } T {c} {");
}

// Catches a typo in template.html, like {{tittle}}
@(test)
test_layout_has_only_known_placeholders :: proc(t: ^testing.T) {
	got := render_page(LAYOUT, Page{}, "/", context.temp_allocator);
	if idx := strings.index(got, "{{"); idx >= 0 {
		testing.expectf(t, false, "template.html has a placeholder render_page leaves in: %q", got[idx:min(idx + 32, len(got))]);
	}
}

@(test)
test_render_page_fills_a_blank_form :: proc(t: ^testing.T) {
	template := "{{status}}|{{form.message}}|{{csrf}}|{{value email}}|{{error email}}|{{invalid email}}";
	testing.expect_value(t, render_page(template, Page{}, "/", context.temp_allocator), "none|||||false");
}

// Password has no error, repeat wasn't sent back
@(test)
test_render_page_escapes_and_marks_form_errors :: proc(t: ^testing.T) {
	page := Page{
		status = .Error,
		form   = {
			message = `wrong "email" or password`,
			inputs  = {{name = "email", value = "<a>@b.c", error = "not a valid email address"}, {name = "password"}},
		},
	};
	got := render_page("{{status}}|{{form.message}}|{{value email}}|{{error email}}|{{invalid email}}|{{invalid password}}|{{error repeat}}", page, "/", context.temp_allocator);
	testing.expect_value(t, got, "error|wrong &#34;email&#34; or password|&lt;a&gt;@b.c|not a valid email address|true|false|");
}

// Catches typos like {{error emial}}, which render empty instead of staying in the page
@(test)
test_templates_name_their_inputs :: proc(t: ^testing.T) {
	files := #load_directory("templates");
	for file in files {
		template := string(file.data);
		rest := template;
		for _, name in next_placeholder(&rest) {
			what, _, input := strings.partition(name, " ");
			if input == "" || (what != "value" && what != "error" && what != "invalid") {
				continue;
			}
			attr := strings.concatenate({`name="`, input, `"`}, context.temp_allocator);
			testing.expectf(t, strings.contains(template, attr), "%s: %q is for an input with %s, and there's none", file.name, name, attr);
		}
	}
}

// Stand-in for Page in the section tests
Test_Data :: struct {
	title:  string,
	admin:  bool,
	count:  int,
	status: Status,
	posts:  []Test_Post,
	user:   ^Test_User,
	form:   Form,
	body:   Html,
}

Test_Post :: struct {
	title: string,
	tags:  []string,
}

Test_User :: struct {
	name: string,
}

@(test)
test_render_template_shows_a_section_if_its_field_is_set :: proc(t: ^testing.T) {
	template := "{{#admin}}admin{{/admin}}{{^admin}}user{{/admin}}|{{#title}}[{{title}}]{{/title}}|{{#count}}{{count}}{{/count}}|{{#status}}{{status}}{{/status}}";
	testing.expect_value(t, render_template(template, Test_Data{}, context.temp_allocator), "user|||");
	set := Test_Data{admin = true, title = "<T>", count = 3, status = .Warn};
	testing.expect_value(t, render_template(template, set, context.temp_allocator), "admin|[&lt;T&gt;]|3|warn");
	// Nested, same name
	testing.expect_value(t, render_template("{{#admin}}a{{#admin}}b{{/admin}}{{/admin}}", set, context.temp_allocator), "ab");
}

@(test)
test_render_template_repeats_a_section_for_each_item :: proc(t: ^testing.T) {
	template := "<ul>{{#posts}}<li>{{title}}:{{#tags}} {{.}}{{/tags}}</li>{{/posts}}{{^posts}}<li>none</li>{{/posts}}</ul>";
	posts := []Test_Post{{title = "a", tags = {"x", "<y>"}}, {title = "b"}};
	testing.expect_value(t, render_template(template, Test_Data{posts = posts}, context.temp_allocator), "<ul><li>a: x &lt;y&gt;</li><li>b:</li></ul>");
	testing.expect_value(t, render_template(template, Test_Data{}, context.temp_allocator), "<ul><li>none</li></ul>");
}

// Inside a section the item's fields come first, then the page's
@(test)
test_render_template_reads_the_page_inside_a_section :: proc(t: ^testing.T) {
	data := Test_Data{title = "page", admin = true, form = {message = "m"}, posts = []Test_Post{{title = "a"}, {title = "b"}}};
	testing.expect_value(t, render_template("{{#posts}}{{title}} {{form.message}}{{#admin}} edit{{/admin}}|{{/posts}}", data, context.temp_allocator), "a m edit|b m edit|");
}

@(test)
test_render_template_goes_into_a_pointer :: proc(t: ^testing.T) {
	template := "{{#user}}hi {{name}}{{/user}}{{^user}}sign in{{/user}}|{{user.name}}";
	testing.expect_value(t, render_template(template, Test_Data{}, context.temp_allocator), "sign in|");
	user := Test_User{name = "N"};
	testing.expect_value(t, render_template(template, Test_Data{user = &user}, context.temp_allocator), "hi N|N");
}

// Html isn't escaped, and like any value isn't scanned for placeholders
@(test)
test_render_template_writes_html_as_it_is :: proc(t: ^testing.T) {
	data := Test_Data{title = "<b>", body = "<p>{{title}} &amp; more</p>"};
	testing.expect_value(t, render_template("{{title}}|{{body}}|{{#body}}has a body{{/body}}", data, context.temp_allocator), "&lt;b&gt;|<p>{{title}} &amp; more</p>|has a body");
}

// A broken section stays in as a tag and its body is hidden
@(test)
test_render_template_hides_a_broken_section :: proc(t: ^testing.T) {
	data := Test_Data{admin = true};
	testing.expect_value(t, render_template("a{{#admni}}secret{{/admni}}b", data, context.temp_allocator), "a{{#admni}}b");
	testing.expect_value(t, render_template("a{{#admin}}secret", data, context.temp_allocator), "a{{#admin}}");
	testing.expect_value(t, render_template("a{{/admin}}b", data, context.temp_allocator), "a{{/admin}}b");
	// A list isn't text
	testing.expect_value(t, render_template("{{posts}}", data, context.temp_allocator), "{{posts}}");
}

// Every name in every template exists, also inside sections the page tests never render,
// and Html fields are only used between tags. data's type isn't known here, so in a page's
// template a name that isn't the page's counts as data's
@(test)
test_templates_use_known_names :: proc(t: ^testing.T) {
	files := #load_directory("templates");
	for file in files {
		name, why := unknown_name(string(file.data), Page, has_data = file.name != "template.html");
		testing.expectf(t, why == "", "%s: %q %s", file.name, name, why);
	}
}

@(test)
test_unknown_name_finds_each_mistake :: proc(t: ^testing.T) {
	mistakes := [?]string{
		"{{tittle}}",
		"{{#admin}}{{tittle}}{{/admin}}", // hidden when admin is false
		"{{tags}}",                       // a post's field, outside its section
		"{{posts}}",                      // a list isn't text
		"{{#admin}}",
		"{{/admin}}",
		"{{#admin}}{{#posts}}{{/admin}}{{/posts}}",
		"{{/static/nope.css}}",
		"{{}}",
		`<p title="{{body}}">`, // Html in an attribute: its quotes would end it
	};
	for template in mistakes {
		_, why := unknown_name(template, Test_Data);
		testing.expectf(t, why != "", "%q isn't caught", template);
	}
	fine := "{{title}}{{#posts}}{{title}}{{#tags}}{{.}}{{/tags}}{{/posts}}{{^posts}}{{count}}{{/posts}}" +
		"{{#user}}{{name}}{{/user}}{{user.name}}{{form.message}}{{value email}}{{/static/css/style.css}}<div>{{body}}</div>";
	name, why := unknown_name(fine, Test_Data);
	testing.expectf(t, why == "", "%q %s", name, why);
}

// The rest is still checked
@(test)
test_unknown_name_takes_other_names_as_data :: proc(t: ^testing.T) {
	fine := "{{reviews}}{{#reviews}}{{rating}}{{#tags}}{{.}}{{/tags}}{{title}}{{/reviews}}{{^reviews}}{{count}}{{/reviews}}";
	name, why := unknown_name(fine, Test_Data, has_data = true);
	testing.expectf(t, why == "", "%q %s", name, why);
	mistakes := [?]string{
		"{{posts}}",
		"{{#reviews}}",
		"{{#reviews}}{{/static/nope.css}}{{/reviews}}",
	};
	for template in mistakes {
		_, why = unknown_name(template, Test_Data, has_data = true);
		testing.expectf(t, why != "", "%q isn't caught", template);
	}
}

// The first name render wouldn't know and why, why is "" if there's none.
// With has_data, names that aren't fields count as data's, and so does what's inside their sections
unknown_name :: proc(template: string, root: typeid, has_data := false) -> (name, why: string) {
	scope := Scope{value = to_any(nil, root)};
	html: Html_Scan;
	return unknown_name_in(template, &scope, &html, has_data);
}

// html is the HTML state where template starts, and is moved past it
unknown_name_in :: proc(template: string, scope: ^Scope, html: ^Html_Scan, has_data: bool) -> (name, why: string) {
	rest := template;
	for before, placeholder in next_placeholder(&rest) {
		scan_html(html, before);
		name = placeholder;
		switch {
		case name == "":
			return name, "is empty";
		case name[0] == '#' || name[0] == '^':
			body, closed := cut_section(&rest, name[1:]);
			if !closed {
				return name, "isn't closed";
			}
			value, found, _ := lookup(scope, name[1:]);
			if !found && !has_data {
				return name, "isn't a field, of the page or of an item around it";
			}
			// Inside, names are looked up on the item. A data item's type isn't known, it stays nil
			_, _, _, item, goes_in := section_items(value);
			inner := Scope{value = to_any(nil, item), parent = scope};
			inner_name, inner_why := unknown_name_in(body, &inner if (goes_in || !found) && name[0] == '#' else scope, html, has_data);
			if inner_why != "" {
				return inner_name, inner_why;
			}
		case strings.has_prefix(name, "/static/"):
			if _, ok := static_version(name); !ok {
				return name, "isn't served: not in static/, or its folder isn't in static_folders";
			}
		case name[0] == '/':
			return name, "closes a section that isn't open";
		case:
			if _, _, ok := input_placeholder(name); ok {
				continue;
			}
			value, found, _ := lookup(scope, name);
			if has_data && (!found || value.id == nil) {
				continue; // data's, or {{.}} of a data item
			}
			if !found {
				return name, "isn't a field, of the page or of an item around it";
			}
			if !is_text(value.id) {
				return name, "is a list or a struct, not text: it goes in a section, as in {{#name}}...{{/name}}";
			}
			if value.id == Html && html.spot != .Text {
				return name, "is Html, which only goes between tags";
			}
		}
	}
	scan_html(html, rest);
	return "", "";
}

// Escaping only covers text and quoted attribute values, anywhere else a value could become code
@(test)
test_templates_put_placeholders_where_escaping_works :: proc(t: ^testing.T) {
	files := #load_directory("templates");
	for file in files {
		name, why := unsafe_placeholder(string(file.data));
		testing.expectf(t, why == "", "%s: %q %s", file.name, name, why);
	}
}

@(test)
test_unsafe_placeholder_finds_each_unsafe_spot :: proc(t: ^testing.T) {
	unsafe := [?]string{
		`<script>let email = "{{value email}}";</script>`,
		`<style>p { color: {{title}} }</style>`,
		`<p onclick="say('{{title}}')">`,
		`<p style="color: {{title}}">`,
		`<p class={{title}}>`,
		`<{{title}}>`,
		`<a href="{{value site}}">`,
		`<a href="/{{value site}}">`,         // could be //evil.test
		`<a href="https://x.test/{{title}}">`, // only paths on this site
		`<script src="/js/{{title}}">`,       // only href can have a value after a path
		`<!-- {{title}} -->`,
		`<p class="{{#admin}}a">{{/admin}}`, // opens in a value and closes outside it
	};
	for template in unsafe {
		_, why := unsafe_placeholder(template);
		testing.expectf(t, why != "", "%q isn't caught", template);
	}
	// Quotes and tags that don't start or end anything, placeholders after a script ends,
	// and sections that close where they open
	safe := `<!doctype html><!-- <p> --><link href="data:,<svg a='b'>"><script>let p = "<p class=";</script>` +
		`<p class="{{status}}" data-x='{{title}}'>{{title}}</p><script defer src="{{/static/js/template.js}}"></script>{{title}}` +
		`{{#admin}}<b>{{title}}</b>{{/admin}}<p {{#admin}}hidden{{/admin}}>{{#admin}}<script>let a = 1;</script>{{/admin}}` +
		`<a href="/posts/{{title}}">{{title}}</a><a href='/search?q={{value q}}&page={{count}}'>`;
	name, why := unsafe_placeholder(safe);
	testing.expectf(t, why == "", "%q %s", name, why);
}

// The first placeholder where escaping isn't enough and why, why is "" if there's none
unsafe_placeholder :: proc(template: string) -> (name, why: string) {
	html: Html_Scan;
	opened: [16]Html_Scan; // the HTML state where each open section started
	depth := 0;
	rest := template;
	for before, placeholder in next_placeholder(&rest) {
		scan_html(&html, before);
		switch {
		case strings.has_prefix(placeholder, "#") || strings.has_prefix(placeholder, "^"):
			if depth == len(opened) {
				return placeholder, "is in too many sections for this test";
			}
			opened[depth] = html;
			depth += 1;
		case strings.has_prefix(placeholder, "/") && !strings.has_prefix(placeholder, "/static/"):
			// Must close in the same HTML state it opened in, or hiding it would change how the rest is read
			if depth > 0 {
				depth -= 1;
				if opened[depth] != html {
					return placeholder, "closes somewhere else in the HTML than its section opens";
				}
			}
		case:
			why = placeholder_risk(html, placeholder);
			if why != "" {
				return placeholder, why;
			}
		}
	}
	return;
}

Html_Spot :: enum {
	Text,  // between tags
	Tag,   // in a tag, outside quotes
	Value, // in a quoted attribute value
	Comment,
	Script,
	Style,
}

Html_Scan :: struct {
	spot:      Html_Spot,
	after_tag: Html_Spot, // spot after the tag's >: Script for <script>, Style for <style>, else Text
	quote:     byte,      // the quote that ends the value
	attribute: string,
	value:     string,    // the value's text up to the placeholder
}

scan_html :: proc(html: ^Html_Scan, text: string) {
	for i := 0; i < len(text); i += 1 {
		rest := text[i:];
		switch html.spot {
		case .Text:
			if strings.has_prefix(rest, "<!--") {
				html.spot = .Comment;
				i += len("<!--") - 1;
			} else if rest[0] == '<' && (len(rest) == 1 || starts_tag(rest[1])) {
				// A < right before a placeholder is a tag too, the value would be its name
				name := tag_name(rest[1:]);
				html.spot = .Tag;
				html.after_tag = .Text;
				if strings.equal_fold(name, "script") {
					html.after_tag = .Script;
				} else if strings.equal_fold(name, "style") {
					html.after_tag = .Style;
				}
			}
		case .Tag:
			switch rest[0] {
			case '>':
				html.spot = html.after_tag;
			case '"', '\'':
				html.spot = .Value;
				html.quote = rest[0];
				html.attribute = attribute_before(text[:i]);
				html.value = text[i + 1:];
			}
		case .Value:
			if rest[0] == html.quote {
				html.spot = .Tag;
			}
		case .Comment:
			if strings.has_prefix(rest, "-->") {
				html.spot = .Text;
				i += len("-->") - 1;
			}
		case .Script, .Style:
			end := "</script" if html.spot == .Script else "</style";
			if len(rest) >= len(end) && strings.equal_fold(rest[:len(end)], end) {
				html.spot = .Tag;
				html.after_tag = .Text;
				i += len(end) - 1;
			}
		}
	}
}

starts_tag :: proc(c: byte) -> bool {
	return ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || c == '/' || c == '!' || c == '?';
}

tag_name :: proc(text: string) -> string {
	end := strings.index_any(text, " \t\r\n/>");
	return text if end < 0 else text[:end];
}

// `<a href="` -> "href"
attribute_before :: proc(text: string) -> string {
	before := strings.trim_right_space(text);
	if !strings.has_suffix(before, "=") {
		return "";
	}
	before = strings.trim_right_space(before[:len(before) - 1]);
	return before[strings.last_index_any(before, " \t\r\n<") + 1:];
}

// Escaping doesn't stop a value in these from being a javascript: URL
URL_ATTRIBUTES :: [?]string{"href", "src", "srcset", "action", "formaction", "poster", "cite", "data", "ping"}

// Why escaping isn't enough at this spot, "" if it is. In URLs only {{/static/...}} is allowed,
// and in href a value after a path on this site, like /posts/
placeholder_risk :: proc(html: Html_Scan, placeholder: string) -> string {
	switch html.spot {
	case .Text:
		return "";
	case .Tag:
		return "is in a tag, outside a quoted value: a space in it would start another attribute";
	case .Comment:
		return "is in an HTML comment: it's filled anyway, and sent to the browser";
	case .Script:
		return "is in a <script>, where escaped text can still be code: put it in a data-* attribute for the script to read";
	case .Style:
		return "is in a <style>: escaping doesn't cover CSS";
	case .Value:
		attribute := html.attribute;
		if len(attribute) > 2 && strings.equal_fold(attribute[:2], "on") {
			return "is in an event handler: the browser unescapes it and runs it as JavaScript";
		}
		if strings.equal_fold(attribute, "style") {
			return "is in a style attribute: escaping doesn't cover CSS";
		}
		for url in URL_ATTRIBUTES {
			if !strings.equal_fold(attribute, url) || strings.has_prefix(placeholder, "/static/") {
				continue;
			}
			// Not after a bare / or //, that could become //evil.test
			value := html.value;
			if strings.equal_fold(attribute, "href") && len(value) >= 2 && value[0] == '/' && value[1] != '/' && value[1] != '\\' {
				continue;
			}
			return "is in a URL, which escaping doesn't make safe: in href it can follow a path on this site, as in /posts/, and only a {{/static/...}} goes anywhere else";
		}
	}
	return "";
}
