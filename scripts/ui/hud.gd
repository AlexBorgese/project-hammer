# In-game HUD: run timer, destruction percentage, and coin balance, all driven
# by signals from GameManager, StructuralManager and CurrencyManager.
class_name Hud
extends CanvasLayer

@onready var timer_label: Label = $TimerLabel
@onready var destruction_label: Label = $DestructionLabel
@onready var destruction_bar: ProgressBar = $DestructionBar
@onready var coins_label: Label = $CoinsLabel

var _game_manager: Node
var _currency: Node


# Autoloads resolved at runtime rather than by bare identifier — see the note
# in structural_manager.gd for why.
func _gm() -> Node:
	if _game_manager == null or not is_instance_valid(_game_manager):
		_game_manager = get_node_or_null("/root/GameManager")
	return _game_manager


func _cm() -> Node:
	if _currency == null or not is_instance_valid(_currency):
		_currency = get_node_or_null("/root/CurrencyManager")
	return _currency


func _ready() -> void:
	var gm := _gm()
	var cm := _cm()
	if gm == null or cm == null:
		push_error("Hud: autoloads not found. Check Project Settings > Autoload.")
		return
	gm.timer_ticked.connect(_on_timer_ticked)
	gm.level_completed.connect(_on_level_completed)
	cm.balance_changed.connect(_on_balance_changed)
	_on_balance_changed(cm.get_balance())
	_on_timer_ticked(0.0)
	_spawn_level_complete()
	_connect_structural_manager()


# Every level with a HUD gets a results screen, without adding it per level.
func _spawn_level_complete() -> void:
	var scene := load("res://scenes/ui/level_complete.tscn") as PackedScene
	if scene == null:
		push_warning("Hud: level_complete.tscn missing; no results screen.")
		return
	add_child(scene.instantiate())
	# F3 profiling overlay — script-only, no scene needed.
	add_child(PerfOverlay.new())


# Polls rather than waiting a fixed number of frames — the StructuralManager's
# own startup does a variable amount of work before it registers itself.
func _connect_structural_manager() -> void:
	var gm := _gm()
	if gm == null:
		return
	# After Retry reloads the scene, GameManager still holds the *old*, freed
	# manager until the new one registers. A plain null check would latch onto
	# the dead one, so require a live manager that's actually in the tree.
	for _attempt in 120:
		if _is_live(gm.structural_manager):
			break
		await get_tree().process_frame

	var manager = gm.structural_manager
	if not _is_live(manager):
		push_warning("Hud: no StructuralManager registered; destruction % will not update.")
		return
	manager.destruction_changed.connect(_on_destruction_changed)
	_on_destruction_changed(manager.destruction_percentage)


func _is_live(node) -> bool:
	return is_instance_valid(node) and node.is_inside_tree()


func _on_timer_ticked(time: float) -> void:
	timer_label.text = _gm().format_time(time)


func _on_destruction_changed(percentage: float) -> void:
	destruction_label.text = "Demolished: %d%%" % int(round(percentage * 100.0))
	destruction_bar.value = percentage * 100.0


func _on_balance_changed(balance: int) -> void:
	coins_label.text = "%d coins" % balance


func _on_level_completed(time: float) -> void:
	timer_label.text = _gm().format_time(time)
