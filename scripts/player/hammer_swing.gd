# Core swing mechanic: the hammer is a free rigid body chasing a mouse-driven
# target point via a spring-damper, so it lags, overshoots and swings under its
# own momentum rather than being directly positioned.
class_name HammerSwing
extends Node3D

signal swing_landed(target: Node, force: float)
signal player_staggered(force: float)

@export_group("Follow")
## How hard the hammer is pulled toward the target. Low = laggy and clumsy.
@export var follow_stiffness: float = 55.0
## Resistance to the hammer's own velocity. Low = wobbly, high = sluggish.
@export var follow_damping: float = 3.5
## Ceiling on the follow force so the spring can't teleport a heavy hammer.
@export var max_follow_force: float = 4000.0
## Extra pull applied when you aren't swinging, to bring it back to rest.
@export var idle_stiffness_scale: float = 1.6
## How much of gravity the follow force cancels out. 1.0 = the hammer hangs
## weightless; lower values let it droop and feel heavier in the hand.
@export_range(0.0, 1.0) var gravity_compensation: float = 0.85

@export_group("Aim")
## Pitch the whole rig to match the camera, so looking down lowers the hammer
## and lets you reach ground-floor chunks.
@export var follow_camera_pitch: bool = true
## How much of the camera's pitch the rig copies. 1.0 = fully tracks.
@export_range(0.0, 1.0) var pitch_follow_amount: float = 0.85
## Metres of target travel per pixel of mouse movement.
@export var mouse_to_target: float = 0.012
## How far the target can get from the rest position, in metres.
@export var target_radius: float = 1.9
## How fast the target springs back to rest once you let go.
@export var target_return_speed: float = 6.0

@export_group("Impact")
## Momentum (mass x speed) below this does no damage.
@export var min_impact_momentum: float = 25.0
## Multiplier converting hammer momentum into destructible damage.
@export var impact_scale: float = 1.4
## Seconds of contact immunity so one swing doesn't hit the same chunk twice.
@export var hit_cooldown: float = 0.15

@export_group("Stagger")
## Momentum above this shoves the player around.
@export var stagger_threshold: float = 120.0
## How hard the player gets yanked, per unit of momentum over the threshold.
@export var stagger_scale: float = 0.035
## Seconds the player loses control after a big hit.
@export var stagger_time: float = 0.45

@onready var hammer: RigidBody3D = $Hammer
@onready var rest_point: Node3D = $RestPoint

var is_swinging: bool = false

var _target_offset: Vector3 = Vector3.ZERO
var _recent_hits: Dictionary = {}
var _player: PlayerController
var _camera_pivot: Node3D


func _ready() -> void:
	_player = _find_player()
	_camera_pivot = _find_camera_pivot()
	_setup_hammer()


func _setup_hammer() -> void:
	if hammer == null:
		push_error("HammerSwing: no child named 'Hammer'.")
		return
	# The hammer is never frozen and never parented to the player — it is a
	# free body that merely gets pushed around.
	hammer.freeze = false
	hammer.contact_monitor = true
	hammer.max_contacts_reported = 12
	hammer.continuous_cd = true
	hammer.top_level = true
	hammer.global_transform = rest_point.global_transform
	if not hammer.body_entered.is_connected(_on_hammer_body_entered):
		hammer.body_entered.connect(_on_hammer_body_entered)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("swing"):
		_set_swinging(true)
	elif event.is_action_released("swing"):
		_set_swinging(false)
	elif event is InputEventMouseMotion and is_swinging:
		_drag_target(event.relative)


func _set_swinging(swinging: bool) -> void:
	is_swinging = swinging
	# While swinging, the mouse drives the hammer instead of the camera.
	if _player != null:
		_player.set_look_enabled(not swinging)


func _drag_target(relative: Vector2) -> void:
	var basis := global_transform.basis
	var delta := basis.x * relative.x * mouse_to_target \
			+ basis.y * -relative.y * mouse_to_target
	_target_offset += delta
	if _target_offset.length() > target_radius:
		_target_offset = _target_offset.normalized() * target_radius


func _physics_process(delta: float) -> void:
	_tick_hit_cooldowns(delta)
	_track_camera_pitch()
	if not is_swinging:
		_target_offset = _target_offset.move_toward(
			Vector3.ZERO, target_return_speed * delta
		)
	_apply_follow_force()
	_apply_tumble()


# Looking down swings the whole rig down with you, so the hammer can reach
# ground-floor chunks instead of permanently hovering at hip height.
func _track_camera_pitch() -> void:
	if not follow_camera_pitch or _camera_pivot == null:
		return
	rotation.x = _camera_pivot.rotation.x * pitch_follow_amount


func _find_camera_pivot() -> Node3D:
	if _player == null:
		return null
	return _player.get_node_or_null("CameraPivot") as Node3D


func get_target_position() -> Vector3:
	if rest_point == null:
		return global_position
	return rest_point.global_position + _target_offset


# Classic spring-damper. The stiffness term chases the target, the damping term
# bleeds off velocity so it settles instead of oscillating forever.
func _apply_follow_force() -> void:
	if hammer == null:
		return
	var to_target := get_target_position() - hammer.global_position
	var stiffness := follow_stiffness
	if not is_swinging:
		stiffness *= idle_stiffness_scale
	var force := to_target * stiffness * hammer.mass
	force -= hammer.linear_velocity * follow_damping * hammer.mass
	# Offset most of gravity so the hammer hangs, but leave a little droop.
	force += Vector3.UP * hammer.mass * 9.8 * hammer.gravity_scale * gravity_compensation
	hammer.apply_central_force(force.limit_length(max_follow_force))


# A little torque toward "head down" keeps it tumbling and readable in flight.
func _apply_tumble() -> void:
	if hammer == null:
		return
	var swing_dir := hammer.linear_velocity
	if swing_dir.length_squared() < 1.0:
		return
	var axis := swing_dir.normalized().cross(Vector3.UP)
	if axis.length_squared() > 0.001:
		hammer.apply_torque(axis.normalized() * swing_dir.length() * hammer.mass * 0.15)


func _tick_hit_cooldowns(delta: float) -> void:
	for key in _recent_hits.keys():
		_recent_hits[key] -= delta
		if _recent_hits[key] <= 0.0:
			_recent_hits.erase(key)


func _on_hammer_body_entered(body: Node) -> void:
	var momentum := hammer.linear_velocity.length() * hammer.mass
	if momentum < min_impact_momentum:
		return
	if _recent_hits.has(body):
		return
	_recent_hits[body] = hit_cooldown

	_damage(body, momentum)
	if momentum >= stagger_threshold:
		_stagger(body, momentum)


func _damage(body: Node, momentum: float) -> void:
	var chunk := body as RigidBody3D
	if chunk == null:
		return
	var destructible = chunk.get_meta("destructible", null)
	if destructible == null:
		return
	var dir: Vector3 = (chunk.global_position - hammer.global_position).normalized()
	var force: float = momentum * impact_scale
	destructible.take_damage(chunk, force, dir)
	swing_landed.emit(chunk, force)


# Newton's third law, roughly: hitting something hard shoves you back.
func _stagger(_body: Node, momentum: float) -> void:
	if _player == null:
		return
	var overage := momentum - stagger_threshold
	var push := hammer.linear_velocity.normalized() * overage * stagger_scale
	push.y = absf(push.y) * 0.4 + 1.5
	_player.apply_stagger(push, stagger_time)
	player_staggered.emit(momentum)


func _find_player() -> PlayerController:
	var node := get_parent()
	while node != null:
		if node is PlayerController:
			return node
		node = node.get_parent()
	return null
