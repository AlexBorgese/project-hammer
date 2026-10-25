# A placeable ladder. Its Area3D marks a climb volume; the player controller
# checks for it and switches to vertical movement while inside.
class_name Ladder
extends Node3D

signal climber_entered(body: Node3D)
signal climber_exited(body: Node3D)

## Height of the climbable region, in metres.
@export var climb_height: float = 3.2
## How far out from the ladder face you can still grab it.
@export var climb_depth: float = 0.7
@export var climb_width: float = 0.9

@onready var climb_area: Area3D = $ClimbArea
@onready var climb_shape: CollisionShape3D = $ClimbArea/CollisionShape3D


func _ready() -> void:
	_size_climb_volume()
	climb_area.body_entered.connect(_on_body_entered)
	climb_area.body_exited.connect(_on_body_exited)


func _size_climb_volume() -> void:
	if climb_shape == null:
		return
	var box := climb_shape.shape as BoxShape3D
	if box == null:
		box = BoxShape3D.new()
		climb_shape.shape = box
	box.size = Vector3(climb_width, climb_height, climb_depth)
	climb_shape.position = Vector3(0.0, climb_height * 0.5, 0.0)


# The top of the ladder in world space, used to step the player onto the ledge.
func get_top_position() -> Vector3:
	return global_position + global_transform.basis.y * climb_height


func _on_body_entered(body: Node3D) -> void:
	if body is PlayerController:
		body.enter_climb(self)
		climber_entered.emit(body)


func _on_body_exited(body: Node3D) -> void:
	if body is PlayerController:
		body.exit_climb(self)
		climber_exited.emit(body)
