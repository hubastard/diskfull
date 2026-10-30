#+build windows
package diskfull

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import rl "vendor:raylib"

PATH_SEP :: '\\'
FILE_MANAGER :: "Explorer"
MOD_KEY :: "Ctrl" // for shortcuts
WINDOW_FLAGS :: rl.ConfigFlags{.WINDOW_RESIZABLE, .MSAA_4X_HINT, .VSYNC_HINT}

FONT_CANDIDATES := [?]cstring {
	"C:/Windows/Fonts/segoeui.ttf",
	"C:/Windows/Fonts/arial.ttf",
}

PERMISSION_HINT :: "Some folders can only be read by administrators. For the complete picture, run diskfull as administrator."
DENIED_HINT :: "Run as administrator to see them."
HIDDEN_HINT :: "Hidden = space the scan cannot see: restore points and shadow copies (System Volume Information), NTFS metadata and unreadable folders."

// Matched against lowercase paths written with '/'.
PLATFORM_NOTES := [?][2]string {
	{"/pagefile.sys/", "Virtual memory (page file), managed by Windows."},
	{"/swapfile.sys/", "Swap file for Store apps, managed by Windows."},
	{"/hiberfil.sys/", "Hibernation file. Remove it, and hibernation, with: powercfg /hibernate off"},
	{"/$recycle.bin/", "Recycle Bin. Empty it to get this space back."},
	{"/windows.old/", "Previous Windows installation. Remove it with Disk Cleanup > Clean up system files."},
	{"/windows/winsxs/", "Windows component store. Hard links to System32 are counted once. Clean up with: Dism /Online /Cleanup-Image /StartComponentCleanup"},
	{"/windows/softwaredistribution/download/", "Downloaded Windows updates. Disk Cleanup removes them."},
	{"/windows/installer/", "Installer cache used to repair and uninstall programs. Do not delete by hand."},
	{"/windows/temp/", "System temporary files. Disk Cleanup removes them."},
	{"/appdata/local/temp/", "Temporary files. Usually safe to delete."},
	{"/appdata/local/docker/wsl/", "Docker's WSL disk. Free space with: docker system prune -a"},
	{"ext4.vhdx/", "Disk of a WSL Linux distribution. Let it shrink with: wsl --manage <distro> --set-sparse true"},
	{"/programdata/package cache/", "Installer caches (Visual Studio, SDKs...)."},
	{"/appdata/local/microsoft/windows/inetcache/", "Browser cache."},
	{"/steamapps/", "Steam games."},
	{"/onedrive/", "OneDrive files kept on this PC. 'Free up space' makes them online-only."},
}

default_root :: proc() -> string {
	drive := os.get_env("SystemDrive", context.temp_allocator)
	return strings.concatenate({drive if drive != "" else "C:", "\\"}, context.temp_allocator)
}

absolute_path :: proc(path: string) -> string {
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	n := win.GetFullPathNameW(wpath, 0, nil, nil)
	if n == 0 {
		return path
	}
	buf := make([]u16, n, context.temp_allocator)
	n = win.GetFullPathNameW(wpath, n, cstring16(raw_data(buf)), nil)
	full, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if n == 0 || err != nil {
		return path
	}
	// Keep "C:\" but drop the trailing separator elsewhere.
	for len(full) > 3 && (full[len(full) - 1] == '\\' || full[len(full) - 1] == '/') {
		full = full[:len(full) - 1]
	}
	return full
}

foreign import kernel32 "system:Kernel32.lib"

@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	GetVolumePathNameW :: proc(lpszFileName: win.LPCWSTR, lpszVolumePathName: win.LPWSTR, cchBufferLength: win.DWORD) -> win.BOOL ---
}

// Strings in the result are temporary; clone them to keep them.
volume_info :: proc(path: cstring) -> (info: Volume_Info, ok: bool) {
	vol: [win.MAX_PATH + 1]u16
	wpath := win.utf8_to_wstring(string(path), context.temp_allocator)
	if !GetVolumePathNameW(wpath, raw_data(vol[:]), len(vol)) {
		return
	}
	avail, total, free: win.ULARGE_INTEGER
	if !win.GetDiskFreeSpaceExW(cstring16(raw_data(vol[:])), &avail, &total, &free) {
		return
	}
	info.total = i64(total)
	info.used = i64(total - free)
	info.free = i64(avail)
	info.mount, _ = win.utf16_to_utf8(vol[:], context.temp_allocator)
	return info, true
}

// Opens the enclosing folder in Explorer with the item selected.
reveal_in_file_manager :: proc(path: string) {
	run_detached(fmt.tprintf(`explorer.exe /select,"%s"`, path))
}

open_folder :: proc(path: string) {
	run_detached(fmt.tprintf(`explorer.exe "%s"`, path))
}

@(private = "file")
run_detached :: proc(command_line: string) {
	si := win.STARTUPINFOW {
		cb = size_of(win.STARTUPINFOW),
	}
	pi: win.PROCESS_INFORMATION
	cmd := win.utf8_to_wstring(command_line, context.temp_allocator)
	if win.CreateProcessW(nil, cmd, nil, nil, false, 0, nil, nil, &si, &pi) {
		win.CloseHandle(pi.hProcess)
		win.CloseHandle(pi.hThread)
	}
}

ignore_child_exits :: proc() {}

ATTACH_PARENT_PROCESS :: ~win.DWORD(0)

// Prints text for --help, --version and usage errors. diskfull.exe is a GUI
// program, so it only has standard handles when its output is redirected;
// otherwise it borrows the console of the terminal that started it. Terminals
// do not wait for GUI programs, so that text shows up after the next prompt.
console_write :: proc(s: string, to_stderr: bool) {
	which := win.STD_ERROR_HANDLE if to_stderr else win.STD_OUTPUT_HANDLE
	text := s
	h := win.GetStdHandle(which)
	if h == nil || h == win.INVALID_HANDLE_VALUE {
		// Fails when started from Explorer: there is no console to print to.
		if win.AttachConsole(ATTACH_PARENT_PROCESS) {
			text = strings.concatenate({"\n", s}, context.temp_allocator) // the prompt is already printed
		}
		h = win.GetStdHandle(which)
		if h == nil || h == win.INVALID_HANDLE_VALUE {
			h = win.CreateFileW(win.L("CONOUT$"), win.GENERIC_WRITE, win.FILE_SHARE_WRITE, nil, win.OPEN_EXISTING, 0, nil)
		}
		if h == nil || h == win.INVALID_HANDLE_VALUE {
			return
		}
	}
	written, mode: win.DWORD
	if win.GetConsoleMode(h, &mode) {
		w := win.utf8_to_utf16(text, context.temp_allocator)
		win.WriteConsoleW(h, raw_data(w), win.DWORD(len(w)), &written, nil)
	} else {
		win.WriteFile(h, raw_data(text), win.DWORD(len(text)), &written, nil)
	}
}

// Windows file names are almost always composed already.
to_nfc :: proc(s: string, allocator := context.temp_allocator) -> string {
	return s
}

// Where settings are saved: %APPDATA%\diskfull.
config_dir :: proc() -> string {
	appdata := os.get_env("APPDATA", context.temp_allocator)
	return strings.concatenate({appdata, "\\diskfull"}, context.temp_allocator) if appdata != "" else ""
}
