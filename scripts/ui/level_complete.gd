# End-of-level results: time, tier, coins, top-3 leaderboard, and buttons to
# retry or keep smashing. Hidden until GameManager reports the level complete.
# Builds its own UI in code, so the .tscn is a single node.
class_name LevelComplete
extends CanvasLayer

const TIER_COLOURS := {
	"Gold": Color(1.0, 0.82, 0.25),
	"Silver": Color(0.78, 0.8, 0.85),
	"Bronze": Color(0.8, 0.52, 0.3),
}
const HIGHLIGHT := Color(1.0, 0.95, 0.5)
const DIM := Color(0.75, 0.75, 0.78)

## Pause the world while the results are up. Debris freezes mid-air, which
## doubles as a nice "freeze frame" on the final collapse.
@export var pause_on_complete: bool = true

var _time_label: Label
var _tier_label: Label
var _coins_label: Label
var _demolished_label: Label
var _board: VBoxContainer
var _retry_button: Button


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false
	var gm := get_node_or_null("/root/GameManager")
	if gm == null:
		push_error("LevelComplete: GameManager autoload not found.")
		return
	gm.level_completed.connect(_on_level_completed)


# --- Showing results ----------------------------------------------------------

func _on_level_completed(time: float) -> void:
	var gm := get_node_or_null("/root/GameManager")
	var cm := get_node_or_null("/root/CurrencyManager")
	var lb := get_node_or_null("/root/LeaderboardManager")
	if gm == null or cm == null or lb == null:
		return

	_time_label.text = gm.format_time(time)
	_show_tier(cm.get_tier(time), cm.get_reward(time), cm.get_balance())
	_show_demolished(gm)
	_show_leaderboard(lb.get_times(gm.current_level_id), time, gm)

	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if pause_on_complete:
		get_tree().paused = true
	_retry_button.grab_focus()


func _show_tier(tier: String, reward: int, balance: int) -> void:
	_tier_label.text = tier.to_upper()
	_tier_label.add_theme_color_override("font_color", TIER_COLOURS.get(tier, DIM))
	_coins_label.text = "+%d coins   (total %d)" % [reward, balance]


func _show_demolished(gm: Node) -> void:
	var manager = gm.structural_manager
	if manager == null or not is_instance_valid(manager):
		_demolished_label.text = ""
		return
	_demolished_label.text = "Demolished %d%%" % roundi(manager.destruction_percentage * 100.0)


# Times come back sorted fastest-first. The run that just finished gets
# highlighted if it made the top 3.
func _show_leaderboard(times: Array, this_run: float, gm: Node) -> void:
	for child in _board.get_children():
		child.queue_free()
	var highlighted := false
	for i in 3:
		var line := Label.new()
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		if i < times.size():
			var t: float = times[i]
			line.text = "%d.   %s" % [i + 1, gm.format_time(t)]
			var is_this := not highlighted and is_equal_approx(t, this_run)
			if is_this:
				highlighted = true
				line.text += "   ← new"
			line.add_theme_color_override("font_color", HIGHLIGHT if is_this else DIM)
		else:
			line.text = "%d.   --:--.--" % (i + 1)
			line.add_theme_color_override("font_color", DIM)
		_board.add_child(line)


# --- Buttons ------------------------------------------------------------------

func _on_retry_pressed() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()


# Close the panel and let the player finish flattening the place. The timer is
# already stopped, so this is purely for fun.
func _on_keep_smashing_pressed() -> void:
	visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# --- UI construction ----------------------------------------------------------

func _build_ui() -> void:
	var root := Control.new()
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	root.add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var centre := CenterContainer.new()
	root.add_child(centre)
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	centre.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	column.add_child(_label("DEMOLISHED", 22, DIM))
	_time_label = _label("00:00.00", 56, Color.WHITE)
	column.add_child(_time_label)
	_tier_label = _label("", 34, DIM)
	column.add_child(_tier_label)
	_coins_label = _label("", 18, Color.WHITE)
	column.add_child(_coins_label)
	_demolished_label = _label("", 16, DIM)
	column.add_child(_demolished_label)

	column.add_child(HSeparator.new())
	column.add_child(_label("BEST TIMES", 16, DIM))
	_board = VBoxContainer.new()
	column.add_child(_board)
	column.add_child(HSeparator.new())

	column.add_child(_build_buttons())


func _build_buttons() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)

	_retry_button = Button.new()
	_retry_button.text = "Retry"
	_retry_button.custom_minimum_size = Vector2(150, 40)
	_retry_button.pressed.connect(_on_retry_pressed)
	row.add_child(_retry_button)

	var keep := Button.new()
	keep.text = "Keep Smashing"
	keep.custom_minimum_size = Vector2(150, 40)
	keep.pressed.connect(_on_keep_smashing_pressed)
	row.add_child(keep)
	return row


func _label(text: String, size: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	return label
