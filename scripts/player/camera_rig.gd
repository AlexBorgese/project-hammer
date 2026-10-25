# Third-person camera boom that survives interiors: casts back from the pivot,
# pulls in instantly when obstructed, and eases back out slowly when clear.
#
# Attach to the SpringArm3D. The asymmetry matters — snapping in prevents the
# camera ever ending up inside geometry, while easing out prevents the jitter
# you get walking past doorways and pillars.
class_name CameraRig
extends SpringArm3D

## Boom length with nothing in the way.
@export var max_length: float = 3.0
## Never get closer than this, or the camera ends up inside the player.
@export var min_length: float = 0.6
## Radius of the cast. Wider = pulls in earlier, less corner peeking.
@export var probe_radius: float = 0.3
## How fast the camera closes in when blocked. High = effectively instant.
@export var pull_in_speed: float = 60.0
## How fast it eases back out once clear. Low = smooth, no popping.
@export var push_out_speed: float = 3.5
## Layers the camera treats as solid. Should be world + destructible, and must
## NOT include debris, or flying rubble will yank the view around.
@export_flags_3d_physics var obstruction_mask: int = 1 | 2

@export_group("Tight Spaces")
## Shrink the over-the-shoulder offset as the camera closes in, so it doesn't
## clip through the player's shoulder indoors.
@export var shoulder_offset: float = 0.5
@export var camera_path: NodePath

var _current_length: float = 0.0
var _camera: Camera3D


func _ready() -> void:
	# SpringArm does its own casting as a safety net; keep it consistent.
	collision_mask = obstruction_mask
	margin = 0.1
	_current_length = max_length
	spring_length = max_length
	_camera = get_node_or_null(camera_path) as Camera3D
	if _camera == null:
		_camera = _first_camera()


func _physics_process(delta: float) -> void:
	var desired := _cast_back()
	var speed := pull_in_speed if desired < _current_length else push_out_speed
	_current_length = move_toward(_current_length, desired, speed * delta)
	spring_length = _current_length
	_apply_shoulder()


# Sphere-cast backwards along the boom. Returns how far the camera can sit.
func _cast_back() -> float:
	var space := get_world_3d().direct_space_state
	var origin := global_position
	var back := global_transform.basis.z  # +Z is behind the arm

	var shape := SphereShape3D.new()
	shape.radius = probe_radius

	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis.IDENTITY, origin)
	params.motion = back * max_length
	params.collision_mask = obstruction_mask
	params.collide_with_bodies = true
	if _player_rid() != RID():
		params.exclude = [_player_rid()]

	# cast_motion returns [safe, unsafe] as fractions of the motion vector.
	var result := space.cast_motion(params)
	if result.is_empty():
		return max_length
	return clampf(max_length * result[0], min_length, max_length)


# Pull the shoulder offset in as the boom shortens, so a close camera doesn't
# sit inside the character's arm.
func _apply_shoulder() -> void:
	if _camera == null:
		return
	var t := clampf(
		inverse_lerp(min_length, max_length, _current_length), 0.0, 1.0
	)
	_camera.position.x = shoulder_offset * t


func _player_rid() -> RID:
	var node := get_parent()
	while node != null:
		if node is CollisionObject3D:
			return (node as CollisionObject3D).get_rid()
		node = node.get_parent()
	return RID()


func _first_camera() -> Camera3D:
	for child in get_children():
		if child is Camera3D:
			return child
	return null
