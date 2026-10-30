#+build darwin, linux
package diskfull

import "core:c/libc"
import "core:strings"
import "core:sys/posix"

PATH_SEP :: '/'

absolute_path :: proc(path: string) -> string {
	real := posix.realpath(strings.clone_to_cstring(path, context.temp_allocator))
	if real == nil {
		return path
	}
	defer libc.free(rawptr(real))
	return strings.clone(string(real), context.temp_allocator)
}

ignore_child_exits :: proc() {
	// Let the kernel reap spawned children so they never become zombies.
	posix.sigignore(.SIGCHLD)
}

// Starts a program (looked up in PATH) without waiting for it.
run_detached :: proc(args: ..string) {
	argv := make([dynamic]cstring, context.temp_allocator)
	for a in args {
		append(&argv, strings.clone_to_cstring(a, context.temp_allocator))
	}
	append(&argv, nil)
	pid: posix.pid_t
	posix.posix_spawnp(&pid, argv[0], nil, nil, raw_data(argv), posix.environ)
}
