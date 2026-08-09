# Generates a grid of RigidBody3D chunks at runtime and handles impact damage,
# breaking chunks free from their neighbours when hit hard enough.
@tool
class_name Destructible
extends Node3D

signal chunk_destroyed(chunk: RigidBody3D)
signal fully_destroyed

enum Role { STRUCTURAL, PARTITION, FURNITURE }

# Presets applied when structural_role changes in the inspector.
# role -> [break_force_threshold, destruction_weight, chunk_mass]
const ROLE_PRESETS := {
	Role.STRUCTURAL: [90.0, 1.0, 12.0],
	Role.PARTITION: [45.0, 0.7, 7.0],
	Role.FURNITURE: [20.0, 0.25, 3.0],
}

## What this object is structurally. Picking a role rewrites the three tuning
## values below to sensible defaults — you can still override any of them
## afterwards, and changing the role again will overwrite them.
@export var structural_role: Role = Role.STRUCTURAL:
	set = _set_structural_role

## Overall size of the slab in metres (width, height, thickness).
@export var size: Vector3 = Vector3(4.0, 3.0, 0.4):
	set(v):
		size = v
		if Engine.is_editor_hint():
			_build_editor_preview()
## How many chunks across (X), up (Y) and through (Z).
@export var grid_columns: int = 3
@export var grid_rows: int = 3
@export var grid_depth: int = 1
## Impact force required to knock a chunk loose.
@export var break_force_threshold: float = 90.0
## How much each chunk of this object contributes to level completion, relative
## to a structural wall chunk at 1.0. Stops 200 chair chunks from dominating
## the destruction percentage.
@export var destruction_weight: float = 1.0
## Mass of each individual chunk.
@export var chunk_mass: float = 12.0
## Small gap between chunks so they don't start interpenetrating.
@export var chunk_gap: float = 0.005
## Material applied to every chunk. Leave null for the default grey.
@export var chunk_material: StandardMaterial3D
## Physics layer/mask the chunks live on. Layer 2 = destructible by convention.
@export_flags_3d_physics var chunk_layer: int = 2
@export_flags_3d_physics var chunk_mask: int = 0xFFFFF
## Use Generic6DOFJoint3D links between neighbours instead of the freeze model.
## Joints look more organic but are jitterier under Jolt with many bodies.
@export var use_joints: bool = false
## Whether this object takes part in structural support analysis. Load-bearing
## things need it; furniture does not — a chair holds nothing up, and including
## it only risks the support probe deciding it's floating.
@export var is_load_bearing: bool = true

@export_group("Debris")
## Broken chunks get lighter so they scatter instead of forming a dead pile.
@export_range(0.05, 1.0) var debris_mass_scale: float = 0.3
## Broken chunks shrink slightly, so rubble takes up less floor space.
@export_range(0.3, 1.0) var debris_scale: float = 0.8
## Seconds after breaking before debris stops blocking the player and hammer.
@export var debris_settle_time: float = 1.5
## Physics layer debris moves to once settled. Layer 5 = debris by convention;
## nothing else masks it, so you can walk and swing straight through rubble.
@export_flags_3d_physics var debris_layer: int = 16
## Seconds before debris despawns entirely. 0 = never.
@export var debris_lifetime: float = 0.0
## Extra damping on debris so it settles quickly instead of rolling for ages.
@export var debris_damping: float = 0.6

var chunks: Array[RigidBody3D] = []
var _destroyed: Dictionary = {}
# chunk -> Array[RigidBody3D] of orthogonal neighbours.
var _neighbours: Dictionary = {}
var _joints: Array[Generic6DOFJoint3D] = []


# Writing the presets straight into the exports (rather than reading the role at
# runtime) means the inspector shows the real numbers and you can override any
# of them by hand afterwards.
func _set_structural_role(value: Role) -> void:
	var changed := structural_role != value
	structural_role = value
	# Only ever rewrite the tuning values in response to a live edit in the
	# editor. Applying them at runtime would clobber whatever the .tscn saved,
	# and would silently depend on the order Godot restores properties in.
	if not changed or not Engine.is_editor_hint():
		return
	if not ROLE_PRESETS.has(value):
		return
	var preset: Array = ROLE_PRESETS[value]
	break_force_threshold = preset[0]
	destruction_weight = preset[1]
	chunk_mass = preset[2]
	is_load_bearing = value != Role.FURNITURE
	_build_editor_preview()
	notify_property_list_changed()


const PREVIEW_NAME := "__EditorPreview"


func _ready() -> void:
	# @tool script: never build physics bodies inside the editor. Show a single
	# ghost box instead, so layouts are visible without simulating anything.
	if Engine.is_editor_hint():
		_build_editor_preview()
		return
	_build_grid()
	if use_joints:
		_build_joints()


# Editor-only stand-in for the chunk grid. Never given an owner, so it is not
# saved into the .tscn.
func _build_editor_preview() -> void:
	if not is_inside_tree():
		return
	var existing := get_node_or_null(PREVIEW_NAME)
	if existing != null:
		existing.free()

	var mesh := MeshInstance3D.new()
	mesh.name = PREVIEW_NAME
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box

	var mat := StandardMaterial3D.new()
	mat.albedo_color = _preview_colour()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material_override = mat

	add_child(mesh)
	mesh.owner = null
	# Destructible origins sit at bottom-centre; BoxMesh is centred.
	mesh.position = Vector3(0.0, size.y * 0.5, 0.0)


func _preview_colour() -> Color:
	match structural_role:
		Role.STRUCTURAL:
			return Color(0.6, 0.6, 0.65, 0.55)
		Role.PARTITION:
			return Color(0.55, 0.7, 0.85, 0.45)
		_:
			return Color(0.85, 0.7, 0.45, 0.45)


# Total weighted value of this object, used by StructuralManager.
func get_total_weight() -> float:
	return float(get_chunk_count()) * destruction_weight


func get_chunk_count() -> int:
	return chunks.size()


func get_destroyed_count() -> int:
	return _destroyed.size()


# Chunks still frozen in place — candidates for a support check.
func get_supported_chunks() -> Array[RigidBody3D]:
	var result: Array[RigidBody3D] = []
	for chunk in chunks:
		if is_instance_valid(chunk) and chunk.freeze:
			result.append(chunk)
	return result


# Called by StructuralManager when nothing is holding this chunk up any more.
func collapse_chunk(chunk: RigidBody3D) -> void:
	if chunk == null or not chunk.freeze:
		return
	_release_joints_for(chunk)
	chunk.freeze = false
	# A nudge so it topples rather than dropping perfectly straight down.
	chunk.apply_central_impulse(
		Vector3(randf_range(-0.4, 0.4), -0.5, randf_range(-0.4, 0.4)) * chunk.mass
	)
	_make_debris(chunk)


# Collapsed-but-not-smashed chunks still count toward the destruction total once
# they've fallen, so a roof caving in makes progress.
func mark_collapsed(chunk: RigidBody3D) -> void:
	if chunk == null or _destroyed.has(chunk):
		return
	_destroyed[chunk] = true
	chunk_destroyed.emit(chunk)
	if _destroyed.size() >= chunks.size():
		fully_destroyed.emit()


# Called by the hammer on collision. force is the impact magnitude.
func take_damage(chunk: RigidBody3D, force: float, impulse_dir: Vector3 = Vector3.ZERO) -> void:
	if chunk == null or _destroyed.has(chunk):
		return
	if force < break_force_threshold:
		return
	_break_chunk(chunk, impulse_dir * force * 0.05)
	# Spread a fraction of the impact into neighbours so hits feel chunky.
	var bleed := force * 0.4
	if bleed >= break_force_threshold:
		for neighbour in _neighbours.get(chunk, []):
			take_damage(neighbour, bleed, impulse_dir)


func _build_grid() -> void:
	var chunk_size := Vector3(
		size.x / float(grid_columns),
		size.y / float(grid_rows),
		size.z / float(grid_depth)
	)
	# grid[row][col][layer]
	var grid: Array = []
	for row in grid_rows:
		var row_chunks: Array = []
		for col in grid_columns:
			var col_chunks: Array = []
			for layer in grid_depth:
				var chunk := _make_chunk(col, row, layer, chunk_size)
				add_child(chunk)
				chunks.append(chunk)
				col_chunks.append(chunk)
			row_chunks.append(col_chunks)
		grid.append(row_chunks)
	_link_neighbours(grid)


func _make_chunk(col: int, row: int, layer: int, chunk_size: Vector3) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "Chunk_%d_%d_%d" % [col, row, layer]
	body.mass = chunk_mass
	body.collision_layer = chunk_layer
	body.collision_mask = chunk_mask
	body.contact_monitor = true
	body.max_contacts_reported = 4
	body.freeze = not use_joints
	body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	body.set_meta("destructible", self)

	var inner := chunk_size - Vector3.ONE * chunk_gap
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = inner
	shape.shape = box
	body.add_child(shape)

	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = inner
	mesh.mesh = box_mesh
	if chunk_material != null:
		mesh.material_override = chunk_material
	body.add_child(mesh)

	# Origin of the slab sits at its bottom-centre.
	body.position = Vector3(
		(col + 0.5) * chunk_size.x - size.x * 0.5,
		(row + 0.5) * chunk_size.y,
		(layer + 0.5) * chunk_size.z - size.z * 0.5
	)
	return body


func _link_neighbours(grid: Array) -> void:
	for row in grid_rows:
		for col in grid_columns:
			for layer in grid_depth:
				var chunk: RigidBody3D = grid[row][col][layer]
				var found: Array[RigidBody3D] = []
				if col > 0:
					found.append(grid[row][col - 1][layer])
				if col < grid_columns - 1:
					found.append(grid[row][col + 1][layer])
				if row > 0:
					found.append(grid[row - 1][col][layer])
				if row < grid_rows - 1:
					found.append(grid[row + 1][col][layer])
				if layer > 0:
					found.append(grid[row][col][layer - 1])
				if layer < grid_depth - 1:
					found.append(grid[row][col][layer + 1])
				_neighbours[chunk] = found


func _build_joints() -> void:
	var seen: Dictionary = {}
	for chunk in chunks:
		for neighbour in _neighbours.get(chunk, []):
			var names := [String(chunk.name), String(neighbour.name)]
			names.sort()
			var key: String = "%s|%s" % names
			if seen.has(key):
				continue
			seen[key] = true
			_joints.append(_make_joint(chunk, neighbour))


func _make_joint(a: RigidBody3D, b: RigidBody3D) -> Generic6DOFJoint3D:
	var joint := Generic6DOFJoint3D.new()
	joint.name = "Joint_%s_%s" % [a.name, b.name]
	add_child(joint)
	joint.position = (a.position + b.position) * 0.5
	joint.node_a = joint.get_path_to(a)
	joint.node_b = joint.get_path_to(b)
	for axis in 3:
		joint.set("linear_limit_%s/upper_distance" % _axis_name(axis), 0.0)
		joint.set("linear_limit_%s/lower_distance" % _axis_name(axis), 0.0)
		joint.set("angular_limit_%s/upper_angle" % _axis_name(axis), 0.0)
		joint.set("angular_limit_%s/lower_angle" % _axis_name(axis), 0.0)
	return joint


func _axis_name(axis: int) -> String:
	return ["x", "y", "z"][axis]


func _break_chunk(chunk: RigidBody3D, impulse: Vector3) -> void:
	_destroyed[chunk] = true
	_release_joints_for(chunk)
	chunk.freeze = false
	chunk.set_meta("broken", true)
	_make_debris(chunk)
	if impulse.length() > 0.0:
		chunk.apply_central_impulse(impulse)
	chunk_destroyed.emit(chunk)
	_destabilise_above(chunk)
	if _destroyed.size() >= chunks.size():
		fully_destroyed.emit()


# Turns a just-broken chunk into debris: lighter and smaller so it scatters
# rather than piling, then demoted to a layer nothing collides with so it stops
# blocking you and the hammer.
func _make_debris(chunk: RigidBody3D) -> void:
	if chunk.get_meta("is_debris", false):
		return
	chunk.set_meta("is_debris", true)

	chunk.mass = maxf(chunk.mass * debris_mass_scale, 0.1)
	chunk.linear_damp = debris_damping
	chunk.angular_damp = debris_damping
	if debris_scale < 1.0:
		_shrink_chunk(chunk)

	_demote_after_delay(chunk)
	if debris_lifetime > 0.0:
		_despawn_after_delay(chunk)


# Scale the shape and mesh, not the RigidBody3D itself — Godot ignores scale on
# physics bodies and warns about it.
func _shrink_chunk(chunk: RigidBody3D) -> void:
	for child in chunk.get_children():
		var col := child as CollisionShape3D
		if col != null:
			var box := col.shape as BoxShape3D
			if box != null:
				# Duplicate so we don't resize the shape shared with siblings.
				var shrunk := box.duplicate() as BoxShape3D
				shrunk.size = box.size * debris_scale
				col.shape = shrunk
			continue
		var mesh := child as MeshInstance3D
		if mesh != null:
			mesh.scale = Vector3.ONE * debris_scale


func _demote_after_delay(chunk: RigidBody3D) -> void:
	await get_tree().create_timer(debris_settle_time).timeout
	if not is_instance_valid(chunk):
		return
	# Debris keeps colliding with the world and other debris, but drops off the
	# layer the player and hammer look at, so you can move straight through it.
	chunk.collision_layer = debris_layer
	chunk.collision_mask = 1 | debris_layer


func _despawn_after_delay(chunk: RigidBody3D) -> void:
	await get_tree().create_timer(debris_lifetime).timeout
	if is_instance_valid(chunk):
		chunk.queue_free()


# Once a chunk goes, anything resting on it should stop being frozen scenery.
func _destabilise_above(chunk: RigidBody3D) -> void:
	for neighbour in _neighbours.get(chunk, []):
		if neighbour.position.y > chunk.position.y and neighbour.freeze:
			neighbour.freeze = false


func _release_joints_for(chunk: RigidBody3D) -> void:
	for joint in _joints:
		if not is_instance_valid(joint):
			continue
		if joint.get_node_or_null(joint.node_a) == chunk \
				or joint.get_node_or_null(joint.node_b) == chunk:
			joint.queue_free()
