# Generates a solid stepped staircase out of Destructible blocks, one per step.
# Each step is independently breakable, so the route upstairs can be destroyed.
@tool
class_name Staircase
extends Node3D

## Number of steps from floor to landing.
@export var steps: int = 8:
	set(v):
		steps = maxi(2, v)
		_request_rebuild()
## Total height climbed, in metres. Should match the storey height.
@export var total_rise: float = 3.0:
	set(v):
		total_rise = v
		_request_rebuild()
## Total horizontal depth the staircase occupies.
@export var total_run: float = 3.6:
	set(v):
		total_run = v
		_request_rebuild()
## Width of the staircase.
@export var width: float = 1.2:
	set(v):
		width = v
		_request_rebuild()

@export_group("Destruction")
@export var step_role: Destructible.Role = Destructible.Role.PARTITION
## Chunk subdivision across the width of each step.
@export var step_columns: int = 2
## Off by default: stairs don't hold up floors. When this was on, the top step
## touched the landing slab and single-handedly held up the whole upper storey.
## Each step is already a solid column from the floor, so it stands without the
## structural graph, and a step's own chunks still crumble when hit.
@export var steps_load_bearing: bool = false

@export_group("Rebuild")
@export var rebuild_now: bool = false:
	set(v):
		if v:
			_rebuild()
		rebuild_now = false

const GENERATED_GROUP := "staircase_generated"

var _rebuild_queued: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		_request_rebuild()
		return
	_rebuild()


func _request_rebuild() -> void:
	if not is_inside_tree() or _rebuild_queued:
		return
	_rebuild_queued = true
	await get_tree().process_frame
	_rebuild_queued = false
	_rebuild()


func _rebuild() -> void:
	for child in get_children():
		if child.is_in_group(GENERATED_GROUP):
			child.free()
	_build_steps()


# Each step is a solid block running from the floor up to its own tread height,
# so the staircase is a wedge rather than a set of floating slabs.
func _build_steps() -> void:
	var rise := total_rise / float(steps)
	var run := total_run / float(steps)

	for i in steps:
		var height := rise * float(i + 1)
		var step := Destructible.new()
		step.name = "Step_%02d" % i
		step.structural_role = step_role
		step.is_load_bearing = steps_load_bearing
		step.size = Vector3(width, height, run)
		step.grid_columns = step_columns
		step.grid_rows = maxi(1, roundi(height / rise))
		step.grid_depth = 1
		_apply_role_presets(step, step_role)

		add_child(step)
		step.owner = _scene_owner()
		step.add_to_group(GENERATED_GROUP)
		# Destructible origin is bottom-centre, so y stays at 0 and each step
		# just sits further along the run.
		step.position = Vector3(0.0, 0.0, (i + 0.5) * run - total_run * 0.5)


# Nodes built in code never fire the editor-only role setter.
func _apply_role_presets(d: Destructible, role: Destructible.Role) -> void:
	if not Destructible.ROLE_PRESETS.has(role):
		return
	var preset: Array = Destructible.ROLE_PRESETS[role]
	d.break_force_threshold = preset[0]
	d.destruction_weight = preset[1]
	d.chunk_mass = preset[2]


# Never saved — see the note on FloorPlan._scene_owner. Steps are rebuilt from
# the Staircase's settings every time the scene opens.
func _scene_owner() -> Node:
	return null
