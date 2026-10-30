package diskfull

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

TOP_H :: 44
STATUS_H :: 28
PANEL_W :: 360
LARGEST_COUNT :: 100
LIVE_REFRESH :: 0.25 // seconds between layouts while the scan runs

Panel_Mode :: enum {
	Contents,
	Largest,
}

App :: struct {
	scanner:      ^Scanner,
	view:         ^Node,
	layout:       Layout,
	layout_view:  ^Node,
	layout_rect:  rl.Rectangle,
	layout_mode:  Color_Mode,
	layout_time:  f64,
	color_mode:   Color_Mode,
	panel_mode:   Panel_Mode,
	largest:      [dynamic]^Node,
	largest_view: ^Node,
	disk:         Volume_Info,
	disk_ok:      bool,
	whole_disk:   bool, // scanning "/", so used space minus scanned space is meaningful
	hover_tile:   int,
	panel_hover:  ^Node,
	wheel:        f32,
	wheel_last:   f64,
	wheel_zoom:   f64,
}

app: App

main :: proc() {
	opts := parse_args(os.args[1:])
	root, screenshot := opts.root, opts.screenshot
	load_settings()
	if opts.zoom != 0 {
		ui.zoom_wanted = opts.zoom
	}
	ignore_child_exits()

	rl.SetTraceLogLevel(.WARNING)
	rl.SetConfigFlags(WINDOW_FLAGS)
	// Start small, then grow to fit the screen: macOS silently shrinks a window
	// that does not fit above the Dock, and raylib would keep the old size.
	rl.InitWindow(1100, 680, "diskfull")
	if !rl.IsWindowReady() {
		fmt.eprintln("diskfull: could not open a window (no display available?)")
		os.exit(1)
	}
	mon := rl.GetCurrentMonitor()
	mw, mh := rl.GetMonitorWidth(mon), rl.GetMonitorHeight(mon)
	ww, wh := min(1440, mw - 80), min(900, mh - 170)
	rl.SetWindowSize(ww, wh)
	rl.SetWindowPosition((mw - ww) / 2, max((mh - wh) / 2 - 30, 40))
	rl.SetWindowMinSize(900, 560)
	rl.SetExitKey(.KEY_NULL)
	rl.SetTargetFPS(60)
	app.hover_tile = -1

	start_scan(root)

	screenshot_frames := 0
	for !rl.WindowShouldClose() {
		if rl.IsKeyPressed(.Q) {
			break
		}
		update()
		rl.BeginDrawing()
		rl.ClearBackground(COL_BG)
		begin_zoom()
		draw()
		draw_zoom_badge()
		end_zoom()
		if screenshot != "" && scanner_done(app.scanner) {
			screenshot_frames += 1
			if screenshot_frames == 5 { // let the layout settle
				ok := save_screenshot(screenshot)
				s := app.scanner
				fmt.printfln("%s: %s, %s, %s unreadable folders, %.1f s -> %s", s.root_path, format_size(s.root.size), format_files(s.root.files), format_count(s.denied), time.duration_seconds(s.elapsed), screenshot if ok else "screenshot FAILED")
				os.exit(0 if ok else 1)
			}
		}
		rl.EndDrawing()
		free_all(context.temp_allocator)
	}
	rl.CloseWindow()
}

// Saves the frame being drawn; call it before EndDrawing.
save_screenshot :: proc(path: string) -> bool {
	rlgl.DrawRenderBatchActive()
	w, h := rl.GetRenderWidth(), rl.GetRenderHeight()
	pixels := rlgl.ReadScreenPixels(w, h)
	defer rl.MemFree(pixels)
	img := rl.Image {
		data    = pixels,
		width   = w,
		height  = h,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	return bool(rl.ExportImage(img, strings.clone_to_cstring(path, context.temp_allocator)))
}

start_scan :: proc(path: string) {
	resolved := absolute_path(path)
	if app.scanner != nil {
		scanner_destroy(app.scanner)
	}
	app.view = nil
	app.layout_view = nil
	app.largest_view = nil
	app.hover_tile = -1
	app.panel_hover = nil
	clear(&app.layout.tiles)
	clear(&app.largest)
	app.layout.top = nil

	app.scanner = scanner_start(resolved)
	delete(app.disk.mount)
	app.disk, app.disk_ok = volume_info(strings.clone_to_cstring(resolved, context.temp_allocator))
	// volume_info's strings are temporary.
	app.disk.mount = strings.clone(app.disk.mount)
	app.disk.container = ""
	// Scanning a whole volume: what the scan did not find is hidden somewhere.
	app.whole_disk = app.disk_ok && app.disk.mount == resolved
	rl.SetWindowTitle(cs("diskfull — %s", resolved))
}

map_rect :: proc() -> rl.Rectangle {
	w, h := view_w(), view_h()
	return {4, TOP_H + 4, w - panel_width() - 8, h - TOP_H - STATUS_H - 8}
}

panel_rect :: proc() -> rl.Rectangle {
	w, h := view_w(), view_h()
	return {w - panel_width(), TOP_H, panel_width(), h - TOP_H - STATUS_H}
}

// Narrower in small views (small windows, zoomed in) so the map keeps room.
panel_width :: proc() -> f32 {
	return clamp(view_w() * 0.3, 280, PANEL_W)
}

update :: proc() {
	s := app.scanner
	if update_zoom() {
		app.layout.font = fonts[.Small]
		app.layout_view = nil // tile labels were fitted with the old fonts
	}

	if rl.IsFileDropped() {
		files := rl.LoadDroppedFiles()
		dropped := strings.clone(string(files.paths[0]), context.temp_allocator) if files.count > 0 else ""
		rl.UnloadDroppedFiles(files)
		if dropped != "" && os.is_dir(dropped) {
			start_scan(dropped)
			return
		}
	}
	if rl.IsKeyPressed(.R) {
		start_scan(strings.clone(s.root_path, context.temp_allocator))
		return
	}
	if app.view == nil {
		app.view = s.root
	}
	// The map and panel show the tree while it is being scanned.
	scanning := !scanner_done(s)

	if (rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.UP)) && app.view.parent != nil {
		app.view = app.view.parent
	}
	if rl.IsKeyPressed(.HOME) {
		app.view = s.root
	}
	if rl.IsKeyPressed(.TAB) {
		app.panel_mode = .Largest if app.panel_mode == .Contents else .Contents
	}
	if rl.IsKeyPressed(.C) {
		app.color_mode = .Kind if app.color_mode == .Folder else .Folder
	}

	mr := map_rect()
	clock := rl.GetTime()
	changed := app.view != app.layout_view || mr != app.layout_rect || app.color_mode != app.layout_mode
	if changed || app.layout.live != scanning || (scanning && clock - app.layout_time > LIVE_REFRESH) {
		app.layout.mode, app.layout.live = app.color_mode, scanning
		layout_build(&app.layout, app.view, mr)
		app.layout_view, app.layout_rect, app.layout_mode, app.layout_time = app.view, mr, app.color_mode, clock
	}
	if app.panel_mode == .Largest && !scanning && app.largest_view != app.view {
		clear(&app.largest)
		collect_largest(app.view)
		app.largest_view = app.view
	}

	app.hover_tile = -1
	mouse := mouse_pos()
	if !rl.CheckCollisionPointRec(mouse, mr) {
		return
	}
	tiles := app.layout.tiles[:]
	#reverse for t, i in tiles {
		if rl.CheckCollisionPointRec(mouse, t.rect) {
			app.hover_tile = i
			break
		}
	}
	if app.hover_tile < 0 {
		return
	}
	t := tiles[app.hover_tile]
	if rl.IsMouseButtonPressed(.LEFT) {
		if t.rest > 0 {
			open_folder(node_path(t.node))
		} else {
			reveal_in_file_manager(node_path(t.node))
		}
	}
	if rl.IsMouseButtonPressed(.RIGHT) {
		target := t.node
		if t.rest == 0 && .Dir not_in target.flags {
			target = target.parent
		}
		zoom_to(target)
	}

	// Scroll: zoom one level in toward the mouse, or back out. Trackpads send
	// lots of small deltas, so accumulate and rate-limit.
	now := rl.GetTime()
	if w := rl.GetMouseWheelMove(); w != 0 && !zoom_keys_down() { // with Ctrl, the wheel sets the text size
		app.wheel += w
		app.wheel_last = now
	} else if now - app.wheel_last > 0.3 {
		app.wheel = 0
	}
	if abs(app.wheel) >= 1 && now - app.wheel_zoom > 0.3 {
		if app.wheel > 0 {
			zoom_toward(t.node)
		} else if app.view.parent != nil {
			app.view = app.view.parent
		}
		app.wheel = 0
		app.wheel_zoom = now
	}
}

zoom_to :: proc(n: ^Node) {
	if n != nil && .Dir in n.flags && node_size(n) > 0 && len(live_children(n)) > 0 {
		app.view = n
	}
}

// Zoom into the child of the current view that contains `target`.
zoom_toward :: proc(target: ^Node) {
	c := target
	for c != nil && c.parent != app.view {
		c = c.parent
	}
	zoom_to(c)
}

// Children are sorted biggest first and a folder is never smaller than any
// file inside it, so whole subtrees can be skipped once the list is full.
collect_largest :: proc(n: ^Node) {
	if .Dir in n.flags {
		for c in n.children {
			if c.size <= 0 || (len(app.largest) == LARGEST_COUNT && c.size <= app.largest[LARGEST_COUNT - 1].size) {
				break
			}
			collect_largest(c)
		}
		return
	}
	i := len(app.largest)
	for i > 0 && app.largest[i - 1].size < n.size {
		i -= 1
	}
	if i >= LARGEST_COUNT {
		return
	}
	inject_at(&app.largest, i, n)
	if len(app.largest) > LARGEST_COUNT {
		pop(&app.largest)
	}
}

draw :: proc() {
	if app.view == nil {
		return
	}
	draw_map()
	draw_top_bar()
	draw_panel()
	draw_status()
	draw_tooltip()
}

draw_map :: proc() {
	tiles := app.layout.tiles[:]
	if len(tiles) == 0 && !scanner_done(app.scanner) {
		// The first folders are not done yet.
		mr := map_rect()
		cw := min(mr.width - 40, 600)
		x, y := mr.x + (mr.width - cw) / 2, mr.y + mr.height / 2 - 40
		text(fit(strings.concatenate({"Scanning ", app.scanner.root_path, " …"}, context.temp_allocator), cw, .Large), x, y, .Large)
		y += 36
		for line in wrap(PERMISSION_HINT, cw, .Small) {
			text(line, x, y, .Small, COL_DIM)
			y += 16
		}
		return
	}
	for t in tiles {
		r := t.rect
		if t.rest == 0 && .Dir in t.node.flags {
			rl.DrawRectangleRec(r, t.color)
			if t.label != nil {
				text(t.label, r.x + 4, r.y + 2, .Small, {255, 255, 255, 220})
			}
			continue
		}
		if r.width > 3 && r.height > 3 {
			r = {r.x + 0.5, r.y + 0.5, r.width - 1, r.height - 1}
		}
		// Cheap "cushion": light top-left, dark bottom-right.
		light := rl.ColorBrightness(t.color, 0.22)
		dark := rl.ColorBrightness(t.color, -0.30)
		rl.DrawRectangleGradientEx(r, light, t.color, dark, t.color)
		if t.rest > 0 && r.width >= 80 && r.height >= 18 {
			text(fit(fmt.tprintf("%d small items", t.rest), r.width - 8, .Small), r.x + 4, r.y + 3, .Small, {255, 255, 255, 150})
		}
		if t.label != nil {
			text(t.label, r.x + 4, r.y + 3, .Small, {0, 0, 0, 210})
			if t.label2 != nil {
				text(t.label2, r.x + 4, r.y + 18, .Small, {0, 0, 0, 150})
			}
		}
	}
	if app.panel_hover != nil {
		for t in tiles {
			if t.node == app.panel_hover && t.rest == 0 {
				rl.DrawRectangleRec(t.rect, {255, 255, 255, 50})
				rl.DrawRectangleLinesEx(t.rect, 2, rl.WHITE)
			}
		}
	}
	if app.hover_tile >= 0 {
		r := tiles[app.hover_tile].rect
		rl.DrawRectangleRec(r, {255, 255, 255, 40})
		rl.DrawRectangleLinesEx(r, 2, rl.WHITE)
	}
}

draw_top_bar :: proc() {
	w := view_w()
	rl.DrawRectangleRec({0, 0, w, TOP_H}, COL_PANEL)
	rl.DrawRectangleRec({0, TOP_H - 1, w, 1}, COL_LINE)

	info := cs("%s   ·   %s", format_size(node_size(app.view)), format_files(node_files(app.view)))
	info_w := text_width(info)
	text_right(info, w - 16, 14, .Normal, COL_DIM)

	// Breadcrumbs, dropping leading ones when they do not fit.
	chain := make([dynamic]^Node, context.temp_allocator)
	for n := app.view; n != nil; n = n.parent {
		inject_at(&chain, 0, n)
	}
	sep: cstring = "  ›  "
	sep_w := text_width(sep)
	avail := w - info_w - 60
	first := 0
	total: f32
	#reverse for n, i in chain {
		total += text_width(strings.clone_to_cstring(to_nfc(n.name), context.temp_allocator)) + sep_w
		if total > avail {
			first = i + 1
			break
		}
	}
	first = min(first, len(chain) - 1)
	x: f32 = 16
	if first > 0 {
		text("…", x, 14, .Normal, COL_DIM)
		x += text_width("…") + sep_w
	}
	for n, i in chain[first:] {
		label := strings.clone_to_cstring(to_nfc(n.name), context.temp_allocator)
		lw := text_width(label)
		last := first + i == len(chain) - 1
		b := button({x - 4, 6, lw + 8, TOP_H - 12})
		if b.hover && !last {
			rl.DrawRectangleRounded({x - 4, 8, lw + 8, TOP_H - 16}, 0.3, 6, COL_LINE)
		}
		if b.clicked {
			app.view = n
		}
		text(label, x, 14, .Normal, COL_TEXT if last else COL_DIM)
		x += lw
		if !last {
			text(sep, x, 14, .Normal, COL_DIM)
			x += sep_w
		}
	}
}

draw_panel :: proc() {
	pr := panel_rect()
	rl.DrawRectangleRec(pr, COL_PANEL)
	rl.DrawRectangleRec({pr.x, pr.y, 1, pr.height}, COL_LINE)
	app.panel_hover = nil

	x, y, w := pr.x + 16, pr.y + 14, pr.width - 32
	s := app.scanner
	scanning := !scanner_done(s)
	scanned := node_size(s.root)
	purgeable := sync.atomic_load(&s.purgeable)
	denied := sync.atomic_load(&s.denied)

	if app.disk_ok {
		total, used, free := app.disk.total, app.disk.used, app.disk.free
		hidden := max(used - scanned, 0) if app.whole_disk && !scanning else 0

		text("DISK", x, y, .Small, COL_DIM)
		text_right(fit(app.disk.mount, w - 60, .Small), x + w, y, .Small, COL_DIM)
		y += 20

		bar := rl.Rectangle{x, y, w, 10}
		rl.DrawRectangleRounded(bar, 1, 8, COL_LINE)
		seg_x := x
		segments := [?]struct {
			bytes: i64,
			color: rl.Color,
		}{{min(scanned, used), COL_ACCENT}, {hidden, COL_WARN}}
		for seg in segments {
			sw := w * f32(f64(seg.bytes) / f64(max(total, 1)))
			if sw >= 1 {
				rl.DrawRectangleRec({seg_x, y, sw, 10}, seg.color)
			}
			seg_x += sw
		}
		y += 22

		row :: proc(label: cstring, value: i64, x, y, w: f32, dot: Maybe(rl.Color) = nil) {
			tx := x
			if c, ok := dot.?; ok {
				rl.DrawRectangleRounded({x, y + 4, 8, 8}, 1, 6, c)
				tx += 14
			}
			text(label, tx, y, .Normal, COL_DIM)
			text_right(cs("%s", format_size(value)), x + w, y)
		}
		if app.whole_disk {
			row("Found so far" if scanning else "Found by scan", scanned, x, y, w, COL_ACCENT); y += 20
			if purgeable > 0 {
				row("   of which purgeable", purgeable, x, y, w); y += 20
			}
			if !scanning {
				row("Hidden from scan", hidden, x, y, w, COL_WARN); y += 20
			}
			row("Free", free, x, y, w, COL_LINE); y += 20
			row("Disk size", total, x, y, w); y += 24
		} else {
			row("This folder", scanned, x, y, w, COL_ACCENT); y += 20
			row("Used on disk", used, x, y, w); y += 20
			row("Free", free, x, y, w); y += 24
		}
		if app.whole_disk && f64(hidden) > 0.03 * f64(used) {
			for line in wrap(HIDDEN_HINT, w, .Small) {
				text(line, x, y, .Small, COL_DIM)
				y += 15
			}
			y += 6
		}
	}
	if denied > 0 {
		text(cs("%s could not be read", "1 folder" if denied == 1 else fmt.tprintf("%s folders", format_count(denied))), x, y, .Small, COL_WARN)
		y += 15
		text(DENIED_HINT, x, y, .Small, COL_DIM)
		y += 21
	}

	rl.DrawRectangleRec({pr.x, y, pr.width, 1}, COL_LINE)
	y += 1

	// Tabs
	tab_w := pr.width / 2
	tabs := [Panel_Mode]cstring {
		.Contents = "This folder",
		.Largest  = "Largest files",
	}
	for label, mode in tabs {
		tr := rl.Rectangle{pr.x + f32(mode) * tab_w, y, tab_w, 34}
		b := button(tr)
		if b.clicked {
			app.panel_mode = mode
		}
		active := app.panel_mode == mode
		lw := text_width(label)
		text(label, tr.x + (tab_w - lw) / 2, tr.y + 9, .Normal, COL_TEXT if active || b.hover else COL_DIM)
		if active {
			rl.DrawRectangleRec({tr.x + 16, tr.y + 32, tab_w - 32, 2}, COL_ACCENT)
		}
	}
	y += 34
	rl.DrawRectangleRec({pr.x, y, pr.width, 1}, COL_LINE)
	y += 6

	ROW_H :: 38
	bottom := pr.y + pr.height - 24 // keep room for the "+ N more" line
	// Rows, biggest first. While scanning, they are the children the map was
	// laid out with, sizes included, so both agree.
	nodes: []^Node
	if app.panel_mode == .Largest && scanning {
		text("Shown when the scan is done.", x, y + 6, .Small, COL_DIM)
	} else if app.panel_mode == .Largest {
		nodes = app.largest[:]
	} else if !scanning {
		nodes = app.view.children
	}
	top := app.layout.top if app.panel_mode == .Contents else nil
	count := len(top) if scanning else len(nodes)
	total: i64
	if scanning {
		for c in top {
			total += c.size
		}
	} else {
		total = node_size(app.view)
	}
	shown := 0
	for i in 0 ..< count {
		n: ^Node
		size: i64
		if scanning {
			n, size = top[i].node, top[i].size
		} else {
			n = nodes[i]
			size = node_size(n)
		}
		if size <= 0 {
			break
		}
		if y + ROW_H > bottom {
			remaining := count - shown
			text(cs("+ %s more", format_count(i64(remaining))), x, y + 6, .Small, COL_DIM)
			break
		}
		rr := rl.Rectangle{pr.x + 1, y, pr.width - 1, ROW_H}
		b := button(rr)
		if b.hover {
			rl.DrawRectangleRec(rr, {255, 255, 255, 14})
			app.panel_hover = n
		}
		is_dir := .Dir in n.flags

		swatch := rl.ColorFromHSV(branch_hue(i), 0.52, 0.76)
		if app.panel_mode == .Largest || app.color_mode == .Kind {
			hue, sat := kind_color(n.name)
			swatch = rl.ColorFromHSV(hue, sat, 0.78)
		}
		if is_dir && app.color_mode == .Kind {
			swatch = rl.ColorFromHSV(0, 0, 0.45)
		}
		rl.DrawRectangleRounded({x, y + 7, 10, 10}, 0.3 if is_dir else 1, 6, swatch)

		size_s := cs("%s", format_size(size))
		size_w := text_width(size_s)
		name := strings.concatenate({n.name, "/" if is_dir else ""}, context.temp_allocator)
		text(fit(name, w - 18 - size_w - 10), x + 18, y + 4)
		text_right(size_s, x + w, y + 4, .Normal, COL_DIM)

		if app.panel_mode == .Contents {
			pct := f64(size) / f64(max(total, 1))
			bw := w - 18 - 48
			rl.DrawRectangleRec({x + 18, y + 25, bw, 3}, COL_LINE)
			rl.DrawRectangleRec({x + 18, y + 25, bw * f32(pct), 3}, swatch)
			text_right(cs("%s", format_pct(pct)), x + w, y + 20, .Small, COL_DIM)
		} else {
			text(fit(node_path(n.parent), w - 18, .Small), x + 18, y + 21, .Small, COL_DIM)
		}

		if b.clicked {
			if app.panel_mode == .Contents && is_dir && len(live_children(n)) > 0 {
				app.view = n
			} else {
				reveal_in_file_manager(node_path(n))
			}
		}
		if b.right_clicked {
			reveal_in_file_manager(node_path(n))
		}
		y += ROW_H
		shown += 1
	}
}

draw_status :: proc() {
	w, h := view_w(), view_h()
	y := h - STATUS_H
	rl.DrawRectangleRec({0, y, w, STATUS_H}, COL_PANEL)
	rl.DrawRectangleRec({0, y, w, 1}, COL_LINE)

	s := app.scanner
	if !scanner_done(s) {
		draw_scan_progress(y, w)
		return
	}
	right := cs("%s in %.1f s   ·   C: colors (%s)", format_files(s.root.files), time.duration_seconds(s.elapsed), "folders" if app.color_mode == .Folder else "file types")
	text_right(right, w - 12, y + 7, .Small, COL_DIM)

	hovered: ^Node = app.panel_hover
	if hovered == nil && app.hover_tile >= 0 {
		hovered = app.layout.tiles[app.hover_tile].node
	}
	left_w := w - text_width(right, .Small) - 40
	if hovered != nil {
		text(fit(node_path(hovered), left_w, .Small), 12, y + 7, .Small)
	} else {
		text(fit("Click: show in " + FILE_MANAGER + "   ·   Right-click / scroll up: zoom in   ·   Backspace / scroll down: zoom out   ·   Tab: largest files   ·   R: rescan   ·   " + MOD_KEY + " +/-: text size   ·   Drop a folder to scan it", left_w, .Small), 12, y + 7, .Small, COL_DIM)
	}
}

// The status bar while scanning: a progress line on its top edge (a real
// fraction when scanning a whole disk: found / used), counts and the folder
// being read, or the hovered item's path.
draw_scan_progress :: proc(y, w: f32) {
	s := app.scanner
	elapsed := time.duration_seconds(time.tick_since(s.start))
	bytes := sync.atomic_load(&s.bytes)
	right: cstring
	if app.whole_disk && app.disk.used > 0 {
		frac := clamp(f64(bytes) / f64(app.disk.used), 0, 1)
		rl.DrawRectangleRec({0, y, w * f32(frac), 2}, COL_ACCENT)
		right = cs("Scanning   ·   %s files   ·   %s of %s   ·   %.0f s", format_count(sync.atomic_load(&s.files)), format_size(bytes), format_size(app.disk.used), elapsed)
	} else {
		seg := w * 0.2
		p := f32(elapsed * 0.5 - math.floor(elapsed * 0.5))
		rl.DrawRectangleRec({(w + seg) * p - seg, y, seg, 2}, COL_ACCENT)
		right = cs("Scanning   ·   %s files   ·   %s   ·   %.0f s", format_count(sync.atomic_load(&s.files)), format_size(bytes), elapsed)
	}
	text_right(right, w - 12, y + 7, .Small, COL_DIM)

	left_w := w - text_width(right, .Small) - 40
	hovered: ^Node = app.panel_hover
	if hovered == nil && app.hover_tile >= 0 {
		hovered = app.layout.tiles[app.hover_tile].node
	}
	if hovered != nil {
		text(fit(node_path(hovered), left_w, .Small), 12, y + 7, .Small)
	} else if cur := sync.atomic_load(&s.current); cur != nil {
		text(fit(node_path(cur), left_w, .Small), 12, y + 7, .Small, COL_DIM)
	}
}

draw_tooltip :: proc() {
	if app.hover_tile < 0 {
		return
	}
	t := app.layout.tiles[app.hover_tile]
	n := t.node
	path := node_path(n)
	is_dir := .Dir in n.flags

	MAX_W :: 440
	inner: f32 = MAX_W - 24

	Line :: struct {
		s:     cstring,
		size:  Font_Size,
		color: rl.Color,
		gap:   f32,
	}
	lines := make([dynamic]Line, context.temp_allocator)

	size := t.rest_size if t.rest > 0 else node_size(n)
	title := cs("%d smaller items", t.rest) if t.rest > 0 else fit(n.name, inner, .Large)
	append(&lines, Line{title, .Large, COL_TEXT, 0})
	for l, i in wrap(path, inner, .Small) {
		append(&lines, Line{l, .Small, COL_DIM, 4 if i == 0 else 0})
	}
	pct_view := format_pct(f64(size) / f64(max(node_size(app.view), 1)))
	details := cs("%s   ·   %s of this view", format_size(size), pct_view)
	if app.disk_ok {
		details = cs("%s   ·   %s of this view   ·   %s of disk", format_size(size), pct_view, format_pct(f64(size) / f64(max(app.disk.total, 1))))
	}
	append(&lines, Line{details, .Normal, COL_TEXT, 8})
	if is_dir && t.rest == 0 {
		append(&lines, Line{cs("%s", format_files(node_files(n))), .Small, COL_DIM, 2})
	}
	if t.rest == 0 && .Denied in n.flags {
		append(&lines, Line{"Could not read this folder (permission denied)", .Small, COL_WARN, 4})
	}
	if t.rest == 0 && .Clone in n.flags {
		for l, i in wrap("APFS clone: shares its data with another file, so only the bytes it does not share are counted.", inner, .Small) {
			append(&lines, Line{l, .Small, COL_DIM, 4 if i == 0 else 0})
		}
	}
	if t.rest == 0 && .Purgeable in n.flags {
		for l, i in wrap("Purgeable: macOS deletes this file by itself when the disk runs low on space.", inner, .Small) {
			append(&lines, Line{l, .Small, COL_TIP, 4 if i == 0 else 0})
		}
	}
	if note := note_for(path); note != "" {
		for l, i in wrap(note, inner, .Small) {
			append(&lines, Line{l, .Small, COL_TIP, 8 if i == 0 else 0})
		}
	}
	hint: cstring = "Click: open this folder   ·   Right-click: zoom in" if t.rest > 0 else "Click: show in " + FILE_MANAGER + "   ·   Right-click: zoom in" if is_dir else "Click: show in " + FILE_MANAGER
	append(&lines, Line{hint, .Small, COL_DIM, 10})

	bw, bh: f32 = 0, 12
	for l in lines {
		bw = max(bw, text_width(l.s, l.size))
		bh += l.gap + f32(l.size) + 4
	}
	bw += 24
	bh += 8

	sw, sh := view_w(), view_h()
	m := mouse_pos()
	bx, by := m.x + 18, m.y + 18
	if bx + bw > sw - 8 {
		bx = m.x - bw - 12
	}
	if by + bh > sh - 8 {
		by = m.y - bh - 12
	}
	bx, by = max(bx, 8), max(by, 8)

	rl.DrawRectangleRounded({bx + 2, by + 3, bw, bh}, 0.06, 8, {0, 0, 0, 90})
	rl.DrawRectangleRounded({bx, by, bw, bh}, 0.06, 8, {40, 41, 46, 245})
	rl.DrawRectangleRoundedLinesEx({bx, by, bw, bh}, 0.06, 8, 1, COL_LINE)
	y := by + 12
	for l in lines {
		y += l.gap
		text(l.s, bx + 12, y, l.size, l.color)
		y += f32(l.size) + 4
	}
}
