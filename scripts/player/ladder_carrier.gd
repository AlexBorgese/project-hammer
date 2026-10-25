# Lets the player carry a single ladder, drop it against a surface, and pick it
# back up. The fallback route upstairs once the staircase is rubble.
class_name LadderCarrier
extends Node3D

signal ladder_placed(ladder: Node3D)
signal ladder_recovered

## Ladder scene to place. Set this to res://scenes/items/ladder.tscn.
@export var ladder_scene: PackedScene
## Whether the player starts holding a ladder.
@export var starts_with_ladder: bool = true
## How far in front of the player the ladder is dropped.
@export var place_distance: float = 1.4
## How close you must be to pick a placed ladder back up.
@export var pickup_radius: float = 2.0

var is_carrying: bool = false
var _placed: Node3D
var _player: PlayerController


func _ready() -> void:
	is_carrying = starts_with_ladder
	_player = _find_player()
	if ladder_scene == null:
		push_warning("LadderCarrier: no ladder_scene assigned; placing will do nothing.")


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("place_ladder"):
		return
	if is_carrying:
		_place()
	else:
		_try_recover()


func _place() -> void:
	if ladder_scene == null or _player == null:
		return
	var ladder := ladder_scene.instantiate() as Node3D
	if ladder == null:
		return

	# Drop it in front of the player, flat against whatever it's facing.
	var forward := -_player.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.001:
		forward = Vector3.FORWARD
	forward = forward.normalized()

	get_tree().current_scene.add_child(ladder)
	ladder.global_position = _foot_position() + forward * place_distance
	ladder.global_rotation.y = _player.global_rotation.y

	_placed = ladder
	is_carrying = false
	ladder_placed.emit(ladder)


func _try_recover() -> void:
	if not is_instance_valid(_placed) or _player == null:
		return
	if _player.global_position.distance_to(_placed.global_position) > pickup_radius:
		return
	_placed.queue_free()
	_placed = null
	is_carrying = true
	ladder_recovered.emit()


# Ladders should stand on the ground, not float at chest height.
func _foot_position() -> Vector3:
	if _player == null:
		return global_position
	return Vector3(
		_player.global_position.x,
		_player.global_position.y - 0.9,
		_player.global_position.z
	)


func _find_player() -> PlayerController:
	var node := get_parent()
	while node != null:
		if node is PlayerController:
			return node
		node = node.get_parent()
	return null
