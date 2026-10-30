package diskfull

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// Set by build.sh / build.bat from `git describe`, e.g. "0.1.1" for a release.
VERSION :: #config(VERSION, "dev")

Options :: struct {
	root:       string,
	screenshot: string, // --screenshot <file.png>: scan, save one frame and quit (used by CI)
	zoom:       f32, // --zoom <percent>, 0 when not given (the saved zoom is used)
	live:       bool, // --live: show the treemap while the scan runs
}

// Parses the command line. --help, --version and usage errors print and exit
// here, before any window is opened.
parse_args :: proc(args: []string) -> (opts: Options) {
	opts.root = default_root()
	have_root, only_folders := false, false
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		switch {
		case only_folders || !strings.has_prefix(arg, "-") || arg == "-":
			if have_root {
				usage_error("only one folder can be scanned at a time")
			}
			opts.root, have_root = arg, true
		case arg == "--":
			only_folders = true
		case arg == "-h" || arg == "--help":
			console_write(help_text(), false)
			os.exit(0)
		case arg == "-v" || arg == "--version":
			console_write(fmt.tprintf("diskfull %s\n", VERSION), false)
			os.exit(0)
		case arg == "--live":
			opts.live = true
		case arg == "--screenshot":
			if i + 1 >= len(args) {
				usage_error("--screenshot needs a file name")
			}
			i += 1
			opts.screenshot = args[i]
		case arg == "--zoom":
			percent, ok := 0, false
			if i + 1 < len(args) {
				i += 1
				percent, ok = strconv.parse_int(strings.trim_suffix(args[i], "%"), 10)
			}
			if !ok || percent < int(ZOOM_MIN * 100) || percent > int(ZOOM_MAX * 100) {
				usage_error(fmt.tprintf("--zoom needs a percentage from %d to %d", int(ZOOM_MIN * 100), int(ZOOM_MAX * 100)))
			}
			opts.zoom = f32(percent) / 100
		case ODIN_OS == .Darwin && strings.has_prefix(arg, "-psn_"):
		// Older macOS versions pass a process serial number to apps opened in Finder.
		case:
			usage_error(fmt.tprintf("unknown option '%s'", arg))
		}
	}
	return
}

help_text :: proc() -> string {
	return fmt.tprintf(
		`diskfull %s
See what is really filling your disk: every file and folder drawn as a box
sized by the space it takes on disk.

Usage: diskfull [options] [folder]

Scans the folder, or the whole system disk (%s) when none is given, and
opens a window to explore it.

Options:
  -h, --help             Show this help and exit.
  -v, --version          Show the version and exit.
      --live             Show the treemap while the scan runs and fill it in
                         as folders are read, instead of a progress screen.
      --zoom PERCENT     Start with the text and interface at this size
                         (50 to 300, default: the last size you chose).
      --screenshot FILE  Scan, save the window as a PNG image to FILE and exit.

In the window: hover to identify, click to show in %s, right-click or
scroll to zoom in and out, Tab for the largest files, C to switch colors,
R to rescan. %s and + or -, or %s and the scroll wheel, change the text
size; %s 0 resets it.

https://github.com/hubastard/diskfull
`,
		VERSION,
		default_root(),
		FILE_MANAGER,
		MOD_KEY,
		MOD_KEY,
		MOD_KEY,
	)
}

usage_error :: proc(msg: string) -> ! {
	console_write(fmt.tprintf("diskfull: %s\nTry 'diskfull --help' for more information.\n", msg), true)
	os.exit(2)
}
