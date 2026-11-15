package main

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_render_page_fills_the_placeholders :: proc(t: ^testing.T) {
	layout := `<title>{{title}}</title><meta content="{{description}}"><link href="/s.css?v={{css_version}}"><main>{{content}}</main>{{path}}{{scripts}}`;
	page := Page{title = "T", description = "D", content = "<p>C</p>", scripts = `<script src="/s.js"></script>`};

	got := render_page(layout, page, "/", context.temp_allocator);
	want := fmt.tprintf(`<title>T</title><meta content="D"><link href="/s.css?v=%x"><main><p>C</p></main>~<script src="/s.js"></script>`, CSS_VERSION);
	testing.expect_value(t, got, want);
}

@(test)
test_render_page_escapes_text_but_not_html :: proc(t: ^testing.T) {
	page := Page{
		title       = `<b>"Tom" & 'Jerry'</b>`,
		description = `a "quote"`,
		content     = `<p class="x">&amp;</p>`,
		scripts     = `<script>if (a < b) {}</script>`,
	};
	got := render_page("{{title}}|{{description}}|{{content}}|{{scripts}}", page, "/", context.temp_allocator);
	testing.expect_value(t, got, `&lt;b&gt;&#34;Tom&#34; &amp; &#39;Jerry&#39;&lt;/b&gt;|a &#34;quote&#34;|<p class="x">&amp;</p>|<script>if (a < b) {}</script>`);
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
test_render_page_leaves_placeholders_inside_content :: proc(t: ^testing.T) {
	got := render_page("{{content}}", Page{title = "T", content = "{{title}}"}, "/", context.temp_allocator);
	testing.expect_value(t, got, "{{title}}");
}

@(test)
test_render_page_leaves_unknown_and_unclosed_placeholders :: proc(t: ^testing.T) {
	page := Page{title = "T"};
	testing.expect_value(t, render_page("a {{nope}} b", page, "/", context.temp_allocator), "a {{nope}} b");
	testing.expect_value(t, render_page("{{title}} {{title", page, "/", context.temp_allocator), "T {{title");
}

// Catches a typo in template.html, like {{tittle}}
@(test)
test_layout_has_only_known_placeholders :: proc(t: ^testing.T) {
	got := render_page(LAYOUT, Page{}, "/", context.temp_allocator);
	if idx := strings.index(got, "{{"); idx >= 0 {
		testing.expectf(t, false, "template.html has a placeholder render_page leaves in: %q", got[idx:min(idx + 32, len(got))]);
	}
}
