package diskfull_tests

import df "../src"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import rl "vendor:raylib"

@(test)
formatting :: proc(t: ^testing.T) {
	testing.expect_value(t, df.format_size(0), "0 B")
	testing.expect_value(t, df.format_size(999), "999 B")
	testing.expect_value(t, df.format_size(1_500_000), "1.5 MB")
	testing.expect_value(t, df.format_size(2_340_000_000), "2.3 GB")
	testing.expect_value(t, df.format_size(1_234_000_000_000), "1.23 TB")
	testing.expect_value(t, df.format_count(999), "999")
	testing.expect_value(t, df.format_count(1_234_567), "1,234,567")
	testing.expect_value(t, df.format_pct(0.5), "50.0%")
	testing.expect_value(t, df.format_pct(0.000_01), "<0.1%")
	testing.expect_value(t, df.format_files(1), "1 file")
	testing.expect_value(t, df.format_files(2_000), "2,000 files")
}

@(test)
command_line :: proc(t: ^testing.T) {
	opts := df.parse_args({})
	testing.expect_value(t, opts.root, df.default_root())
	testing.expect_value(t, opts.screenshot, "")
	testing.expect_value(t, opts.live, false)

	opts = df.parse_args({"--live", "some/folder"})
	testing.expect_value(t, opts.live, true)
	testing.expect_value(t, opts.root, "some/folder")

	opts = df.parse_args({"--screenshot", "out.png", "some/folder"})
	testing.expect_value(t, opts.root, "some/folder")
	testing.expect_value(t, opts.screenshot, "out.png")

	opts = df.parse_args({"--", "--help"}) // a folder named --help
	testing.expect_value(t, opts.root, "--help")

	help := df.help_text()
	testing.expect(t, strings.has_prefix(help, "diskfull " + df.VERSION + "\n"))
	testing.expect(t, strings.contains(help, "--version"))
}

@(test)
zoom :: proc(t: ^testing.T) {
	testing.expect_value(t, df.zoom_step(1, 1), 1.1)
	testing.expect_value(t, df.zoom_step(1, -1), 0.9)
	testing.expect_value(t, df.zoom_step(1.4, 1), 1.5) // from a --zoom between levels
	testing.expect_value(t, df.zoom_step(1.4, -1), 1.25)
	testing.expect_value(t, df.zoom_step(df.ZOOM_MAX, 1), df.ZOOM_MAX)
	testing.expect_value(t, df.zoom_step(df.ZOOM_MIN, -1), df.ZOOM_MIN)

	opts := df.parse_args({"--zoom", "150%"})
	testing.expect_value(t, opts.zoom, 1.5)

	// The chosen zoom survives a restart. Point the config folder at a temporary one.
	tmp, _ := os.temp_directory(context.temp_allocator)
	base, err := os.make_directory_temp(tmp, "diskfull-test-*", context.temp_allocator)
	if !testing.expectf(t, err == nil, "temp dir: %v", err) {
		return
	}
	defer os.remove_all(base)
	key := "APPDATA" when ODIN_OS == .Windows else "XDG_CONFIG_HOME" when ODIN_OS == .Linux else "HOME"
	old := os.get_env(key, context.temp_allocator)
	os.set_env(key, base)
	defer os.set_env(key, old)

	df.ui.zoom_wanted = 1.75
	df.save_settings()
	df.ui.zoom_wanted = 1
	df.load_settings()
	testing.expect_value(t, df.ui.zoom_wanted, 1.75)
	df.ui.zoom_wanted = 1
}

@(test)
names_are_composed_for_display :: proc(t: ^testing.T) {
	testing.expect_value(t, df.to_nfc("Résumé.pdf"), "Résumé.pdf")
	testing.expect_value(t, df.to_nfc("plain"), "plain")
	when ODIN_OS == .Darwin {
		testing.expect_value(t, df.to_nfc("Re\u0301sume\u0301.pdf"), "Résumé.pdf")
		testing.expect_value(t, df.to_nfc("Tie\u0302\u0301ng Vie\u0323\u0302t"), "Tiếng Việt")
	}
}

@(test)
notes :: proc(t: ^testing.T) {
	has :: proc(t: ^testing.T, path, want: string, loc := #caller_location) {
		note := df.note_for(path)
		testing.expectf(t, strings.contains(note, want), "note for %q is %q, want it to mention %q", path, note, want, loc = loc)
	}
	when ODIN_OS == .Windows {
		has(t, `C:\Windows\WinSxS\amd64_foo`, "component store")
		has(t, `C:\hiberfil.sys`, "Hibernation")
		has(t, `C:\Users\me\AppData\Local\Temp`, "Temporary")
		has(t, `D:\code\app\node_modules\left-pad`, "npm")
		testing.expect_value(t, df.note_for(`C:\Users\me\Documents`), "")
	} else {
		has(t, "/home/me/code/app/node_modules/left-pad", "npm")
		testing.expect_value(t, df.note_for("/home/me/Documents"), "")
	}
	when ODIN_OS == .Darwin {
		has(t, "/Users/me/Library/Caches/com.example", "caches")
		has(t, "/Users/me/Library/Developer/Xcode/DerivedData", "Xcode")
	}
	when ODIN_OS == .Linux {
		has(t, "/var/lib/docker/overlay2", "Docker")
		has(t, "/var/log/journal/abc", "journal")
	}
}

@(test)
volume_of_the_system_disk :: proc(t: ^testing.T) {
	root := df.absolute_path(df.default_root())
	info, ok := df.volume_info(strings.clone_to_cstring(root, context.temp_allocator))
	testing.expect(t, ok, "volume_info failed")
	testing.expect(t, info.total > 0 && info.used > 0 && info.used <= info.total && info.free >= 0)
	testing.expect_value(t, info.mount, root)
}

@(test)
absolute_paths :: proc(t: ^testing.T) {
	p := df.absolute_path(".")
	testing.expectf(t, filepath.is_abs(p), "%q is not absolute", p)
	testing.expectf(t, !strings.has_suffix(p, "/") && !strings.has_suffix(p, "\\"), "%q has a trailing separator", p)
}

// Lays out 4 files: each tile's area must match its share of the total.
@(test)
treemap_areas :: proc(t: ^testing.T) {
	sizes := [?]i64{50, 25, 15, 10}
	root := df.Node {
		name  = "root",
		size  = 100,
		flags = {.Dir},
	}
	nodes: [len(sizes)]df.Node
	kids: [len(sizes)]^df.Node
	for size, i in sizes {
		nodes[i] = {
			name   = "file",
			parent = &root,
			size   = size,
			files  = 1,
		}
		kids[i] = &nodes[i]
	}
	root.children = kids[:]

	l: df.Layout
	defer virtual.arena_destroy(&l.arena)
	defer delete(l.tiles)
	r := rl.Rectangle{10, 20, 400, 300}
	df.layout_build(&l, &root, r)

	testing.expect_value(t, len(l.tiles), len(sizes))
	for tile, i in l.tiles {
		tr := tile.rect
		want := f32(sizes[i]) / 100 * r.width * r.height
		testing.expectf(t, abs(tr.width * tr.height - want) < 1, "tile %d area %v, want %v", i, tr.width * tr.height, want)
		testing.expectf(t, tr.x >= r.x - 0.01 && tr.y >= r.y - 0.01 && tr.x + tr.width <= r.x + r.width + 0.01 && tr.y + tr.height <= r.y + r.height + 0.01, "tile %d %v outside %v", i, tr, r)
	}
}

// Items too small to see are merged into one "N small items" tile.
@(test)
treemap_merges_tiny_items :: proc(t: ^testing.T) {
	N :: 100
	root := df.Node {
		name  = "root",
		size  = 1000 + N,
		flags = {.Dir},
	}
	nodes: [N + 1]df.Node
	kids: [N + 1]^df.Node
	for &n, i in nodes {
		n = {
			name   = "file",
			parent = &root,
			size   = 1000 if i == 0 else 1,
			files  = 1,
		}
		kids[i] = &n
	}
	root.children = kids[:]

	l: df.Layout
	defer virtual.arena_destroy(&l.arena)
	defer delete(l.tiles)
	df.layout_build(&l, &root, {0, 0, 100, 100})

	testing.expect_value(t, len(l.tiles), 2)
	if len(l.tiles) == 2 {
		testing.expect_value(t, l.tiles[0].node, kids[0])
		testing.expect_value(t, l.tiles[1].rest, i32(N))
		testing.expect_value(t, l.tiles[1].rest_size, i64(N))
	}
}

// Builds a small tree on disk and checks what the scanner makes of it.
@(test)
scan_fixture :: proc(t: ^testing.T) {
	tmp, _ := os.temp_directory(context.temp_allocator)
	base, err := os.make_directory_temp(tmp, "diskfull-test-*", context.temp_allocator)
	if !testing.expectf(t, err == nil, "temp dir: %v", err) {
		return
	}
	defer os.remove_all(base)
	path :: proc(parts: ..string) -> string {
		p, _ := filepath.join(parts, context.temp_allocator)
		return p
	}

	big := make([]u8, 200_000, context.temp_allocator)
	for &b, i in big {
		b = u8(i * 7) // not all zeros, so no filesystem can compress it away
	}
	testing.expect_value(t, os.make_directory_all(path(base, "a", "b")), nil)
	testing.expect_value(t, os.make_directory(path(base, "empty")), nil)
	testing.expect_value(t, os.write_entire_file(path(base, "a", "big.bin"), big), nil)
	testing.expect_value(t, os.write_entire_file(path(base, "a", "b", "small.txt"), "hello"), nil)
	testing.expect_value(t, os.link(path(base, "a", "big.bin"), path(base, "a", "big-link.bin")), nil)
	when ODIN_OS != .Windows { 	// symlinks need admin rights on Windows
		testing.expect_value(t, os.symlink(path(base, "a"), path(base, "alias")), nil)
		// 64 MiB long, but only one block is allocated.
		f, ferr := os.open(path(base, "sparse.bin"), {.Write, .Create})
		testing.expect_value(t, ferr, nil)
		os.write_at(f, {1}, 64 << 20)
		os.close(f)
	}

	s := df.scanner_start(df.absolute_path(base))
	defer df.scanner_destroy(s)
	start := time.tick_now()
	for !df.scanner_done(s) {
		if time.tick_since(start) > 30 * time.Second {
			testing.fail_now(t, "scan timed out")
		}
		time.sleep(10 * time.Millisecond)
	}

	find :: proc(n: ^df.Node, name: string) -> ^df.Node {
		for c in n.children {
			if c.name == name {
				return c
			}
		}
		return nil
	}
	root := s.root
	testing.expect_value(t, s.denied, 0)
	for i in 1 ..< len(root.children) {
		testing.expect(t, root.children[i - 1].size >= root.children[i].size, "children are sorted biggest first")
	}

	a := find(root, "a")
	if !testing.expect(t, a != nil && .Dir in a.flags, "a/ is a directory") {
		return
	}
	testing.expect_value(t, len(a.children), 2) // big.bin or big-link.bin, and b/
	testing.expect_value(t, a.files, 2)
	testing.expectf(t, a.size >= 200_000 && a.size < 400_000, "a/ is %d bytes: the hard-linked file must be counted once", a.size)
	testing.expect(t, .Dir not_in a.children[0].flags, "the big file comes first")
	if b := find(a, "b"); testing.expect(t, b != nil) {
		testing.expect_value(t, b.files, 1)
	}
	if empty := find(root, "empty"); testing.expect(t, empty != nil) {
		testing.expect_value(t, empty.files, 0)
	}
	when ODIN_OS != .Windows {
		if alias := find(root, "alias"); testing.expect(t, alias != nil) {
			testing.expect(t, .Dir not_in alias.flags, "symlinks are not followed")
		}
		if sparse := find(root, "sparse.bin"); testing.expect(t, sparse != nil) {
			testing.expectf(t, sparse.size < 1 << 20, "sparse file counted as %d bytes, want its allocated size", sparse.size)
		}
	}
	testing.expect_value(t, root.files, a.files + (2 when ODIN_OS != .Windows else 0))
	fmt.println(df.format_size(root.size), "in", df.format_files(root.files))
}
