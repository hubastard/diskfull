package diskfull

import "core:fmt"
import "core:os"
import "core:strings"

// Set by build.sh / build.bat from `git describe`, e.g. "0.1.1" for a release.
VERSION :: #config(VERSION, "dev")

Options :: struct {
	root:       string,
	screenshot: string, // --screenshot <file.png>: scan, save one frame and quit (used by CI)
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
		case arg == "--screenshot":
			if i + 1 >= len(args) {
				usage_error("--screenshot needs a file name")
			}
			i += 1
			opts.screenshot = args[i]
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
      --screenshot FILE  Scan, save the window as a PNG image to FILE and exit.

In the window: hover to identify, click to show in %s, right-click or
scroll to zoom in and out, Tab for the largest files, C to switch colors,
R to rescan.

https://github.com/hubastard/diskfull
`,
		VERSION,
		default_root(),
		FILE_MANAGER,
	)
}

usage_error :: proc(msg: string) -> ! {
	console_write(fmt.tprintf("diskfull: %s\nTry 'diskfull --help' for more information.\n", msg), true)
	os.exit(2)
}
