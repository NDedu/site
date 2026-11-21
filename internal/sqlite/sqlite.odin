package sqlite

import "base:runtime"
import "core:c"
import "core:slice"
import "core:strings"

when ODIN_OS == .Windows {
	foreign import sqlite3 "sqlite3.lib" // built from the sqlite3.c amalgamation
} else {
	foreign import sqlite3 "system:sqlite3"
}

// Opaque, only used through pointers
Database  :: struct {}
Statement :: struct {}

// Ok is 0, so step(...) or_return also returns on Row and Done: use next_row
Result :: enum c.int {
	Ok = 0, Error = 1, Internal = 2, Perm = 3, Abort = 4, Busy = 5, Locked = 6,
	No_Mem = 7, Read_Only = 8, Interrupt = 9, IO_Err = 10, Corrupt = 11,
	Not_Found = 12, Full = 13, Cant_Open = 14, Protocol = 15, Empty = 16,
	Schema = 17, Too_Big = 18, Constraint = 19, Mismatch = 20, Misuse = 21,
	No_LFS = 22, Auth = 23, Format = 24, Range = 25, Not_A_DB = 26,
	Notice = 27, Warning = 28,
	Row    = 100,
	Done   = 101,
}

// Bit positions, not values: SQLITE_OPEN_READWRITE is 0x2, so bit 1
Open_Flag :: enum c.int {
	Read_Only   = 0,
	Read_Write  = 1,
	Create      = 2,
	URI         = 6,
	Memory      = 7,
	No_Mutex    = 15,
	Full_Mutex  = 16,
	No_Follow   = 24,
	Ex_Res_Code = 25, // calls then return extended codes, which Result doesn't list
}
Open_Flags :: distinct bit_set[Open_Flag; c.int]

// From extended_errcode after .Constraint or .Busy. Primary code | sub-code << 8, e.g. 2067 = 19 | 8 << 8
Extended_Result :: enum c.int {
	Constraint_Check       = 275,
	Busy_Snapshot          = 517,
	Constraint_Foreign_Key = 787,
	Constraint_Not_Null    = 1299,
	Constraint_Primary_Key = 1555,
	Constraint_Unique      = 2067,
}

Column_Type :: enum c.int {
	Integer = 1,
	Float   = 2,
	Text    = 3,
	Blob    = 4,
	Null    = 5,
}

Config_Option :: enum c.int {
	Memstatus = 9, // c.int, 0 turns off memory statistics
}

// Destructor argument of bind_text and bind_blob
STATIC    :: uintptr(0)  // SQLite keeps the pointer, the bytes must outlive the binding
TRANSIENT :: ~uintptr(0) // SQLite copies the bytes

@(default_calling_convention = "c", link_prefix = "sqlite3_")
foreign sqlite3 {
	libversion        :: proc() -> cstring ---
	// Only before SQLite is first used (.Misuse after), and not while another thread uses it
	config            :: proc(option: Config_Option, #c_vararg args: ..any) -> Result ---
	threadsafe        :: proc() -> c.int --- // 0 if built without mutexes
	free              :: proc(ptr: rawptr) --- // for exec's error message
	open_v2           :: proc(filename: cstring, database: ^^Database, flags: Open_Flags, vfs: cstring) -> Result ---
	close_v2          :: proc(database: ^Database) -> Result ---
	close             :: proc(database: ^Database) -> Result --- // .Busy while a statement is alive, unlike close_v2
	extended_errcode  :: proc(database: ^Database) -> Extended_Result ---
	errmsg            :: proc(database: ^Database) -> cstring ---
	busy_timeout      :: proc(database: ^Database, milliseconds: c.int) -> Result ---
	exec              :: proc(database: ^Database, sql: cstring, callback: rawptr, user_data: rawptr, error_message: ^cstring) -> Result ---
	last_insert_rowid :: proc(database: ^Database) -> i64 ---
	changes           :: proc(database: ^Database) -> c.int ---

	prepare_v2        :: proc(database: ^Database, sql: [^]byte, byte_count: c.int, statement: ^^Statement, tail: ^[^]byte) -> Result ---
	step              :: proc(statement: ^Statement) -> Result ---
	reset             :: proc(statement: ^Statement) -> Result ---
	clear_bindings    :: proc(statement: ^Statement) -> Result ---
	finalize          :: proc(statement: ^Statement) -> Result ---

	bind_int64        :: proc(statement: ^Statement, index: c.int, value: i64) -> Result ---
	bind_double       :: proc(statement: ^Statement, index: c.int, value: f64) -> Result ---
	bind_null         :: proc(statement: ^Statement, index: c.int) -> Result ---
	bind_text         :: proc(statement: ^Statement, index: c.int, text: [^]byte, byte_count: c.int, destructor: uintptr) -> Result ---
	bind_blob         :: proc(statement: ^Statement, index: c.int, data: rawptr, byte_count: c.int, destructor: uintptr) -> Result ---

	column_type       :: proc(statement: ^Statement, column: c.int) -> Column_Type ---
	column_int64      :: proc(statement: ^Statement, column: c.int) -> i64 ---
	column_double     :: proc(statement: ^Statement, column: c.int) -> f64 ---
	column_text       :: proc(statement: ^Statement, column: c.int) -> [^]byte ---
	column_blob       :: proc(statement: ^Statement, column: c.int) -> [^]byte ---
	column_bytes      :: proc(statement: ^Statement, column: c.int) -> c.int ---
}

// SQLite returns a handle even when opening fails, and it still has to be closed
open :: proc(path: cstring, flags: Open_Flags = {.Read_Write, .Create}) -> (database: ^Database, result: Result) {
	result = open_v2(path, &database, flags, nil)
	if result != .Ok {
		close_v2(database)
		database = nil
	}
	return
}

// With the byte length, sql doesn't need a NUL terminator
prepare :: proc(database: ^Database, sql: string) -> (statement: ^Statement, result: Result) {
	if len(sql) > int(max(c.int)) {
		return nil, .Too_Big
	}
	result = prepare_v2(database, raw_data(sql), c.int(len(sql)), &statement, nil)
	return
}

// step, with Row and Done turned into has_row so or_return only returns on errors
//
//	for sqlite.next_row(statement) or_return { ... } // SELECT
//	sqlite.next_row(statement) or_return             // INSERT, UPDATE, DELETE
next_row :: proc(statement: ^Statement) -> (has_row: bool, result: Result) {
	#partial switch code := step(statement); code {
	case .Row:
		return true, .Ok
	case .Done:
		return false, .Ok
	case:
		return false, code
	}
}

@(private, rodata)
EMPTY_TEXT := [1]byte{0}

// index starts at 1. An empty Odin string can have a nil pointer, which SQLite stores as NULL instead of ''
bind_string :: proc(statement: ^Statement, index: c.int, value: string) -> Result {
	if len(value) > int(max(c.int)) {
		return .Too_Big
	}
	data := raw_data(value)
	if data == nil {
		data = &EMPTY_TEXT[0]
	}
	return bind_text(statement, index, data, c.int(len(value)), TRANSIENT)
}

// Same nil pointer problem as bind_string
bind_bytes :: proc(statement: ^Statement, index: c.int, value: []byte) -> Result {
	if len(value) > int(max(c.int)) {
		return .Too_Big
	}
	data := raw_data(value)
	if data == nil {
		data = &EMPTY_TEXT[0]
	}
	return bind_blob(statement, index, data, c.int(len(value)), TRANSIENT)
}

// Copied, SQLite's pointer is only valid until the next step, reset or finalize. NULL comes back as ""
column_string :: proc(statement: ^Statement, column: c.int, allocator := context.allocator) -> (value: string, err: runtime.Allocator_Error) #optional_allocator_error {
	text  := column_text(statement, column) // column_text before column_bytes, as SQLite's docs say
	count := column_bytes(statement, column)
	if text == nil {
		return "", nil
	}
	return strings.clone(string(text[:count]), allocator)
}

// Copied like column_string. NULL and empty blobs both come back as nil
column_bytes_copy :: proc(statement: ^Statement, column: c.int, allocator := context.allocator) -> (value: []byte, err: runtime.Allocator_Error) #optional_allocator_error {
	data  := column_blob(statement, column)
	count := column_bytes(statement, column)
	if data == nil || count == 0 {
		return nil, nil
	}
	return slice.clone(data[:count], allocator)
}
