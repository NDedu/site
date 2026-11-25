package dotenv

import "core:os"
import "core:strings"
import "core:testing"

// parse_line unescapes in place, so it gets a copy
parse :: proc(line: string) -> (key, value: string, ok, is_empty: bool) {
	return parse_line(transmute([]u8)strings.clone(line, context.temp_allocator))
}

@(test)
test_parse_line_skips_blank_lines_and_comments :: proc(t: ^testing.T) {
	lines := []string{"", "   ", "\t", "# comment", "   # indented comment"}
	for line in lines {
		_, _, ok, is_empty := parse(line)
		testing.expectf(t, ok && is_empty, "%q: ok %v, empty %v", line, ok, is_empty)
	}
}

@(test)
test_parse_line_values :: proc(t: ^testing.T) {
	Case :: struct {
		line, key, value: string,
	}
	cases := [?]Case{
		{"KEY=value", "KEY", "value"},
		{"  KEY  =  value  ", "KEY", "value"},
		{"export KEY=value", "KEY", "value"},
		{"lower.dotted_key1=value", "lower.dotted_key1", "value"},
		{"KEY=", "KEY", ""},
		{"KEY= # only a comment", "KEY", ""},
		{"KEY=value # comment", "KEY", "value"},
		{"KEY=a#b", "KEY", "a#b"},
		{"KEY=a=b", "KEY", "a=b"},
		{"KEY='a # b' # comment", "KEY", "a # b"},
		{`KEY='a\nb'`, "KEY", `a\nb`},
		{`KEY=""`, "KEY", ""},
		{`KEY="a\nb\tc\rd"`, "KEY", "a\nb\tc\rd"},
		{`KEY="say \"hi\" \\ \q"`, "KEY", `say "hi" \ q`},
		{`KEY="a # b" # comment`, "KEY", "a # b"},
	}
	for c in cases {
		key, value, ok, is_empty := parse(c.line)
		testing.expectf(t, ok && !is_empty && key == c.key && value == c.value,
			"%q: got key %q value %q (ok %v, empty %v), want key %q value %q", c.line, key, value, ok, is_empty, c.key, c.value)
	}
}

@(test)
test_parse_line_rejects_malformed_lines :: proc(t: ^testing.T) {
	lines := []string{
		"no equals sign",
		"=value",
		"KEY WITH SPACES=value",
		"KEY-DASH=value",
		`KEY='unterminated`,
		`KEY="unterminated`,
		`KEY="ends in a backslash\`,
		`KEY='value' trailing`,
		`KEY="value" trailing`,
	}
	for line in lines {
		_, _, ok, _ := parse(line)
		testing.expectf(t, !ok, "%q: accepted", line)
	}
}

@(test)
test_load_missing_file :: proc(t: ^testing.T) {
	line, err := load("/nonexistent/dotenv-test/.env", context.temp_allocator)
	testing.expect_value(t, err, Error.Not_Found)
	testing.expect_value(t, line, 0)
}

@(test)
test_load_unreadable :: proc(t: ^testing.T) {
	dir, ok := make_temp_dir(t)
	if !ok {
		return
	}
	defer os.remove_all(dir)

	line, err := load(dir, context.temp_allocator) // a directory
	testing.expect_value(t, err, Error.Unreadable)
	testing.expect_value(t, line, 0)
}

@(test)
test_load_sets_variables_but_keeps_existing_ones :: proc(t: ^testing.T) {
	dir, ok := make_temp_dir(t)
	if !ok {
		return
	}
	defer os.remove_all(dir)
	defer {
		os.unset_env("DOTENV_TEST_NEW")
		os.unset_env("DOTENV_TEST_KEPT")
		os.unset_env("DOTENV_TEST_QUOTED")
		os.unset_env("DOTENV_TEST_CRLF")
	}

	os.set_env("DOTENV_TEST_KEPT", "from the environment")
	path := write_file(t, dir, ".env",
		"# comment\n\nDOTENV_TEST_NEW=from the file\nDOTENV_TEST_KEPT=from the file\nexport DOTENV_TEST_QUOTED=\"two\\nlines\"\nDOTENV_TEST_CRLF=crlf\r\n")

	line, err := load(path, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, line, 0)
	expect_env(t, "DOTENV_TEST_NEW", "from the file")
	expect_env(t, "DOTENV_TEST_KEPT", "from the environment")
	expect_env(t, "DOTENV_TEST_QUOTED", "two\nlines")
	expect_env(t, "DOTENV_TEST_CRLF", "crlf")
}

@(test)
test_load_stops_at_a_syntax_error :: proc(t: ^testing.T) {
	dir, ok := make_temp_dir(t)
	if !ok {
		return
	}
	defer os.remove_all(dir)
	defer {
		os.unset_env("DOTENV_TEST_BEFORE_ERROR")
		os.unset_env("DOTENV_TEST_AFTER_ERROR")
	}

	path := write_file(t, dir, ".env", "DOTENV_TEST_BEFORE_ERROR=1\n\nnot a valid line\nDOTENV_TEST_AFTER_ERROR=1\n")

	line, err := load(path, context.temp_allocator)
	testing.expect_value(t, err, Error.Syntax)
	testing.expect_value(t, line, 3)
	_, after_set := os.lookup_env("DOTENV_TEST_AFTER_ERROR", context.temp_allocator)
	testing.expect(t, !after_set, "kept going after the error")
}

make_temp_dir :: proc(t: ^testing.T) -> (dir: string, ok: bool) {
	err: os.Error
	dir, err = os.make_directory_temp("", "dotenv-test-*", context.temp_allocator)
	return dir, testing.expectf(t, err == nil, "making a temp dir: %v", err)
}

write_file :: proc(t: ^testing.T, dir, name, content: string) -> (path: string) {
	path = strings.concatenate({dir, "/", name}, context.temp_allocator)
	err := os.write_entire_file(path, content)
	testing.expectf(t, err == nil, "writing %s: %v", path, err)
	return
}

expect_env :: proc(t: ^testing.T, key, want: string, loc := #caller_location) {
	value, found := os.lookup_env(key, context.temp_allocator)
	testing.expectf(t, found && value == want, "%s is %q (set: %v), want %q", key, value, found, want, loc = loc)
}
