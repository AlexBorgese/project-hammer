# Aggregates every Destructible in a level, tracks the overall destruction
# percentage, and runs a support check so unsupported chunks collapse.
class_name StructuralManager
extends Node3D

signal destruction_changed(percentage: float)
signal building_demolished
signal collapse_occurred(chunk_count: int)

## Fraction of chunks that must be destroyed to win the level.
@export var win_threshold: float = 0.85
## Identifier used for leaderboard and save keys.
@export var level_id: String = "level_01_house"
## Start the run timer automatically when the level loads.
@export var auto_start: bool = true

@export_group("Collapse")
## Run the support check so unsupported chunks fall. Turn off to debug.
@export var enable_collapse: bool = true
## How far past its own bounds a chunk looks for neighbours, in metres. Larger
## is more forgiving — raise it if things collapse that visibly shouldn't.
@export var support_probe_distance: float = 0.12
## Seconds between support checks. Debounces bursts of breaking chunks.
@export var collapse_check_interval: float = 0.2

var destruction_percentage: float = 0.0

var _destructibles: Array[Destructible] = []
var _total_chunks: int = 0
var _destroyed_chunks: int = 0
var _has_won: bool = false
var _check_queued: bool = false
var _check_timer: float = 0.0
var _game_manager: Node


# Autoloads are resolved at runtime rather than by the bare `GameManager`
# identifier. A script with a class_name is compiled before autoloads exist in
# some load orders, and referencing the singleton directly fails the whole
# compile with "Identifier not found".
func _gm() -> Node:
	if _game_manager == null or not is_instance_valid(_game_manager):
		_game_manager = get_node_or_null("/root/GameManager")
	return _game_manager


func _ready() -> void:
	# Wait a frame so every Destructible has finished building its grid.
	await get_tree().process_frame
	var search_root: Node = get_tree().current_scene
	if search_root == null:
		search_root = get_parent()
	_collect_destructibles(search_root)
	var gm := _gm()
	if gm == null:
		push_error("StructuralManager: GameManager autoload not found at /root/GameManager.")
		return
	gm.register_structural_manager(self)
	destruction_changed.emit(0.0)
	if auto_start:
		gm.start_level(level_id)


func _physics_process(delta: float) -> void:
	if not _check_queued:
		return
	_check_timer -= delta
	if _check_timer <= 0.0:
		_check_queued = false
		_run_collapse_check()


func _collect_destructibles(root: Node) -> void:
	for node in root.find_children("*", "Destructible", true, false):
		var d := node as Destructible
		_destructibles.append(d)
		_total_chunks += d.get_chunk_count()
		d.chunk_destroyed.connect(_on_chunk_destroyed)
	if _total_chunks == 0:
		push_warning("StructuralManager found no Destructible nodes in the level.")


func _on_chunk_destroyed(_chunk: RigidBody3D) -> void:
	_destroyed_chunks += 1
	_recalculate()
	_queue_collapse_check()


func _queue_collapse_check() -> void:
	if not enable_collapse or _check_queued:
		return
	_check_queued = true
	_check_timer = collapse_check_interval


# Structural analysis by flood fill: a chunk is only standing if there's an
# unbroken chain of intact chunks from it down to the ground. Anything not in
# that chain has nothing holding it up, so it falls.
#
# A downward-only probe isn't enough — the middle of a roof has no wall directly
# beneath it, but it's still held up by the roof chunks either side of it.
func _run_collapse_check() -> void:
	var space := get_world_3d().direct_space_state
	var standing := _gather_standing_chunks()
	if standing.is_empty():
		return

	var grounded: Array[RigidBody3D] = []
	var links: Dictionary = {}
	for chunk in standing:
		var found := _probe_neighbours(space, chunk)
		if found["grounded"]:
			grounded.append(chunk)
		links[chunk] = found["chunks"]

	var supported := _flood_fill(grounded, links)

	var collapsed := 0
	for chunk in standing:
		if supported.has(chunk):
			continue
		var owner_node := _owner_of(chunk)
		if owner_node == null:
			continue
		owner_node.collapse_chunk(chunk)
		owner_node.mark_collapsed(chunk)
		collapsed += 1

	if collapsed > 0:
		collapse_occurred.emit(collapsed)


func _gather_standing_chunks() -> Array[RigidBody3D]:
	var standing: Array[RigidBody3D] = []
	for destructible in _destructibles:
		if is_instance_valid(destructible):
			standing.append_array(destructible.get_supported_chunks())
	return standing


# Walks outward from the grounded chunks through the contact graph. Whatever it
# can't reach is floating.
func _flood_fill(grounded: Array[RigidBody3D], links: Dictionary) -> Dictionary:
	var supported: Dictionary = {}
	var queue: Array = grounded.duplicate()
	for chunk in queue:
		supported[chunk] = true
	while not queue.is_empty():
		var current = queue.pop_back()
		for neighbour in links.get(current, []):
			if supported.has(neighbour):
				continue
			supported[neighbour] = true
			queue.append(neighbour)
	return supported


# One shape query per chunk, finding both touching chunks and ground contact.
# Works across separate Destructible nodes, so a roof knows the walls hold it.
func _probe_neighbours(space: PhysicsDirectSpaceState3D, chunk: RigidBody3D) -> Dictionary:
	var result := {"grounded": false, "chunks": []}
	var extents := _chunk_extents(chunk)

	var shape := BoxShape3D.new()
	shape.size = extents * 2.0 + Vector3.ONE * support_probe_distance

	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(chunk.global_transform.basis, chunk.global_position)
	params.exclude = [chunk.get_rid()]
	params.collision_mask = chunk.collision_mask
	params.collide_with_bodies = true

	for hit in space.intersect_shape(params, 24):
		var collider = hit.get("collider")
		if collider == null:
			continue
		if collider is StaticBody3D:
			result["grounded"] = true
			continue
		var body := collider as RigidBody3D
		if body != null and body.freeze:
			result["chunks"].append(body)
	return result


func _chunk_extents(chunk: RigidBody3D) -> Vector3:
	for child in chunk.get_children():
		var col := child as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			return (col.shape as BoxShape3D).size * 0.5
	return Vector3.ONE * 0.5


func _owner_of(chunk: RigidBody3D) -> Destructible:
	return chunk.get_meta("destructible", null) as Destructible


func _recalculate() -> void:
	if _total_chunks == 0:
		return
	destruction_percentage = float(_destroyed_chunks) / float(_total_chunks)
	destruction_changed.emit(destruction_percentage)
	if not _has_won and destruction_percentage >= win_threshold:
		_has_won = true
		building_demolished.emit()


func get_total_chunks() -> int:
	return _total_chunks


func get_destroyed_chunks() -> int:
	return _destroyed_chunks
