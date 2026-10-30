package diskfull

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Node_Flag :: enum u8 {
	Dir,
	Denied,    // directory exists but could not be opened (permissions)
	Clone,     // macOS: APFS clone of a file seen elsewhere, only its private bytes are counted
	Purgeable, // macOS: the system may delete it by itself when space runs low
}
Node_Flags :: bit_set[Node_Flag; u8]

Node :: struct {
	name:     string, // NUL-terminated in memory, so cstring(raw_data(name)) is valid
	parent:   ^Node,
	children: []^Node, // sorted by size, biggest first, once the scan is done (see live_children)
	size:     i64, // bytes allocated on disk, summed for directories; grows during the scan
	files:    i64, // number of files in the subtree; grows during the scan
	flags:    Node_Flags,
}

// Identifies a file or directory across hard links and path aliases.
File_Id :: struct {
	dev: u64,
	ino: u64,
}

Worker :: struct {
	scanner: ^Scanner,
	arena:   virtual.Arena,
	thread:  ^thread.Thread,
}

Scanner :: struct {
	root_path:      string,
	root:           ^Node,
	root_container: string, // only mounts backed by the same storage are followed (see volume_info)
	arena:          virtual.Arena,

	mutex:          sync.Mutex,
	cond:           sync.Cond,
	queue:          [dynamic]^Node,
	deferred:       [dynamic]^Node,
	active:         int,

	seen_mutex:     sync.Mutex,
	seen_dirs:      map[File_Id]struct{},
	seen_files:     map[File_Id]struct{},
	seen_clones:    map[File_Id]struct{}, // ino holds the APFS clone id
	devices:        map[u64]bool,         // mount point device -> followed?

	workers:        []Worker,
	coordinator:    ^thread.Thread,
	start:          time.Tick,

	// Progress, read by the UI thread with atomics.
	files:          i64,
	dirs:           i64,
	bytes:          i64,
	denied:         i64,
	purgeable:      i64,
	current:        ^Node,
	cancel:         bool,
	done:           bool,
	elapsed:        time.Duration,
}

scanner_start :: proc(root_path: string) -> ^Scanner {
	s := new(Scanner)
	s.root_path = strings.clone(root_path)
	s.start = time.tick_now()

	alloc := virtual.arena_allocator(&s.arena)
	s.root = new(Node, alloc)
	s.root.name = clone_name(root_path, alloc)
	s.root.flags = {.Dir}

	cpath := strings.clone_to_cstring(root_path, context.temp_allocator)
	if info, ok := volume_info(cpath); ok {
		s.root_container = strings.clone(info.container)
	}
	if id, ok := path_id(root_path); ok {
		s.seen_dirs[id] = {}
	}
	append(&s.queue, s.root)

	n := clamp(os.get_processor_core_count(), 4, 16)
	s.workers = make([]Worker, n)
	for &w in s.workers {
		w.scanner = s
		w.thread = thread.create_and_start_with_poly_data(&w, worker_proc)
	}
	s.coordinator = thread.create_and_start_with_poly_data(s, coordinator_proc)
	return s
}

scanner_destroy :: proc(s: ^Scanner) {
	sync.atomic_store(&s.cancel, true)
	sync.mutex_lock(&s.mutex)
	sync.cond_broadcast(&s.cond)
	sync.mutex_unlock(&s.mutex)
	thread.join(s.coordinator)
	thread.destroy(s.coordinator)
	for &w in s.workers {
		thread.destroy(w.thread)
		virtual.arena_destroy(&w.arena)
	}
	delete(s.workers)
	delete(s.queue)
	delete(s.deferred)
	delete(s.seen_dirs)
	delete(s.seen_files)
	delete(s.seen_clones)
	delete(s.devices)
	delete(s.root_path)
	delete(s.root_container)
	virtual.arena_destroy(&s.arena)
	free(s)
}

scanner_done :: proc(s: ^Scanner) -> bool {
	return sync.atomic_load(&s.done)
}

@(private = "file")
coordinator_proc :: proc(s: ^Scanner) {
	for &w in s.workers {
		thread.join(w.thread)
	}
	if sync.atomic_load(&s.cancel) {
		return
	}
	sort_tree(s.root)
	s.elapsed = time.tick_since(s.start)
	sync.atomic_store(&s.done, true)
}

// Sizes are final once every directory is scanned (end_dir adds them up the
// tree as it goes): sort children biggest first.
@(private = "file")
sort_tree :: proc(n: ^Node) {
	for c in n.children {
		if .Dir in c.flags {
			sort_tree(c)
		}
	}
	slice.sort_by(n.children, proc(a, b: ^Node) -> bool {return a.size > b.size})
}

// The UI reads the tree while the scan builds it, through these.

live_children :: proc(n: ^Node) -> []^Node {
	raw := (^runtime.Raw_Slice)(&n.children)
	count := sync.atomic_load_explicit(&raw.len, .Acquire)
	return ([^]^Node)(raw.data)[:count]
}

node_size :: proc(n: ^Node) -> i64 {
	return sync.atomic_load_explicit(&n.size, .Relaxed)
}

node_files :: proc(n: ^Node) -> i64 {
	return sync.atomic_load_explicit(&n.files, .Relaxed)
}

@(private = "file")
worker_proc :: proc(w: ^Worker) {
	s := w.scanner
	path: [dynamic]u8
	entries: [dynamic]^Node
	subdirs: [dynamic]^Node
	defer delete(path)
	defer delete(entries)
	defer delete(subdirs)

	for {
		sync.mutex_lock(&s.mutex)
		for len(s.queue) == 0 && !sync.atomic_load(&s.cancel) {
			if s.active == 0 {
				// Everything reachable has been scanned. Now walk the deferred
				// directories: anything already seen through a firmlink is skipped.
				if len(s.deferred) == 0 {
					break
				}
				append(&s.queue, ..s.deferred[:])
				clear(&s.deferred)
				sync.cond_broadcast(&s.cond)
				break
			}
			sync.cond_wait(&s.cond, &s.mutex)
		}
		if len(s.queue) == 0 || sync.atomic_load(&s.cancel) {
			sync.cond_broadcast(&s.cond)
			sync.mutex_unlock(&s.mutex)
			return
		}
		dir := pop(&s.queue)
		s.active += 1
		sync.mutex_unlock(&s.mutex)

		scan_dir(w, dir, &path, &entries, &subdirs)
		free_all(context.temp_allocator)

		sync.mutex_lock(&s.mutex)
		s.active -= 1
		append(&s.queue, ..subdirs[:])
		sync.cond_broadcast(&s.cond)
		sync.mutex_unlock(&s.mutex)
	}
}

// Called by each platform's scan_dir before reading `dir`; leaves its path in `path`.
begin_dir :: proc(w: ^Worker, dir: ^Node, path: ^[dynamic]u8, entries, subdirs: ^[dynamic]^Node) {
	clear(entries)
	clear(subdirs)
	sync.atomic_store(&w.scanner.current, dir)
	sync.atomic_add(&w.scanner.dirs, 1)
	clear(path)
	append_node_path(path, dir)
}

end_dir :: proc(w: ^Worker, dir: ^Node, entries: ^[dynamic]^Node) {
	children := slice.clone(entries[:], virtual.arena_allocator(&w.arena))
	// Publish the children: the length is stored last, so a reader that sees
	// it (live_children) also sees the elements.
	raw := (^runtime.Raw_Slice)(&dir.children)
	raw.data = raw_data(children)
	sync.atomic_store_explicit(&raw.len, len(children), .Release)

	// Add what this directory directly holds to it and every ancestor, so sizes
	// are right during the scan too. Subdirectories are scanned after this
	// returns and add their own contents the same way.
	bytes, files: i64
	for c in children {
		bytes += c.size
		files += c.files
	}
	for a := dir; a != nil; a = a.parent {
		sync.atomic_add(&a.size, bytes)
		sync.atomic_add(&a.files, files)
	}
}

mark_denied :: proc(s: ^Scanner, dir: ^Node) {
	dir.flags += {.Denied}
	sync.atomic_add(&s.denied, 1)
}

add_child :: proc(w: ^Worker, parent: ^Node, name: string, size: i64, flags: Node_Flags, entries: ^[dynamic]^Node) -> ^Node {
	alloc := virtual.arena_allocator(&w.arena)
	child := new(Node, alloc)
	child.name = clone_name(name, alloc)
	child.parent = parent
	child.size = size
	child.flags = flags
	if .Dir not_in flags {
		child.files = 1
		sync.atomic_add(&w.scanner.files, 1)
		sync.atomic_add(&w.scanner.bytes, size)
	}
	append(entries, child)
	return child
}

defer_dir :: proc(s: ^Scanner, dir: ^Node) {
	sync.mutex_lock(&s.mutex)
	append(&s.deferred, dir)
	sync.mutex_unlock(&s.mutex)
}

// Returns false if `key` was already in the set.
mark_seen :: proc(s: ^Scanner, set: ^map[File_Id]struct{}, key: File_Id) -> bool {
	sync.mutex_lock(&s.seen_mutex)
	defer sync.mutex_unlock(&s.seen_mutex)
	if key in set {
		return false
	}
	set[key] = {}
	return true
}

clone_name :: proc(name: string, alloc := context.allocator) -> string {
	buf := make([]u8, len(name) + 1, alloc)
	copy(buf, name)
	return string(buf[:len(name)])
}

append_node_path :: proc(buf: ^[dynamic]u8, n: ^Node) {
	if n.parent == nil {
		append(buf, n.name)
		return
	}
	append_node_path(buf, n.parent)
	if len(buf) == 0 || buf[len(buf) - 1] != PATH_SEP {
		append(buf, PATH_SEP)
	}
	append(buf, n.name)
}

node_path :: proc(n: ^Node, allocator := context.temp_allocator) -> string {
	buf := make([dynamic]u8, allocator)
	append_node_path(&buf, n)
	return string(buf[:])
}

node_is_ancestor :: proc(ancestor, n: ^Node) -> bool {
	for p := n; p != nil; p = p.parent {
		if p == ancestor {
			return true
		}
	}
	return false
}
