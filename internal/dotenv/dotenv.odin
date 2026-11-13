// Loads a .env file into the environment
package dotenv

import "base:runtime"
import "core:os"
import "core:strings"

Error :: enum {
    None,
	Not_Found,
	Unreadable,
	Syntax,
	Environment,
}

load :: proc(path: string, scratch: runtime.Allocator) -> (line_number: int, err: Error) {
	data, read_err := os.read_entire_file(path, scratch);
	if read_err == .Not_Exist {
		return 0, .Not_Found;
	}
	if read_err != nil {
		return 0, .Unreadable;
	}

	content := string(data);
	for line in strings.split_lines_iterator(&content) {
		line_number += 1;
		key, value, line_ok, is_empty := parse_line(transmute([]u8)line);
		if is_empty {
			continue;
		}
		if !line_ok {
			return line_number, .Syntax;
		}
		if _, exists := os.lookup_env(key, scratch); exists {
			continue;
		}
		if os.set_env(key, value) != nil {
			return line_number, .Environment;
		}
	}
	return 0, .None;
}

@(private)
parse_line :: proc(raw: []u8) -> (key, value: string, ok, is_empty: bool) {
	line := strings.trim_space(string(raw));
	if line == "" || line[0] == '#' {
		return "", "", true, true;
	}
	line = strings.trim_prefix(line, "export ");

	eq_idx := strings.index_byte(line, '=');
	if eq_idx <= 0 {
		return;
	}
	key = strings.trim_space(line[:eq_idx]);
	if key == "" {
		return;
	}
	for char in transmute([]u8)key {
		if !(char == '_' || char == '.' || (char >= '0' && char <= '9') || (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z')) {
			return;
		}
	}

	after_eq := line[eq_idx + 1:]; // untrimmed, so `KEY= # note` keeps the space before its #
	rest := strings.trim_space(after_eq);
	switch {
	case rest == "":
		return key, "", true, false;

	case rest[0] == '\'':
		end_idx := strings.index_byte(rest[1:], '\'');
		if end_idx < 0 || !is_blank_or_comment(rest[end_idx + 2:]) {
			return;
		}
		return key, rest[1:end_idx + 1], true, false;

	case rest[0] == '"':
		buffer := transmute([]u8)rest;
		write_idx := 1;
		for read_idx := 1; read_idx < len(buffer); read_idx += 1 {
			char := buffer[read_idx];
			switch char {
			case '"':
				if !is_blank_or_comment(rest[read_idx + 1:]) {
					return;
				}
				return key, rest[1:write_idx], true, false;
			case '\\':
				read_idx += 1;
				if read_idx >= len(buffer) {
					return;
				}
				switch buffer[read_idx] {
				case 'n': char = '\n';
				case 't': char = '\t';
				case 'r': char = '\r';
				case:     char = buffer[read_idx]; // \" \\ and anything else: the character itself
				}
			}
			buffer[write_idx] = char;
			write_idx += 1;
		}
		return; // no closing quote

	case:
		if comment_idx := strings.index(after_eq, " #"); comment_idx >= 0 {
			after_eq = after_eq[:comment_idx];
		}
		return key, strings.trim_space(after_eq), true, false;
	}
}

// After a closing quote, only whitespace or a comment may follow
@(private)
is_blank_or_comment :: proc(tail: string) -> bool {
	trimmed := strings.trim_space(tail);
	return trimmed == "" || trimmed[0] == '#';
}
