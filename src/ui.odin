package diskfull

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

COL_BG :: rl.Color{24, 25, 28, 255}
COL_PANEL :: rl.Color{32, 33, 37, 255}
COL_LINE :: rl.Color{52, 54, 60, 255}
COL_TEXT :: rl.Color{232, 233, 236, 255}
COL_DIM :: rl.Color{150, 153, 162, 255}
COL_ACCENT :: rl.Color{92, 156, 255, 255}
COL_WARN :: rl.Color{255, 170, 70, 255}
COL_TIP :: rl.Color{255, 214, 102, 255}

Font_Size :: enum {
	Small  = 12,
	Normal = 14,
	Large  = 20,
}

fonts: #sparse[Font_Size]rl.Font

load_fonts :: proc() {
	codepoints := make([dynamic]rune, context.temp_allocator)
	for r in rune(32) ..= 126 {append(&codepoints, r)}
	for r in rune(0xA0) ..= 0x24F {append(&codepoints, r)}   // Latin-1, Latin Extended-A/B
	for r in rune(0x300) ..= 0x36F {append(&codepoints, r)}  // combining accents with no composed form
	for r in rune(0x370) ..= 0x4FF {append(&codepoints, r)}  // Greek, Cyrillic
	for r in rune(0x1E00) ..= 0x1EFF {append(&codepoints, r)} // Latin Extended Additional (Vietnamese...)
	append(&codepoints, '…', '•', '·', '›', '‹', '→', '←', '—', '–', '‘', '’', '“', '”')

	path: cstring
	for c in FONT_CANDIDATES {
		if rl.FileExists(c) {
			path = c
			break
		}
	}
	if path == nil {
		for size in Font_Size {
			fonts[size] = rl.GetFontDefault()
		}
		return
	}
	data_size: i32
	data := rl.LoadFileData(path, &data_size)
	defer rl.UnloadFileData(data)

	// No font has every glyph above, and raylib warns about each missing one
	// (they are drawn as '?'). Keep the log quiet while loading.
	rl.SetTraceLogLevel(.ERROR)
	defer rl.SetTraceLogLevel(.WARNING)
	scale := max(rl.GetWindowScaleDPI().x, 1)
	for size in Font_Size {
		px := i32(math.round(f32(size) * scale))
		fonts[size] = rl.LoadFontFromMemory(rl.GetFileExtension(path), data, data_size, px, raw_data(codepoints), i32(len(codepoints)))
		rl.SetTextureFilter(fonts[size].texture, .BILINEAR)
	}
}

text :: proc(s: cstring, x, y: f32, size: Font_Size = .Normal, color := COL_TEXT) {
	rl.DrawTextEx(fonts[size], s, {math.round(x), math.round(y)}, f32(size), 0, color)
}

text_width :: proc(s: cstring, size: Font_Size = .Normal) -> f32 {
	return rl.MeasureTextEx(fonts[size], s, f32(size), 0).x
}

// Right-aligned text ending at x.
text_right :: proc(s: cstring, x, y: f32, size: Font_Size = .Normal, color := COL_TEXT) {
	text(s, x - text_width(s, size), y, size, color)
}

// Shortens text with a trailing "…" so it fits in max_w.
fit_text :: proc(font: rl.Font, raw: string, size: f32, max_w: f32, allocator := context.temp_allocator) -> cstring {
	if max_w <= 0 || font.glyphCount == 0 {
		return nil // no room, or no font loaded (no window, e.g. in tests)
	}
	s := to_nfc(raw, allocator)
	full := strings.clone_to_cstring(s, allocator)
	if rl.MeasureTextEx(font, full, size, 0).x <= max_w {
		return full
	}
	// Binary search the longest rune-aligned prefix that fits with the ellipsis.
	bounds := make([dynamic]int, 0, len(s) + 1, allocator)
	for _, i in s {
		append(&bounds, i)
	}
	append(&bounds, len(s))
	buf := make([]u8, len(s) + 4, allocator)
	with_ellipsis :: proc(buf: []u8, prefix: string) -> cstring {
		n := copy(buf, prefix)
		n += copy(buf[n:], "…")
		buf[n] = 0
		return cstring(raw_data(buf))
	}
	lo, hi := 0, len(bounds) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if rl.MeasureTextEx(font, with_ellipsis(buf, s[:bounds[mid]]), size, 0).x <= max_w {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	if lo == 0 {
		return nil
	}
	return with_ellipsis(buf, s[:bounds[lo]])
}

fit :: proc(s: string, max_w: f32, size: Font_Size = .Normal) -> cstring {
	return fit_text(fonts[size], s, f32(size), max_w)
}

// Breaks text into lines no wider than max_w, preferring to break after ' ' or '/'.
wrap :: proc(s: string, max_w: f32, size: Font_Size) -> []cstring {
	lines := make([dynamic]cstring, context.temp_allocator)
	rest := to_nfc(s)
	for len(rest) > 0 && len(lines) < 6 {
		c := strings.clone_to_cstring(rest, context.temp_allocator)
		if text_width(c, size) <= max_w {
			append(&lines, c)
			break
		}
		// Longest prefix that fits.
		lo, hi := 1, len(rest)
		for lo < hi {
			mid := (lo + hi + 1) / 2
			p := strings.clone_to_cstring(rest[:mid], context.temp_allocator)
			if text_width(p, size) <= max_w {
				lo = mid
			} else {
				hi = mid - 1
			}
		}
		cut := lo
		if brk := strings.last_index_any(rest[:cut], " /"); brk > cut / 2 {
			cut = brk + 1
		}
		for cut > 1 && cut < len(rest) && !utf8.rune_start(rest[cut]) {
			cut -= 1
		}
		append(&lines, strings.clone_to_cstring(rest[:cut], context.temp_allocator))
		rest = rest[cut:]
	}
	return lines[:]
}

// Decimal units, like Finder and System Settings.
format_size :: proc(b: i64, allocator := context.temp_allocator) -> string {
	v := f64(b)
	switch {
	case v >= 1e12:
		return fmt.aprintf("%.2f TB", v / 1e12, allocator = allocator)
	case v >= 1e9:
		return fmt.aprintf("%.1f GB", v / 1e9, allocator = allocator)
	case v >= 1e6:
		return fmt.aprintf("%.1f MB", v / 1e6, allocator = allocator)
	case v >= 1e3:
		return fmt.aprintf("%.0f KB", v / 1e3, allocator = allocator)
	}
	return fmt.aprintf("%d B", b, allocator = allocator)
}

format_pct :: proc(frac: f64) -> string {
	p := frac * 100
	if p > 0 && p < 0.1 {
		return "<0.1%"
	}
	return fmt.tprintf("%.1f%%", p)
}

format_files :: proc(n: i64) -> string {
	return "1 file" if n == 1 else fmt.tprintf("%s files", format_count(n))
}

format_count :: proc(n: i64) -> string {
	s := fmt.tprintf("%d", n)
	b := strings.builder_make(context.temp_allocator)
	for c, i in s {
		if i > 0 && (len(s) - i) % 3 == 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_rune(&b, c)
	}
	return strings.to_string(b)
}

cs :: proc(format: string, args: ..any) -> cstring {
	return fmt.ctprintf(format, ..args)
}

// Space hogs found on every platform; checked after PLATFORM_NOTES.
COMMON_NOTES := [?][2]string {
	{"/node_modules/", "npm packages. Delete it and run npm install again when needed."},
	{"/.npm/", "npm cache. Clean up with: npm cache clean --force"},
	{"/.gradle/", "Gradle caches."},
	{"/.m2/", "Maven repository cache."},
	{"/.cargo/registry/", "Rust crate cache."},
	{"/.rustup/", "Rust toolchains. Remove old ones with: rustup toolchain list / uninstall"},
	{"/target/debug/", "Rust debug build output. cargo clean frees it."},
	{"/.ollama/models/", "Ollama models. Remove unused ones with: ollama rm <model>"},
	{"/.cache/huggingface/", "Hugging Face model cache."},
	{"/.cache/", "Tool caches. Usually safe to delete."},
}

note_for :: proc(path: string) -> string {
	p := strings.concatenate({path, "/"}, context.temp_allocator)
	when ODIN_OS == .Windows {
		// Notes are written with '/'; Windows paths are case-insensitive.
		p, _ = strings.replace_all(p, "\\", "/", context.temp_allocator)
		p = strings.to_lower(p, context.temp_allocator)
	}
	for list in ([][][2]string{PLATFORM_NOTES[:], COMMON_NOTES[:]}) {
		for n in list {
			pattern := n[0]
			when ODIN_OS == .Windows {
				pattern = strings.to_lower(pattern, context.temp_allocator)
			}
			if strings.contains(p, pattern) {
				return n[1]
			}
		}
	}
	return ""
}

Button :: struct {
	hover, clicked, right_clicked: bool,
}

button :: proc(r: rl.Rectangle) -> (b: Button) {
	b.hover = rl.CheckCollisionPointRec(rl.GetMousePosition(), r)
	b.clicked = b.hover && rl.IsMouseButtonPressed(.LEFT)
	b.right_clicked = b.hover && rl.IsMouseButtonPressed(.RIGHT)
	return
}
