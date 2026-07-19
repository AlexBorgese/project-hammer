# Third-person character controller: camera-relative WASD movement, an
# over-the-shoulder SpringArm3D camera, and stagger knockback when the hammer
# lands a heavy hit.
class_name PlayerController
extends CharacterBody3D

signal stagger_started(duration: float)
signal stagger_ended

@export var move_speed: float = 5.0
@export var acceleration: float = 12.0
@export var jump_velocity: float = 4.5
@export var mouse_sensitivity: float = 0.003
## How far the camera can pitch up/down, in degrees.
@export var min_pitch: float = -60.0
@export var max_pitch: float = 45.0
## How quickly stagger knockback bleeds away. Lower = you slide further.
@export var stagger_friction: float = 3.0
## Speed multiplier while a swing is being wound up.
@export var swing_move_penalty: float = 0.35

@onready var pivot: Node3D = $CameraPivot
@onready var spring_arm: SpringArm3D = $CameraPivot/SpringArm3D

var look_enabled: bool = true
var stagger_time_left: float = 0.0

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _can_look():
		_apply_look(event.relative)
	elif event.is_action_pressed("ui_cancel"):
		_toggle_mouse_capture()


func _can_look() -> bool:
	return look_enabled \
			and stagger_time_left <= 0.0 \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _apply_look(relative: Vector2) -> void:
	rotate_y(-relative.x * mouse_sensitivity)
	pivot.rotate_x(-relative.y * mouse_sensitivity)
	pivot.rotation.x = clampf(
		pivot.rotation.x, deg_to_rad(min_pitch), deg_to_rad(max_pitch)
	)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta

	if stagger_time_left > 0.0:
		_process_stagger(delta)
	else:
		_process_movement(delta)

	move_and_slide()


func _process_movement(delta: float) -> void:
	var target := _get_target_velocity()
	velocity.x = move_toward(velocity.x, target.x, acceleration * delta * move_speed)
	velocity.z = move_toward(velocity.z, target.z, acceleration * delta * move_speed)
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = jump_velocity


# While staggered you have no control — momentum just carries you.
func _process_stagger(delta: float) -> void:
	stagger_time_left -= delta
	velocity.x = move_toward(velocity.x, 0.0, stagger_friction * delta * move_speed)
	velocity.z = move_toward(velocity.z, 0.0, stagger_friction * delta * move_speed)
	if stagger_time_left <= 0.0:
		stagger_ended.emit()


func _get_target_velocity() -> Vector3:
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if input == Vector2.ZERO:
		return Vector3.ZERO
	var direction := (transform.basis * Vector3(input.x, 0.0, input.y)).normalized()
	var speed := move_speed
	if not look_enabled:
		speed *= swing_move_penalty
	return direction * speed


# Called by hammer_swing.gd on a heavy impact.
func apply_stagger(impulse: Vector3, duration: float) -> void:
	velocity += impulse
	stagger_time_left = maxf(stagger_time_left, duration)
	stagger_started.emit(duration)


# Called by hammer_swing.gd: the mouse drives the hammer, not the camera,
# while a swing is in progress.
func set_look_enabled(enabled: bool) -> void:
	look_enabled = enabled


func _toggle_mouse_capture() -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
