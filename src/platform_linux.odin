#+build linux
package diskfull

import "core:os"
import "core:strings"
import "core:sys/posix"
import rl "vendor:raylib"

FILE_MANAGER :: "file manager"
WINDOW_FLAGS :: rl.ConfigFlags{.WINDOW_RESIZABLE, .MSAA_4X_HINT, .VSYNC_HINT}

FONT_CANDIDATES := [?]cstring {
	"/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf", // Debian, Ubuntu
	"/usr/share/fonts/noto/NotoSans-Regular.ttf", // Arch
	"/usr/share/fonts/google-noto/NotoSans-Regular.ttf", // Fedora
	"/usr/share/fonts/google-noto-vf/NotoSans[wght].ttf", // Fedora 40+
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
}

PERMISSION_HINT :: "Some folders can only be read by root. For the complete picture, run with sudo."
DENIED_HINT :: "Run with sudo to see them."
HIDDEN_HINT :: "Hidden = space the scan cannot see: unreadable folders, snapshots (btrfs, zfs), filesystem metadata and deleted files still held open by a running program."

PLATFORM_NOTES := [?][2]string {
	{"/var/log/journal/", "systemd journal. Shrink it with: sudo journalctl --vacuum-size=200M"},
	{"/var/lib/docker/", "Docker images, containers and volumes. Free space with: docker system prune -a"},
	{"/var/lib/containers/", "Podman images and containers. Free space with: podman system prune -a"},
	{"/.local/share/containers/", "Podman images and containers. Free space with: podman system prune -a"},
	{"/var/lib/snapd/", "Snap packages; old revisions are kept. Keep fewer with: sudo snap set system refresh.retain=2"},
	{"/var/lib/flatpak/", "Flatpak apps and runtimes. Remove unused ones with: flatpak uninstall --unused"},
	{"/.local/share/flatpak/", "Flatpak apps and runtimes. Remove unused ones with: flatpak uninstall --unused"},
	{"/.var/app/", "Data of Flatpak apps."},
	{"/var/cache/apt/", "Downloaded packages. Clean up with: sudo apt clean"},
	{"/var/cache/pacman/", "Downloaded packages. Clean up with: sudo paccache -r"},
	{"/var/cache/dnf/", "Downloaded packages. Clean up with: sudo dnf clean all"},
	{"/var/lib/libvirt/images/", "Virtual machine disks."},
	{"/.local/share/Trash/", "Trash. Empty it to get this space back."},
	{"/.local/share/Steam/", "Steam games."},
	{"/lib/modules/", "Kernel modules. Old kernels can be removed with your package manager."},
	{"/usr/lib/modules/", "Kernel modules. Old kernels can be removed with your package manager."},
	{"/swapfile/", "Swap file."},
	{"/var/log/", "System logs."},
	{"/var/tmp/", "Temporary files kept across reboots."},
	{"/tmp/", "Temporary files."},
}

default_root :: proc() -> string {
	return "/"
}

// Strings in the result are temporary; clone them to keep them.
volume_info :: proc(path: cstring) -> (info: Volume_Info, ok: bool) {
	sv: posix.statvfs_t
	if posix.statvfs(path, &sv) != .OK {
		return {}, false
	}
	frsize := i64(sv.f_frsize)
	info.total = i64(sv.f_blocks) * frsize
	info.used = (i64(sv.f_blocks) - i64(sv.f_bfree)) * frsize
	info.free = i64(sv.f_bavail) * frsize // like df: excludes blocks reserved for root
	info.mount, info.container = find_mount(string(path))
	return info, true
}

// Finds the mount holding `path` in /proc/self/mountinfo. Its container is the
// block device (shared by btrfs subvolumes) or the zfs pool.
@(private = "file")
find_mount :: proc(path: string) -> (mount, container: string) {
	data, err := os.read_entire_file("/proc/self/mountinfo", context.temp_allocator)
	if err != nil {
		return
	}
	text := string(data)
	best := -1
	for line in strings.split_lines_iterator(&text) {
		// id parent major:minor root mount-point options [optional...] - fstype source super-options
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 10 {
			continue
		}
		sep := -1
		for f, i in fields[6:] {
			if f == "-" {
				sep = 6 + i
				break
			}
		}
		if sep < 0 || sep + 2 >= len(fields) {
			continue
		}
		mp := unescape_mount(fields[4])
		inside := mp == "/" || path == mp || (strings.has_prefix(path, mp) && path[len(mp)] == '/')
		// Later entries stack on top of earlier ones at the same mount point.
		if !inside || len(mp) < best {
			continue
		}
		best = len(mp)
		mount = mp
		fstype, source := fields[sep + 1], fields[sep + 2]
		switch {
		case fstype == "zfs":
			container = source[:strings.index_byte(source, '/')] if strings.contains(source, "/") else source
		case strings.has_prefix(source, "/dev/"):
			container = source
		case:
			container = "" // tmpfs, proc, overlay...: never cross into these
		}
	}
	return
}

// mountinfo escapes space, tab, newline and backslash as octal (\040...).
@(private = "file")
unescape_mount :: proc(s: string) -> string {
	if !strings.contains_rune(s, '\\') {
		return s
	}
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 3 < len(s) {
			strings.write_byte(&b, (s[i + 1] - '0') * 64 + (s[i + 2] - '0') * 8 + (s[i + 3] - '0'))
			i += 3
		} else {
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

// Asks the file manager to select the item (freedesktop FileManager1 D-Bus
// interface: Nautilus, Dolphin, Nemo, Caja...), else just opens the folder.
reveal_in_file_manager :: proc(path: string) {
	parent := path[:max(strings.last_index_byte(path, '/'), 1)]
	script := `dbus-send --session --print-reply --dest=org.freedesktop.FileManager1 --type=method_call /org/freedesktop/FileManager1 org.freedesktop.FileManager1.ShowItems array:string:"$1" string:"" >/dev/null 2>&1 || xdg-open "$2"`
	run_detached("/bin/sh", "-c", script, "sh", file_uri(path), parent)
}

open_folder :: proc(path: string) {
	run_detached("xdg-open", path)
}

// Everything but unreserved characters and '/' is percent-encoded (commas
// would also split dbus-send's array argument).
@(private = "file")
file_uri :: proc(path: string) -> string {
	hex := "0123456789ABCDEF"
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "file://")
	for c in transmute([]u8)path {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '.', '_', '~', '/':
			strings.write_byte(&b, c)
		case:
			strings.write_byte(&b, '%')
			strings.write_byte(&b, hex[c >> 4])
			strings.write_byte(&b, hex[c & 15])
		}
	}
	return strings.to_string(b)
}

// Linux file names are almost always composed already.
to_nfc :: proc(s: string, allocator := context.temp_allocator) -> string {
	return s
}

// Scanner hooks, see scan_posix.odin. Nothing special on Linux.

skip_dir_entry :: proc(dirfd: posix.FD, name: cstring, st: ^posix.stat_t) -> bool {
	return false
}

scan_last :: proc(dir_path, name: string) -> bool {
	return false
}

adjust_file :: proc(s: ^Scanner, dirfd: posix.FD, name: cstring, st: ^posix.stat_t, bytes: i64) -> (i64, Node_Flags) {
	return bytes, {}
}
