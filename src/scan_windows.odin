#+build windows
package diskfull

import "core:strings"
import win "core:sys/windows"

// Returned by GetFileInformationByHandleEx(FileIdBothDirectoryInfo): one call
// lists many entries with their on-disk size and file id, no per-file syscall.
@(private = "file")
FILE_ID_BOTH_DIR_INFO :: struct {
	NextEntryOffset: u32,
	FileIndex:       u32,
	CreationTime:    i64,
	LastAccessTime:  i64,
	LastWriteTime:   i64,
	ChangeTime:      i64,
	EndOfFile:       i64,
	AllocationSize:  i64,
	FileAttributes:  u32,
	FileNameLength:  u32, // in bytes
	EaSize:          u32, // the reparse tag, for reparse points
	ShortNameLength: i8,
	ShortName:       [12]u16,
	FileId:          i64,
	FileName:        [1]u16,
}
#assert(offset_of(FILE_ID_BOTH_DIR_INFO, FileId) == 96)
#assert(offset_of(FILE_ID_BOTH_DIR_INFO, FileName) == 104)

@(private = "file")
ERROR_NO_MORE_FILES :: 18

// Directories are never reached twice on Windows: junctions and symlinks are skipped.
path_id :: proc(path: string) -> (id: File_Id, ok: bool) {
	return
}

scan_dir :: proc(w: ^Worker, dir: ^Node, path: ^[dynamic]u8, entries, subdirs: ^[dynamic]^Node) {
	s := w.scanner
	begin_dir(w, dir, path, entries, subdirs)

	wpath := win.utf8_to_wstring(long_path(string(path[:])), context.temp_allocator)
	share := win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE
	h := win.CreateFileW(wpath, win.FILE_LIST_DIRECTORY, share, nil, win.OPEN_EXISTING, win.FILE_FLAG_BACKUP_SEMANTICS, nil)
	if h == win.INVALID_HANDLE_VALUE {
		mark_denied(s, dir)
		return
	}
	defer win.CloseHandle(h)

	buf: [8 * 1024]u64 // 64 KiB, 8-byte aligned
	class := win.FILE_INFO_BY_HANDLE_CLASS.FileIdBothDirectoryRestartInfo
	listed := false
	for win.GetFileInformationByHandleEx(h, class, &buf, size_of(buf)) {
		class = .FileIdBothDirectoryInfo
		listed = true
		bytes := ([^]u8)(&buf)
		off := 0
		for {
			info := (^FILE_ID_BOTH_DIR_INFO)(&bytes[off])
			add_entry(w, dir, info, entries, subdirs)
			if info.NextEntryOffset == 0 {
				break
			}
			off += int(info.NextEntryOffset)
		}
	}
	if !listed && win.GetLastError() != ERROR_NO_MORE_FILES {
		mark_denied(s, dir)
	}
	end_dir(w, dir, entries)
}

@(private = "file")
add_entry :: proc(w: ^Worker, dir: ^Node, info: ^FILE_ID_BOTH_DIR_INFO, entries, subdirs: ^[dynamic]^Node) {
	name16 := ([^]u16)(&info.FileName)[:info.FileNameLength / 2]
	name, err := win.utf16_to_utf8(name16, context.temp_allocator)
	if err != nil || name == "." || name == ".." {
		return
	}
	attrs := info.FileAttributes
	if attrs & win.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		tag := info.EaSize
		if tag == win.IO_REPARSE_TAG_MOUNT_POINT || tag == win.IO_REPARSE_TAG_SYMLINK {
			return // junctions, mounted volumes and symlinks: counted elsewhere, or another disk
		}
	}
	if attrs & win.FILE_ATTRIBUTE_DIRECTORY != 0 {
		append(subdirs, add_child(w, dir, name, 0, {.Dir}, entries))
		return
	}
	// AllocationSize is what the file takes on disk: compressed and sparse files
	// count for less, online-only OneDrive files for nothing.
	size := info.AllocationSize
	if size > 0 && !mark_seen(w.scanner, &w.scanner.seen_files, {0, u64(info.FileId)}) {
		return // hard link to a file already counted (WinSxS <-> System32, pnpm stores...)
	}
	add_child(w, dir, name, size, {}, entries)
}

// The \\?\ prefix lifts the 260 character MAX_PATH limit.
@(private = "file")
long_path :: proc(path: string) -> string {
	switch {
	case strings.has_prefix(path, `\\?\`):
		return path
	case strings.has_prefix(path, `\\`):
		return strings.concatenate({`\\?\UNC\`, path[2:]}, context.temp_allocator)
	}
	return strings.concatenate({`\\?\`, path}, context.temp_allocator)
}
