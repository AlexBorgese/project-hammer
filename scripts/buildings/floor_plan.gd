# Generates one storey of a building from a grid floor plan: exterior walls,
# shared interior partitions, doorway gaps, and a floor slab. Walls between two
# adjacent rooms are built once, not twice.
@tool
class_name FloorPlan
extends Node3D

## Cell size in metres (width, height, depth). Height is the storey height.
@export var cell_size: Vector3 = Vector3(4.0, 3.0, 4.0):
	set(v):
		cell_size = v
		_request_rebuild()

## Grid dimensions in cells.
@export var grid_width: int = 3:
	set(v):
		grid_width = maxi(1, v)
		_request_rebuild()
@export var grid_depth: int = 2:
	set(v):
		grid_depth = maxi(1, v)
		_request_rebuild()

## Room layout, one string per grid row, one character per cell.
## Same character = same room. "." = empty (no floor, no walls).
## Example for a 3x2 floor:  ["LLK", "HHB"]
##   L = living room (2 cells), K = kitchen, H = hallway (2 cells), B = back room
@export var layout: PackedStringArray = PackedStringArray(["LLK", "HHB"]):
	set(v):
		layout = v
		_request_rebuild()

@export_group("Construction")
@export var wall_thickness: float = 0.3:
	set(v):
		wall_thickness = v
		_request_rebuild()
## Chunk subdivision for a full-width wall segment.
@export var wall_columns: int = 3
@export var wall_rows: int = 3
## Build a floor slab under the whole storey.
@export var build_floor_slab: bool = true
## Thickness of the floor slab in metres.
@export var floor_thickness: float = 0.3
## Chunk subdivision of the floor slab, per cell.
@export var floor_subdivision: int = 2

@export_group("Doorways")
## Leave a gap in walls between different rooms so the house is navigable.
@export var auto_doorways: bool = true
## Doorway width in metres. Clamped to the wall length.
@export var doorway_width: float = 1.2
## Also leave one doorway in an exterior wall as a front door.
@export var front_door: bool = true

@export_group("Rebuild")
## Tick to regenerate in the editor. Auto-unticks.
@export var rebuild_now: bool = false:
	set(v):
		if v:
			_rebuild()
		rebuild_now = false

const GENERATED_GROUP := "floorplan_generated"

var _rebuild_queued: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_rebuild()


# --- Layout access ----------------------------------------------------------

# Room id at a cell, or "" for empty/out of bounds.
func get_room_at(col: int, row: int) -> String:
	if row < 0 or row >= layout.size():
		return ""
	if col < 0 or col >= grid_width:
		return ""
	var line: String = layout[row]
	if col >= line.length():
		return ""
	var ch := line.substr(col, 1)
	return "" if ch == "." else ch


func _cell_centre(col: int, row: int) -> Vector3:
	return Vector3(
		(col + 0.5) * cell_size.x - grid_width * cell_size.x * 0.5,
		0.0,
		(row + 0.5) * cell_size.z - grid_depth * cell_size.z * 0.5
	)


# --- Build ------------------------------------------------------------------

func _request_rebuild() -> void:
	if not Engine.is_editor_hint() or _rebuild_queued or not is_inside_tree():
		return
	_rebuild_queued = true
	await get_tree().process_frame
	_rebuild_queued = false
	_rebuild()


func _rebuild() -> void:
	_clear_generated()
	if build_floor_slab:
		_build_floor()
	_build_walls_along_x()
	_build_walls_along_z()


func _clear_generated() -> void:
	for child in get_children():
		if child.is_in_group(GENERATED_GROUP):
			child.free()


# Vertical walls running along X, i.e. the boundaries between row and row-1.
func _build_walls_along_x() -> void:
	for row in range(grid_depth + 1):
		for col in grid_width:
			var near := get_room_at(col, row - 1)
			var far := get_room_at(col, row)
			if near == far:
				continue  # same room, or both empty — no wall needed
			var centre := _cell_centre(col, mini(row, grid_depth - 1))
			centre.z = row * cell_size.z - grid_depth * cell_size.z * 0.5
			_spawn_wall(centre, cell_size.x, 0.0, _role_for(near, far), near, far)


# Walls running along Z, i.e. boundaries between col and col-1.
func _build_walls_along_z() -> void:
	for col in range(grid_width + 1):
		for row in grid_depth:
			var near := get_room_at(col - 1, row)
			var far := get_room_at(col, row)
			if near == far:
				continue
			var centre := _cell_centre(mini(col, grid_width - 1), row)
			centre.x = col * cell_size.x - grid_width * cell_size.x * 0.5
			_spawn_wall(centre, cell_size.z, 90.0, _role_for(near, far), near, far)


# A wall with empty space on one side is exterior and load-bearing. A wall
# between two rooms is an interior partition.
func _role_for(near: String, far: String) -> Destructible.Role:
	if near == "" or far == "":
		return Destructible.Role.STRUCTURAL
	return Destructible.Role.PARTITION


func _spawn_wall(
	centre: Vector3,
	length: float,
	y_rotation: float,
	role: Destructible.Role,
	near: String,
	far: String
) -> void:
	# A doorway splits one wall into two shorter segments either side of the gap.
	var gap := 0.0
	if auto_doorways and near != "" and far != "":
		gap = minf(doorway_width, length * 0.6)
	elif auto_doorways and front_door and _is_front_door(centre, near, far):
		gap = minf(doorway_width, length * 0.6)

	if gap <= 0.0:
		_make_wall_segment(centre, length, y_rotation, role, 0)
		return

	var segment := (length - gap) * 0.5
	if segment < 0.15:
		return  # doorway eats the whole wall; leave it open
	var axis := Vector3.RIGHT.rotated(Vector3.UP, deg_to_rad(y_rotation))
	var offset := (gap + segment) * 0.5
	_make_wall_segment(centre - axis * offset, segment, y_rotation, role, 0)
	_make_wall_segment(centre + axis * offset, segment, y_rotation, role, 1)


# Exactly one front door: the leftmost exterior wall on the lowest-Z edge.
func _is_front_door(centre: Vector3, near: String, far: String) -> bool:
	if near != "" and far != "":
		return false
	var front_z := -grid_depth * cell_size.z * 0.5
	if not is_equal_approx(centre.z, front_z):
		return false
	return is_equal_approx(centre.x, _cell_centre(0, 0).x)


func _make_wall_segment(
	centre: Vector3,
	length: float,
	y_rotation: float,
	role: Destructible.Role,
	index: int
) -> void:
	var wall := Destructible.new()
	wall.name = "Wall_%d_%d_%d" % [
		roundi(centre.x * 10), roundi(centre.z * 10), index
	]
	wall.structural_role = role
	wall.size = Vector3(length, cell_size.y, wall_thickness)
	wall.grid_columns = maxi(1, roundi(wall_columns * length / cell_size.x))
	wall.grid_rows = wall_rows
	wall.grid_depth = 1
	_apply_role_presets(wall, role)

	add_child(wall)
	wall.owner = _scene_owner()
	wall.add_to_group(GENERATED_GROUP)
	wall.position = centre
	wall.rotation.y = deg_to_rad(y_rotation)


func _build_floor() -> void:
	var slab := Destructible.new()
	slab.name = "FloorSlab"
	slab.structural_role = Destructible.Role.STRUCTURAL
	slab.size = Vector3(
		grid_width * cell_size.x, floor_thickness, grid_depth * cell_size.z
	)
	slab.grid_columns = grid_width * floor_subdivision
	slab.grid_rows = 1
	slab.grid_depth = grid_depth * floor_subdivision
	_apply_role_presets(slab, Destructible.Role.STRUCTURAL)

	add_child(slab)
	slab.owner = _scene_owner()
	slab.add_to_group(GENERATED_GROUP)
	# Destructible origins sit at bottom-centre, so drop the slab below y=0.
	slab.position = Vector3(0.0, -floor_thickness, 0.0)


# Nodes are created in code, so the role setter (editor-only) never fires.
# Apply the same presets by hand.
func _apply_role_presets(d: Destructible, role: Destructible.Role) -> void:
	if not Destructible.ROLE_PRESETS.has(role):
		return
	var preset: Array = Destructible.ROLE_PRESETS[role]
	d.break_force_threshold = preset[0]
	d.destruction_weight = preset[1]
	d.chunk_mass = preset[2]


# In the editor, generated children need an owner to show in the scene tree.
# At runtime they must not have one.
func _scene_owner() -> Node:
	if not Engine.is_editor_hint():
		return null
	return owner if owner != null else self
