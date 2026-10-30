package diskfull

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// Interface zoom, like a browser's Ctrl (Cmd on macOS) +, - and 0. Everything
// is laid out in view units and drawn through a camera scaled by the zoom, and
// the fonts are rasterized at the zoomed size so text stays sharp.

ZOOM_LEVELS := [?]f32{0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3}
ZOOM_MIN :: 0.5
ZOOM_MAX :: 3

// Smallest view the layout is designed for: zooming in stops there.
MIN_VIEW_W :: 640
MIN_VIEW_H :: 400

Zoom_State :: struct {
	zoom_wanted: f32, // chosen by the user
	zoom:        f32, // in effect: zoom_wanted, or less if the window is too small for it
	pixel:       f32, // screen pixels per view unit (zoom × display scale)
	font_zoom:   f32, // zoom the fonts were rasterized for
	wheel:       f32, // Ctrl + wheel deltas not used yet
	shown_at:    f64, // when the zoom last changed, to show it for a moment
}

ui := Zoom_State {
	zoom_wanted = 1,
	zoom        = 1,
	pixel       = 1,
}

view_w :: proc() -> f32 {return f32(rl.GetScreenWidth()) / ui.zoom}
view_h :: proc() -> f32 {return f32(rl.GetScreenHeight()) / ui.zoom}
mouse_pos :: proc() -> rl.Vector2 {return rl.GetMousePosition() / ui.zoom}

// Draws what follows scaled by the zoom. Not BeginMode2D: it would reset the
// transform raylib sets up for high-DPI screens.
begin_zoom :: proc() {
	rlgl.PushMatrix()
	rlgl.Scalef(ui.zoom, ui.zoom, 1)
}

end_zoom :: proc() {
	rlgl.PopMatrix()
}

zoom_keys_down :: proc() -> bool {
	when ODIN_OS == .Darwin {
		if rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER) {
			return true
		}
	}
	return rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
}

// Handles the zoom shortcuts, and reloads the fonts when the zoom in effect
// changes (also on the first call). Returns true when it changed.
update_zoom :: proc() -> bool {
	hit :: proc(keys: ..rl.KeyboardKey) -> bool {
		for k in keys {
			if rl.IsKeyPressed(k) || rl.IsKeyPressedRepeat(k) {
				return true
			}
		}
		return false
	}
	if zoom_keys_down() {
		// Steps start from the zoom in effect, so after hitting the limit of
		// the window, the first zoom out is visible right away.
		step := 0
		if hit(.EQUAL, .KP_ADD) {
			step = 1
		}
		if hit(.MINUS, .KP_SUBTRACT) {
			step = -1
		}
		ui.wheel += rl.GetMouseWheelMove()
		if abs(ui.wheel) >= 1 {
			step = 1 if ui.wheel > 0 else -1
			ui.wheel = 0
		}
		wanted := ui.zoom_wanted
		if step != 0 {
			wanted = zoom_step(ui.zoom, step)
		}
		if hit(.ZERO, .KP_0) {
			wanted = 1
		}
		if step != 0 || wanted != ui.zoom_wanted {
			ui.zoom_wanted = wanted
			ui.shown_at = rl.GetTime()
			save_settings()
		}
	} else {
		ui.wheel = 0
	}

	// Keep to the levels when the window limits the zoom, so resizing the
	// window does not reload the fonts on every frame.
	limit := min(f32(rl.GetScreenWidth()) / MIN_VIEW_W, f32(rl.GetScreenHeight()) / MIN_VIEW_H)
	zoom := ui.zoom_wanted
	if zoom > limit {
		zoom = ZOOM_LEVELS[0]
		for l in ZOOM_LEVELS {
			if l <= limit {
				zoom = l
			}
		}
	}
	if zoom == ui.font_zoom {
		return false
	}
	ui.zoom, ui.font_zoom = zoom, zoom
	ui.pixel = zoom * max(rl.GetWindowScaleDPI().x, 1)
	load_fonts(ui.pixel)
	return true
}

zoom_step :: proc(from: f32, dir: int) -> f32 {
	if dir > 0 {
		for l in ZOOM_LEVELS {
			if l > from + 0.001 {
				return l
			}
		}
		return ZOOM_MAX
	}
	#reverse for l in ZOOM_LEVELS {
		if l < from - 0.001 {
			return l
		}
	}
	return ZOOM_MIN
}

// Shows the zoom level for a moment after it changes, like browsers do.
draw_zoom_badge :: proc() {
	age := rl.GetTime() - ui.shown_at
	if ui.shown_at == 0 || age > 1.6 {
		return
	}
	alpha := f32(clamp((1.6 - age) / 0.3, 0, 1))
	label := cs("%d%%", int(math.round(ui.zoom * 100)))
	if ui.zoom < ui.zoom_wanted - 0.001 {
		label = cs("%d%%   ·   enlarge the window to zoom further", int(math.round(ui.zoom * 100)))
	}
	w := text_width(label) + 28
	r := rl.Rectangle{(view_w() - w) / 2, TOP_H + 14, w, 32}
	rl.DrawRectangleRounded(r, 0.5, 8, rl.Fade({40, 41, 46, 255}, 0.96 * alpha))
	rl.DrawRectangleRoundedLinesEx(r, 0.5, 8, 1, rl.Fade(COL_LINE, alpha))
	text(label, r.x + 14, r.y + 8, .Normal, rl.Fade(COL_TEXT, alpha))
}

// Settings live in a small text file in the platform's config folder.

settings_path :: proc() -> string {
	dir := config_dir()
	if dir == "" {
		return ""
	}
	path, _ := filepath.join({dir, "settings"}, context.temp_allocator)
	return path
}

load_settings :: proc() {
	path := settings_path()
	if path == "" {
		return
	}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return
	}
	s := string(data)
	for line in strings.split_lines_iterator(&s) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "zoom=") {
			if z, ok := strconv.parse_f32(l[len("zoom="):]); ok && z >= ZOOM_MIN && z <= ZOOM_MAX {
				ui.zoom_wanted = z
			}
		}
	}
}

save_settings :: proc() {
	path := settings_path()
	if path == "" {
		return
	}
	_ = os.make_directory_all(config_dir())
	_ = os.write_entire_file_from_string(path, fmt.tprintf("zoom=%.2f\n", ui.zoom_wanted))
}
