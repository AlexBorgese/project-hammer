# F3 profiling overlay: frame and physics timings, worst frame in the last few
# seconds, chunk counts and collapse-check cost. Spawned by the HUD, hidden by
# default, refreshes a few times a second so it doesn't distort what it measures.
class_name PerfOverlay
extends CanvasLayer

## Seconds of history for the "worst frame" figure. A collapse spike is what
## matters, and it's gone from the FPS counter before you can read it.
@export var worst_window: float = 5.0
@export var refresh_interval: float = 0.25

var _label: Label
var _refresh_left: float = 0.0
# [timestamp_sec, frame_ms] pairs inside the window.
var _frames: Array = []


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_label = Label.new()
	_label.position = Vector2(12, 40)
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_color", Color(0.85, 1.0, 0.85))
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	add_child(_label)
	visible = false


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_F3:
		visible = not visible


func _process(delta: float) -> void:
	_track_worst(delta)
	if not visible:
		return
	_refresh_left -= delta
	if _refresh_left > 0.0:
		return
	_refresh_left = refresh_interval
	_label.text = _build_text()


# Each entry: [timestamp_sec, frame_ms, physics_ms].
func _track_worst(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_frames.append([now, delta * 1000.0, physics_ms])
	while not _frames.is_empty() and now - _frames[0][0] > worst_window:
		_frames.pop_front()


func _worst(index: int) -> float:
	var worst := 0.0
	for f in _frames:
		worst = maxf(worst, f[index])
	return worst


func _worst_frame_ms() -> float:
	return _worst(1)


func _build_text() -> String:
	var lines: Array[String] = []
	var fps := Engine.get_frames_per_second()
	var worst := _worst_frame_ms()
	lines.append("FPS %d   worst frame %.1f ms (%d fps) over %ds"
		% [fps, worst, roundi(1000.0 / maxf(worst, 0.001)), roundi(worst_window)])
	# TIME_PROCESS is the whole frame (vsync-capped at ~16.7 ms), not script cost.
	# The physics PEAK is the useful one: it shows whether a hitch was the solver.
	lines.append("frame %.2f ms   physics %.2f ms now   %.2f ms peak"
		% [Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		_worst(2)])
	# Jolt doesn't report the active-object / collision-pair monitors, so they
	# aren't shown; the "awake" chunk count below is counted directly instead.
	lines.append("draw calls %d"
		% Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	lines.append_array(_structure_lines())
	return "\n".join(lines)


func _structure_lines() -> Array[String]:
	var out: Array[String] = []
	var gm := get_node_or_null("/root/GameManager")
	if gm == null:
		return out
	var sm = gm.structural_manager
	if not is_instance_valid(sm):
		out.append("(no StructuralManager)")
		return out
	out.append("chunks %d total   %d destroyed   %d standing structural   %d awake"
		% [sm.get_total_chunks(), sm.get_destroyed_chunks(),
		sm.get_standing_chunks(), sm.count_awake_chunks()])
	out.append("collapse check %.2f ms last   %.2f ms peak   graph build %.1f ms"
		% [sm.last_check_ms, sm.peak_check_ms, sm.graph_build_ms])
	return out
