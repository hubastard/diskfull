#+build darwin, linux
package diskfull

import "core:strings"
import "core:sync"
import "core:sys/posix"

path_id :: proc(path: string) -> (id: File_Id, ok: bool) {
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK {
		return
	}
	return {u64(st.st_dev), u64(st.st_ino)}, true
}

scan_dir :: proc(w: ^Worker, dir: ^Node, path: ^[dynamic]u8, entries, subdirs: ^[dynamic]^Node) {
	s := w.scanner
	begin_dir(w, dir, path, entries, subdirs)

	// opendir rather than open(O_DIRECTORY | O_NOFOLLOW): core:sys/posix has the
	// x86 values of those flags on every Linux architecture, which breaks arm64.
	// Only entries that lstat says are real directories get here anyway.
	dirp := posix.opendir(strings.clone_to_cstring(string(path[:]), context.temp_allocator))
	if dirp == nil {
		mark_denied(s, dir)
		return
	}
	defer posix.closedir(dirp)
	fd := posix.dirfd(dirp)

	dir_st: posix.stat_t
	posix.fstat(fd, &dir_st)

	for {
		ent := posix.readdir(dirp)
		if ent == nil {
			break
		}
		cname := cstring(&ent.d_name[0])
		name := string(cname)
		if name == "." || name == ".." {
			continue
		}
		st: posix.stat_t
		if posix.fstatat(fd, cname, &st, {.SYMLINK_NOFOLLOW}) != .OK {
			continue
		}
		bytes := i64(st.st_blocks) * 512 // allocated size, so sparse files count for what they use

		if posix.S_ISDIR(st.st_mode) {
			if st.st_dev != dir_st.st_dev && !mount_allowed(s, u64(st.st_dev), string(path[:]), name) {
				continue // another disk, a network share, a pseudo filesystem...
			}
			if !mark_seen(s, &s.seen_dirs, {u64(st.st_dev), u64(st.st_ino)}) {
				continue // bind mount, firmlink or other alias of a directory we already have
			}
			if skip_dir_entry(fd, cname, &st) {
				continue
			}
			child := add_child(w, dir, name, bytes, {.Dir}, entries)
			if scan_last(string(path[:]), name) {
				defer_dir(s, child)
			} else {
				append(subdirs, child)
			}
		} else {
			if st.st_nlink > 1 && !mark_seen(s, &s.seen_files, {u64(st.st_dev), u64(st.st_ino)}) {
				continue // hard link to a file already counted
			}
			flags: Node_Flags
			bytes, flags = adjust_file(s, fd, cname, &st, bytes)
			add_child(w, dir, name, bytes, flags, entries)
		}
	}
	end_dir(w, dir, entries)
}

// A mount point is followed only if it is backed by the same storage as the
// scan root (same APFS container, same block device, same zfs pool), i.e. it
// eats the same disk space.
@(private = "file")
mount_allowed :: proc(s: ^Scanner, dev: u64, dir_path: string, name: string) -> bool {
	sync.mutex_lock(&s.seen_mutex)
	if allowed, ok := s.devices[dev]; ok {
		sync.mutex_unlock(&s.seen_mutex)
		return allowed
	}
	sync.mutex_unlock(&s.seen_mutex)

	full := strings.concatenate({dir_path, "/" if dir_path != "/" else "", name}, context.temp_allocator)
	allowed := false
	if info, ok := volume_info(strings.clone_to_cstring(full, context.temp_allocator)); ok {
		allowed = s.root_container != "" && info.container == s.root_container
	}

	sync.mutex_lock(&s.seen_mutex)
	s.devices[dev] = allowed
	sync.mutex_unlock(&s.seen_mutex)
	return allowed
}
