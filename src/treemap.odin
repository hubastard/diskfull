package diskfull

import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem/virtual"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

HEADER_H :: 16
MIN_TILE_AREA :: 20 // px²; smaller items are merged into one "N smaller items" tile

Color_Mode :: enum {
	Folder, // one hue per top-level folder of the current view
	Kind,   // by file extension category
}

Tile :: struct {
	rect:      rl.Rectangle,
	node:      ^Node, // for a "rest" tile: the directory holding the small items
	rest:      i32,   // > 0: this tile stands for `rest` small items of `node`
	rest_size: i64,
	depth:     i32,
	hue:       f32,
	color:     rl.Color,
	label:     cstring, // directory header or file name, nil when it does not fit
	label2:    cstring, // file size, under the name
}

Layout :: struct {
	tiles: [dynamic]Tile,
	arena: virtual.Arena,
	font:  rl.Font,
	mode:  Color_Mode,
}

layout_build :: proc(l: ^Layout, view: ^Node, r: rl.Rectangle) {
	clear(&l.tiles)
	virtual.arena_free_all(&l.arena)
	if view == nil || view.size <= 0 {
		return
	}
	squarify(l, view, r, 1, 0)
}

@(private = "file")
layout_node :: proc(l: ^Layout, n: ^Node, r: rl.Rectangle, depth: i32, hue: f32) {
	t := Tile {
		rect  = r,
		node  = n,
		depth = depth,
		hue   = hue,
		color = tile_color(l.mode, n, depth, hue),
	}
	is_dir := .Dir in n.flags
	header := is_dir && r.width >= 48 && r.height >= 34
	alloc := virtual.arena_allocator(&l.arena)
	if header {
		text := fmt.aprintf("%s  %s", n.name, format_size(n.size), allocator = alloc)
		t.label = fit_text(l.font, text, 12, r.width - 8, alloc)
	} else if !is_dir && r.width >= 50 && r.height >= 18 {
		t.label = fit_text(l.font, n.name, 12, r.width - 8, alloc)
		if r.height >= 34 {
			t.label2 = fit_text(l.font, format_size(n.size), 12, r.width - 8, alloc)
		}
	}
	append(&l.tiles, t)

	if !is_dir || len(n.children) == 0 || r.width < 8 || r.height < 8 {
		return
	}
	pad: f32 = 2 if r.width >= 40 && r.height >= 40 else 1
	head: f32 = HEADER_H if header else 0
	inner := rl.Rectangle{r.x + pad, r.y + pad + head, r.width - 2 * pad, r.height - 2 * pad - head}
	if inner.width < 2 || inner.height < 2 {
		return
	}
	squarify(l, n, inner, depth + 1, hue)
}

// Squarified treemap (Bruls, Huizing, van Wijk). Children are already sorted
// biggest first by the scanner.
@(private = "file")
squarify :: proc(l: ^Layout, parent: ^Node, r: rl.Rectangle, depth: i32, hue: f32) {
	kids := parent.children
	sum: f64
	for c in kids {
		sum += f64(c.size)
	}
	if sum <= 0 {
		return
	}
	x, y, w, h := f64(r.x), f64(r.y), f64(r.width), f64(r.height)
	scale := w * h / sum
	area :: #force_inline proc(n: ^Node, scale: f64) -> f64 {return f64(n.size) * scale}

	i := 0
	for i < len(kids) && kids[i].size > 0 {
		if area(kids[i], scale) < MIN_TILE_AREA {
			rest := Tile {
				rect  = {f32(x), f32(y), f32(w), f32(h)},
				node  = parent,
				depth = depth,
				hue   = hue,
			}
			for c in kids[i:] {
				if c.size <= 0 {
					break
				}
				rest.rest += 1
				rest.rest_size += c.size
			}
			rest.color = rest_color(l.mode, depth, hue)
			append(&l.tiles, rest)
			return
		}

		side := min(w, h)
		row_sum := area(kids[i], scale)
		row_min, row_max := row_sum, row_sum
		cur := worst(row_sum, row_min, row_max, side)
		j := i + 1
		for j < len(kids) {
			a := area(kids[j], scale)
			if a < MIN_TILE_AREA {
				break
			}
			next := worst(row_sum + a, min(row_min, a), row_max, side)
			if next > cur {
				break
			}
			row_sum += a
			row_min = min(row_min, a)
			cur = next
			j += 1
		}

		if w >= h {
			thick := row_sum / h
			cy := y
			for k in i ..< j {
				kh := area(kids[k], scale) / thick
				layout_node(l, kids[k], {f32(x), f32(cy), f32(thick), f32(kh)}, depth, child_hue(depth, k, hue))
				cy += kh
			}
			x += thick
			w -= thick
		} else {
			thick := row_sum / w
			cx := x
			for k in i ..< j {
				kw := area(kids[k], scale) / thick
				layout_node(l, kids[k], {f32(cx), f32(y), f32(kw), f32(thick)}, depth, child_hue(depth, k, hue))
				cx += kw
			}
			y += thick
			h -= thick
		}
		i = j
	}
}

@(private = "file")
worst :: proc(sum, mn, mx, side: f64) -> f64 {
	s2, w2 := sum * sum, side * side
	return max(w2 * mx / s2, s2 / (w2 * mn))
}

@(private = "file")
child_hue :: proc(depth: i32, index: int, parent_hue: f32) -> f32 {
	if depth == 1 {
		return branch_hue(index)
	}
	return parent_hue
}

branch_hue :: proc(index: int) -> f32 {
	return f32(math.mod(205 + f64(index) * 137.508, 360))
}

@(private = "file")
tile_color :: proc(mode: Color_Mode, n: ^Node, depth: i32, hue: f32) -> rl.Color {
	if .Dir in n.flags {
		v := 0.20 + 0.035 * f32(min(depth, 6))
		if mode == .Kind {
			return rl.ColorFromHSV(0, 0, v)
		}
		return rl.ColorFromHSV(hue, 0.40, v)
	}
	jitter := f32(hash.fnv32a(transmute([]u8)n.name) % 1000) / 1000 * 0.16 - 0.08
	if mode == .Kind {
		h, s := kind_color(n.name)
		return rl.ColorFromHSV(h, s, 0.78 + jitter)
	}
	return rl.ColorFromHSV(hue, 0.52, 0.76 + jitter)
}

@(private = "file")
rest_color :: proc(mode: Color_Mode, depth: i32, hue: f32) -> rl.Color {
	if mode == .Kind {
		return rl.ColorFromHSV(0, 0, 0.42)
	}
	return rl.ColorFromHSV(hue, 0.22, 0.46)
}

File_Kind :: enum {
	Other,
	Video,
	Image,
	Audio,
	Archive,
	Code,
	Document,
	Data,
}

KIND_NAMES := [File_Kind]string {
	.Other    = "Other",
	.Video    = "Video",
	.Image    = "Images",
	.Audio    = "Audio",
	.Archive  = "Archives / disk images",
	.Code     = "Code / build output",
	.Document = "Documents",
	.Data     = "Databases / caches",
}

KIND_HS := [File_Kind][2]f32 {
	.Other    = {0, 0},
	.Video    = {350, 0.60},
	.Image    = {28, 0.65},
	.Audio    = {52, 0.65},
	.Archive  = {275, 0.50},
	.Code     = {135, 0.50},
	.Document = {210, 0.55},
	.Data     = {180, 0.55},
}

kind_color :: proc(name: string) -> (hue, sat: f32) {
	hs := KIND_HS[file_kind(name)]
	return hs[0], hs[1]
}

file_kind :: proc(name: string) -> File_Kind {
	ext := filepath.ext(name)
	if len(ext) < 2 || len(ext) > 12 {
		return .Other
	}
	lower := strings.to_lower(ext[1:], context.temp_allocator)
	switch lower {
	case "mp4", "mov", "mkv", "avi", "m4v", "webm", "mpg", "mpeg", "wmv", "flv", "mts", "braw", "r3d", "prores":
		return .Video
	case "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "psb", "svg", "exr":
		return .Image
	case "mp3", "wav", "aif", "aiff", "flac", "m4a", "aac", "ogg", "opus", "caf", "alac":
		return .Audio
	case "zip", "gz", "tgz", "tar", "xz", "bz2", "zst", "7z", "rar", "dmg", "iso", "img", "pkg", "ipsw", "vmdk", "vdi", "qcow2", "vhd", "vhdx", "sparseimage", "sparsebundle", "asar", "xip", "whl", "jar", "msi", "cab", "deb", "rpm", "snap", "appimage", "flatpak":
		return .Archive
	case "o", "a", "dylib", "so", "framework", "pch", "pcm", "swiftmodule", "dsym", "js", "ts", "map", "wasm", "class", "pyc", "rlib", "rmeta", "node", "bin", "exe", "dll", "lib", "obj", "pdb", "gguf", "safetensors", "pt", "onnx", "ckpt":
		return .Code
	case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "md", "rtf", "epub", "csv":
		return .Document
	case "db", "sqlite", "sqlite3", "sqlite-wal", "sqlite-shm", "db-wal", "realm", "store", "cache", "log", "ldb", "idx", "pack", "dat", "photoslibrary":
		return .Data
	}
	return .Other
}
