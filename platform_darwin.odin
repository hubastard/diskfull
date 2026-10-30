#+build darwin
package diskfull

import "base:intrinsics"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import rl "vendor:raylib"

FILE_MANAGER :: "Finder"
WINDOW_FLAGS :: rl.ConfigFlags{.WINDOW_RESIZABLE, .WINDOW_HIGHDPI, .MSAA_4X_HINT, .VSYNC_HINT}

FONT_CANDIDATES := [?]cstring {
	"/System/Library/Fonts/SFNS.ttf",
	"/System/Library/Fonts/Supplemental/Arial.ttf",
	"/Library/Fonts/Arial Unicode.ttf",
}

PERMISSION_HINT :: "For the complete picture, give your terminal Full Disk Access (System Settings › Privacy & Security › Full Disk Access), or run with sudo."
DENIED_HINT :: "Use Full Disk Access or sudo to see them."
HIDDEN_HINT :: "Hidden = space the scan cannot see: APFS snapshots (Time Machine, updates), purgeable files and unreadable folders. Check snapshots with: tmutil listlocalsnapshots /"

// What well-known space hogs are and what to do about them. First match wins,
// so more specific paths come first.
PLATFORM_NOTES := [?][2]string {
	{"/Library/Developer/Xcode/DerivedData/", "Xcode build cache. Safe to delete, Xcode rebuilds it."},
	{"/Library/Developer/Xcode/iOS DeviceSupport/", "Debug symbols for connected devices. Old iOS versions are safe to delete."},
	{"/Library/Developer/Xcode/Archives/", "Xcode archives of apps you built. Delete the ones you no longer need."},
	{"/Library/Developer/CoreSimulator/", "iOS simulators and their data. Clean up with: xcrun simctl delete unavailable"},
	{"/com.docker.docker/", "Docker's virtual machine disk. Free space with: docker system prune -a"},
	{"/.orbstack/", "OrbStack virtual machine data."},
	{"/MobileSync/Backup/", "iPhone/iPad backups. Manage them in Finder > your device > Manage Backups."},
	{"/.Trash/", "Trash. Empty it to get this space back."},
	{"/Library/Caches/Homebrew/", "Homebrew downloads. Clean up with: brew cleanup --prune=all"},
	{"/Library/Caches/", "Application caches. Usually safe to delete, apps recreate what they need."},
	{"/System/Volumes/VM/", "Swap files and sleep image, managed by macOS. Shrinks after a reboot."},
	{"/private/var/vm/", "Swap files and sleep image, managed by macOS. Shrinks after a reboot."},
	{"/private/var/folders/", "Per-user temporary files and caches. A reboot cleans part of it."},
	{"/.Spotlight-V100/", "Spotlight search index."},
	{"/.DocumentRevisions-V100/", "Document version history kept by macOS."},
	{"/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/", "iOS Simulator runtimes. Remove old ones in Xcode > Settings > Components."},
	{"/System/Library/AssetsV2/", "Assets downloaded by macOS: Apple Intelligence models, voices, fonts, updates."},
	{"/Library/Updates/", "Downloaded macOS updates."},
	{"/macOS Install Data/", "Leftovers from a macOS install or update."},
	{"/Library/Application Support/Steam/", "Steam games."},
	{".photoslibrary/", "Photos library. 'Optimize Mac Storage' in Photos settings keeps originals in iCloud only."},
	{"/Library/Mail/", "Mail messages and attachments."},
	{"/Library/Messages/", "Messages history and attachments."},
	{"/Library/Group Containers/", "Data shared between apps from the same developer."},
	{"/Library/Containers/", "Data of sandboxed apps."},
	{"/Library/Logs/", "Log files. Safe to delete."},
	{"/private/var/log/", "System logs."},
	{"/private/var/db/", "System databases, diagnostics and caches."},
	{"/Library/CloudStorage/", "Cloud drive files (Google Drive, Dropbox, OneDrive...) stored on this Mac."},
	{"/Library/Mobile Documents/", "iCloud Drive files stored on this Mac."},
	{"/Library/Application Support/", "Application data."},
}

default_root :: proc() -> string {
	return "/"
}

foreign import libc "system:System"

@(private = "file")
Statfs :: struct {
	f_bsize:       u32,
	f_iosize:      i32,
	f_blocks:      u64,
	f_bfree:       u64,
	f_bavail:      u64,
	f_files:       u64,
	f_ffree:       u64,
	f_fsid:        [2]i32,
	f_owner:       u32,
	f_type:        u32,
	f_flags:       u32,
	f_fssubtype:   u32,
	f_fstypename:  [16]u8,
	f_mntonname:   [1024]u8,
	f_mntfromname: [1024]u8,
	f_flags_ext:   u32,
	f_reserved:    [7]u32,
}

@(private = "file")
STATFS_NAME :: "statfs$INODE64" when ODIN_ARCH == .amd64 else "statfs"

@(private = "file")
foreign libc {
	@(link_name = STATFS_NAME)
	_statfs :: proc "c" (path: cstring, buf: ^Statfs) -> i32 ---
}

// Strings in the result point into a thread-local buffer; clone them to keep them.
// The container is the APFS container ("disk3" for "/dev/disk3s5"): all its
// volumes (System, Data, Preboot, VM...) share the same disk space.
volume_info :: proc(path: cstring) -> (info: Volume_Info, ok: bool) {
	@(thread_local) sf: Statfs
	if _statfs(path, &sf) != 0 {
		return {}, false
	}
	info.total = i64(sf.f_blocks) * i64(sf.f_bsize)
	info.free = i64(sf.f_bfree) * i64(sf.f_bsize)
	info.used = info.total - info.free
	info.mount = string(cstring(&sf.f_mntonname[0]))

	from := string(cstring(&sf.f_mntfromname[0]))
	if strings.has_prefix(from, "/dev/disk") {
		id := from[len("/dev/"):]
		end := len("disk")
		for end < len(id) && id[end] >= '0' && id[end] <= '9' {
			end += 1
		}
		info.container = id[:end]
	}
	return info, true
}

// `open -R` opens the enclosing folder in Finder with the item selected.
reveal_in_file_manager :: proc(path: string) {
	run_detached("/usr/bin/open", "-R", path)
}

open_folder :: proc(path: string) {
	run_detached("/usr/bin/open", path)
}

// Scanner hooks, see scan_posix.odin.

// A directory whose APFS object is a filesystem root, without being a mount
// point, is a graft: a disk image (e.g. a cryptex .dmg) shown in place. The
// .dmg itself is already counted.
skip_dir_entry :: proc(dirfd: posix.FD, name: cstring, st: ^posix.stat_t) -> bool {
	info, ok := apfs_info(dirfd, name)
	return ok && info.clone_id == APFS_ROOT_DIR_ID && st.st_ino != APFS_ROOT_DIR_ID
}

// The Data volume is mostly reachable through firmlinks (/Users,
// /Applications, ...). Scan it last so those keep their short paths.
scan_last :: proc(dir_path, name: string) -> bool {
	return name == "Data" && dir_path == "/System/Volumes"
}

// Smaller files are not checked for APFS clones / purgeability (it costs a syscall).
@(private = "file")
CLONE_CHECK_MIN :: 32 * 1024

// APFS clones share their data: count it once, and only the private bytes of
// the other copies.
adjust_file :: proc(s: ^Scanner, dirfd: posix.FD, name: cstring, st: ^posix.stat_t, bytes: i64) -> (size: i64, flags: Node_Flags) {
	size = bytes
	if bytes < CLONE_CHECK_MIN {
		return
	}
	info, ok := apfs_info(dirfd, name)
	if !ok {
		return
	}
	if info.ext_flags & EF_MAY_SHARE_BLOCKS != 0 && !mark_seen(s, &s.seen_clones, {u64(st.st_dev), info.clone_id}) {
		size = info.private_size
		flags += {.Clone}
	}
	if info.ext_flags & EF_IS_PURGEABLE != 0 {
		flags += {.Purgeable}
		sync.atomic_add(&s.purgeable, size)
	}
	return
}

@(private = "file")
Attrlist :: struct {
	bitmapcount: u16,
	reserved:    u16,
	commonattr:  u32,
	volattr:     u32,
	dirattr:     u32,
	fileattr:    u32,
	forkattr:    u32,
}

@(private = "file")
foreign libc {
	getattrlistat :: proc "c" (fd: posix.FD, path: cstring, attrs: ^Attrlist, buf: rawptr, size: uint, options: uint) -> i32 ---
}

// <sys/attr.h>
@(private = "file") ATTR_BIT_MAP_COUNT :: 5
@(private = "file") ATTR_CMN_RETURNED_ATTRS :: 0x80000000
@(private = "file") ATTR_CMNEXT_PRIVATESIZE :: 0x8
@(private = "file") ATTR_CMNEXT_CLONEID :: 0x100
@(private = "file") ATTR_CMNEXT_EXT_FLAGS :: 0x200
@(private = "file") FSOPT_NOFOLLOW :: 0x1
@(private = "file") FSOPT_ATTR_CMN_EXTENDED :: 0x20

EF_MAY_SHARE_BLOCKS :: 0x1
EF_IS_PURGEABLE :: 0x8

APFS_ROOT_DIR_ID :: 2

Apfs_Info :: struct {
	private_size: i64, // bytes not shared with any clone
	clone_id:     u64, // identical for pure clones; APFS object id otherwise
	ext_flags:    u64,
}

apfs_info :: proc(dirfd: posix.FD, name: cstring) -> (info: Apfs_Info, ok: bool) {
	al := Attrlist {
		bitmapcount = ATTR_BIT_MAP_COUNT,
		commonattr  = ATTR_CMN_RETURNED_ATTRS,
		forkattr    = ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS,
	}
	buf: [64]u8
	if getattrlistat(dirfd, name, &al, &buf[0], len(buf), FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED) != 0 {
		return {}, false
	}
	// u32 length, attribute_set_t (5 x u32), then the requested attributes in bit order.
	returned := intrinsics.unaligned_load((^[5]u32)(&buf[4]))[4]
	off := 24
	read_u64 :: proc(buf: []u8, off: ^int) -> u64 {
		v := intrinsics.unaligned_load((^u64)(&buf[off^]))
		off^ += 8
		return v
	}
	if returned & ATTR_CMNEXT_PRIVATESIZE != 0 {
		info.private_size = i64(read_u64(buf[:], &off))
	}
	if returned & ATTR_CMNEXT_CLONEID == 0 {
		return {}, false
	}
	info.clone_id = read_u64(buf[:], &off)
	if returned & ATTR_CMNEXT_EXT_FLAGS != 0 {
		info.ext_flags = read_u64(buf[:], &off)
	}
	return info, true
}

foreign import core_foundation "system:CoreFoundation.framework"

@(private = "file")
CFStringRef :: distinct rawptr

@(private = "file")
kCFStringEncodingUTF8 :: 0x08000100

@(private = "file")
kCFStringNormalizationFormC :: 2

@(private = "file")
foreign core_foundation {
	CFStringCreateWithBytes :: proc "c" (alloc: rawptr, bytes: [^]u8, num_bytes: int, encoding: u32, is_external: b8) -> CFStringRef ---
	CFStringCreateMutableCopy :: proc "c" (alloc: rawptr, max_length: int, s: CFStringRef) -> CFStringRef ---
	CFStringNormalize :: proc "c" (s: CFStringRef, form: int) ---
	CFStringGetLength :: proc "c" (s: CFStringRef) -> int ---
	CFStringGetMaximumSizeForEncoding :: proc "c" (length: int, encoding: u32) -> int ---
	CFStringGetCString :: proc "c" (s: CFStringRef, buffer: [^]u8, buffer_size: int, encoding: u32) -> b8 ---
	CFRelease :: proc "c" (cf: rawptr) ---
}

// macOS often stores names decomposed ("e" + U+0301) and raylib cannot stack
// combining accents, so names are composed ("é") for display only. Paths
// given to Finder keep their original bytes.
to_nfc :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !has_combining_mark(s) {
		return s
	}
	str := CFStringCreateWithBytes(nil, raw_data(s), len(s), kCFStringEncodingUTF8, false)
	if str == nil {
		return s
	}
	defer CFRelease(rawptr(str))
	m := CFStringCreateMutableCopy(nil, 0, str)
	if m == nil {
		return s
	}
	defer CFRelease(rawptr(m))
	CFStringNormalize(m, kCFStringNormalizationFormC)
	size := CFStringGetMaximumSizeForEncoding(CFStringGetLength(m), kCFStringEncodingUTF8) + 1
	buf := make([]u8, size, allocator)
	if !CFStringGetCString(m, raw_data(buf), size, kCFStringEncodingUTF8) {
		return s
	}
	return string(cstring(raw_data(buf)))
}

// U+0300..U+036F (combining diacritics) are CC 80..CD AF in UTF-8.
@(private = "file")
has_combining_mark :: proc(s: string) -> bool {
	for i in 0 ..< len(s) - 1 {
		if (s[i] == 0xCC && s[i + 1] >= 0x80) || (s[i] == 0xCD && s[i + 1] >= 0x80 && s[i + 1] <= 0xAF) {
			return true
		}
	}
	return false
}
