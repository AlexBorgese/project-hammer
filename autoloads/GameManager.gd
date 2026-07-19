# Global game state machine: tracks the current level, run timer, equipment, and
# broadcasts level start/complete events to the rest of the game.
extends Node

signal level_started
signal level_completed(time: float)
signal timer_ticked(time: float)
signal state_changed(new_state: State)

enum State { MENU, PLAYING, LEVEL_COMPLETE }

var state: State = State.MENU
var current_level_id: String = ""
var current_equipment_id: String = "hammer_basic"
var run_time: float = 0.0

# Set by the level's StructuralManager when it registers itself.
var structural_manager: Node = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_input_actions()


# Safety net: registers any action missing from the project input map, so the
# game still plays if project.godot's [input] section is lost or overwritten.
func _ensure_input_actions() -> void:
	_add_key_action("move_forward", KEY_W)
	_add_key_action("move_back", KEY_S)
	_add_key_action("move_left", KEY_A)
	_add_key_action("move_right", KEY_D)
	_add_stick_action("move_left", JOY_AXIS_LEFT_X, -1.0)
	_add_stick_action("move_right", JOY_AXIS_LEFT_X, 1.0)
	_add_stick_action("move_forward", JOY_AXIS_LEFT_Y, -1.0)
	_add_stick_action("move_back", JOY_AXIS_LEFT_Y, 1.0)

	_add_mouse_action("swing", MOUSE_BUTTON_LEFT)
	_add_stick_action("swing_left", JOY_AXIS_RIGHT_X, -1.0)
	_add_stick_action("swing_right", JOY_AXIS_RIGHT_X, 1.0)
	_add_stick_action("swing_up", JOY_AXIS_RIGHT_Y, -1.0)
	_add_stick_action("swing_down", JOY_AXIS_RIGHT_Y, 1.0)


func _ensure_action(action: String) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.2)


func _add_key_action(action: String, keycode: int) -> void:
	_ensure_action(action)
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			return
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	InputMap.action_add_event(action, ev)


func _add_mouse_action(action: String, button: int) -> void:
	_ensure_action(action)
	for event in InputMap.action_get_events(action):
		if event is InputEventMouseButton:
			return
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)


func _add_stick_action(action: String, axis: int, value: float) -> void:
	_ensure_action(action)
	for event in InputMap.action_get_events(action):
		var motion := event as InputEventJoypadMotion
		if motion != null and motion.axis == axis \
				and signf(motion.axis_value) == signf(value):
			return
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	InputMap.action_add_event(action, ev)


func _process(delta: float) -> void:
	if state != State.PLAYING:
		return
	run_time += delta
	timer_ticked.emit(run_time)


func start_level(level_id: String) -> void:
	current_level_id = level_id
	run_time = 0.0
	_set_state(State.PLAYING)
	level_started.emit()


func complete_level() -> void:
	if state != State.PLAYING:
		return
	_set_state(State.LEVEL_COMPLETE)
	var final_time := run_time
	CurrencyManager.award_for_time(final_time)
	LeaderboardManager.submit_time(current_level_id, final_time)
	level_completed.emit(final_time)


func register_structural_manager(manager: Node) -> void:
	structural_manager = manager
	if not manager.building_demolished.is_connected(complete_level):
		manager.building_demolished.connect(complete_level)


func return_to_menu() -> void:
	current_level_id = ""
	run_time = 0.0
	_set_state(State.MENU)


func format_time(seconds: float) -> String:
	var minutes := int(seconds) / 60
	var secs := int(seconds) % 60
	var hundredths := int(fmod(seconds, 1.0) * 100.0)
	return "%02d:%02d.%02d" % [minutes, secs, hundredths]


func _set_state(new_state: State) -> void:
	state = new_state
	state_changed.emit(new_state)
