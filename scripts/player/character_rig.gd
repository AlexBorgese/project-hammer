# Procedurally poses a primitive character: arms stretch and point at the
# hammer, legs swing on a sine wave driven by movement speed, torso leans into
# the swing. No skeleton and no AnimationPlayer.
class_name CharacterRig
extends Node3D

@export_group("Arms")
## Arms point at the hammer and stretch to reach it.
@export var arms_track_hammer: bool = true
## Resting length of an arm cylinder, in metres. Must match the mesh height.
@export var arm_base_length: float = 0.7
## Arms won't stretch beyond this multiple of their base length.
@export_range(1.0, 3.0) var arm_max_stretch: float = 1.8
## How quickly arms catch up to the hammer. Lower = laggier, more relaxed.
@export var arm_follow_speed: float = 14.0

@export_group("Legs")
@export var legs_animate: bool = true
## Resting length of a leg cylinder, in metres.
@export var leg_base_length: float = 0.8
## Max swing of a leg, in degrees, at full speed.
@export var leg_swing_degrees: float = 38.0
## Stride cycles per metre travelled. Higher = faster leg turnover.
@export var leg_cycles_per_metre: float = 0.55

@export_group("Torso")
@export var torso_leans: bool = true
## Max lean into a swing, in degrees.
@export var torso_lean_degrees: float = 22.0
@export var torso_lean_speed: float = 8.0
## Extra lean-back when the player is staggered.
@export var stagger_lean_degrees: float = 30.0

@export_group("Wiring")
## Leave empty to auto-find the hammer via the player's SwingRig.
@export var hammer_path: NodePath

@onready var torso_pivot: Node3D = get_node_or_null("TorsoPivot")
@onready var shoulder_l: Node3D = get_node_or_null("TorsoPivot/ShoulderL")
@onready var shoulder_r: Node3D = get_node_or_null("TorsoPivot/ShoulderR")
@onready var arm_l: Node3D = get_node_or_null("TorsoPivot/ShoulderL/ArmL")
@onready var arm_r: Node3D = get_node_or_null("TorsoPivot/ShoulderR/ArmR")
@onready var hip_l: Node3D = get_node_or_null("HipL")
@onready var hip_r: Node3D = get_node_or_null("HipR")

var _player: PlayerController
var _hammer: RigidBody3D
var _stride_phase: float = 0.0
var _stride_amplitude: float = 0.0
var _lean: float = 0.0


func _ready() -> void:
	_player = _find_player()
	_hammer = _resolve_hammer()
	if _hammer == null:
		push_warning("CharacterRig: no hammer found; arms will rest.")


func _process(delta: float) -> void:
	if arms_track_hammer:
		_pose_arms(delta)
	if legs_animate:
		_pose_legs(delta)
	if torso_leans:
		_pose_torso(delta)


# --- Arms -------------------------------------------------------------------

func _pose_arms(delta: float) -> void:
	if _hammer == null:
		return
	var target := _hammer.global_position
	_aim_arm(shoulder_l, arm_l, target, delta)
	_aim_arm(shoulder_r, arm_r, target, delta)


# The shoulder is a pivot that gets rotated to face the hammer; the arm mesh
# hangs off it along -Z and is scaled to bridge the gap.
func _aim_arm(shoulder: Node3D, arm: Node3D, target: Vector3, delta: float) -> void:
	if shoulder == null or arm == null:
		return

	var to_target := target - shoulder.global_position
	if to_target.length_squared() < 0.0001:
		return

	var dir := to_target.normalized()
	# looking_at breaks down when the aim direction is parallel to the up vector,
	# which happens whenever the hammer is directly overhead or underfoot.
	var up := Vector3.UP
	if absf(dir.dot(up)) > 0.99:
		up = global_transform.basis.z

	var desired := Basis.looking_at(dir, up)
	var weight := clampf(arm_follow_speed * delta, 0.0, 1.0)
	var current := shoulder.global_basis.orthonormalized()
	shoulder.global_basis = current.slerp(desired, weight).orthonormalized()

	var reach := clampf(
		to_target.length(), arm_base_length * 0.5, arm_base_length * arm_max_stretch
	)
	# Cylinder mesh is rotated so its length runs down -Z; scale.y is its length.
	arm.scale.y = reach / arm_base_length
	arm.position.z = -reach * 0.5


# --- Legs -------------------------------------------------------------------

func _pose_legs(delta: float) -> void:
	if hip_l == null or hip_r == null:
		return

	var speed := _horizontal_speed()
	_stride_phase = fmod(
		_stride_phase + speed * leg_cycles_per_metre * TAU * delta, TAU
	)

	# Amplitude eases to zero when standing still, so legs settle rather than
	# freezing mid-stride.
	var target_amp := deg_to_rad(leg_swing_degrees) * clampf(speed / 5.0, 0.0, 1.0)
	_stride_amplitude = lerp(
		_stride_amplitude, target_amp, clampf(9.0 * delta, 0.0, 1.0)
	)

	hip_l.rotation.x = sin(_stride_phase) * _stride_amplitude
	hip_r.rotation.x = -sin(_stride_phase) * _stride_amplitude


func _horizontal_speed() -> float:
	if _player == null:
		return 0.0
	return Vector2(_player.velocity.x, _player.velocity.z).length()


# --- Torso ------------------------------------------------------------------

func _pose_torso(delta: float) -> void:
	if torso_pivot == null:
		return
	var target_lean := 0.0

	if _player != null and _player.stagger_time_left > 0.0:
		target_lean = -deg_to_rad(stagger_lean_degrees)
	elif _hammer != null:
		# Lean forward proportionally to how far out in front the hammer is.
		var local := global_transform.affine_inverse() * _hammer.global_position
		target_lean = deg_to_rad(torso_lean_degrees) * clampf(-local.z / 2.0, -1.0, 1.0)

	_lean = lerp(_lean, target_lean, clampf(torso_lean_speed * delta, 0.0, 1.0))
	torso_pivot.rotation.x = _lean


# --- Wiring -----------------------------------------------------------------

func _resolve_hammer() -> RigidBody3D:
	if not hammer_path.is_empty():
		return get_node_or_null(hammer_path) as RigidBody3D
	if _player == null:
		return null
	var rig := _player.find_child("SwingRig", true, false)
	if rig == null:
		return null
	return rig.get_node_or_null("Hammer") as RigidBody3D


func _find_player() -> PlayerController:
	var node := get_parent()
	while node != null:
		if node is PlayerController:
			return node
		node = node.get_parent()
	return null
