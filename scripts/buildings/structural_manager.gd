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
## Print graph stats at load and on each collapse. Useful when things fall over
## that shouldn't.
@export var debug_collapse: bool = false

var destruction_percentage: float = 0.0

var _destructibles: Array[Destructible] = []
var _total_weight: float = 0.0
var _destroyed_weight: float = 0.0
var _total_chunks: int = 0
var _destroyed_chunks: int = 0
var _has_won: bool = false
var _check_queued: bool = false
var _check_timer: float = 0.0
var _game_manager: Node

# Cached contact graph: chunk -> Array[RigidBody3D] of touching intact chunks.
var _links: Dictionary = {}
# Chunks touching a StaticBody3D (the ground).
var _grounded: Dictionary = {}
var _graph_built: bool = false
# Chunks whose links need re-probing on the next check.
var _dirty: Dictionary = {}

# Reused across every probe so we aren't allocating a shape and a params object
# per chunk per check.
var _probe_shape: BoxShape3D = BoxShape3D.new()
var _probe_params: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()


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

	# Second wait, on a physics frame, so Jolt has registered every chunk body
	# before we shape-query them. Building the graph here means the one-time
	# cost lands during level load rather than as a hitch on the first hit.
	await get_tree().physics_frame
	if enable_collapse:
		_build_graph()

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
		_total_weight += d.get_total_weight()
		d.chunk_destroyed.connect(_on_chunk_destroyed)
	if _total_chunks == 0:
		push_warning("StructuralManager found no Destructible nodes in the level.")


func _on_chunk_destroyed(chunk: RigidBody3D) -> void:
	_destroyed_chunks += 1
	var owner_node := _owner_of(chunk)
	_destroyed_weight += owner_node.destruction_weight if owner_node != null else 1.0
	_mark_neighbours_dirty(chunk)
	_recalculate()
	_queue_collapse_check()


# A broken chunk leaves the graph, and its former neighbours need re-probing
# because their contact list just changed.
func _mark_neighbours_dirty(chunk: RigidBody3D) -> void:
	for neighbour in _links.get(chunk, []):
		if is_instance_valid(neighbour):
			_dirty[neighbour] = true
	_links.erase(chunk)
	_grounded.erase(chunk)


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
#
# The graph is cached rather than rebuilt each check. Intact chunks are frozen,
# so they never move, so their contact links can't change while they're intact.
# Only chunks adjacent to a break need re-probing; everything else is reused.
# The flood fill itself is a pure memory walk, so it stays global and cheap.
func _run_collapse_check() -> void:
	if not _graph_built:
		_build_graph()
	else:
		_reprobe_dirty()

	var supported := _flood_fill()

	var collapsed := 0
	for chunk in _links.keys():
		if supported.has(chunk) or not is_instance_valid(chunk):
			continue
		var owner_node := _owner_of(chunk)
		if owner_node == null:
			continue
		owner_node.collapse_chunk(chunk)
		owner_node.mark_collapsed(chunk)
		collapsed += 1

	if collapsed > 0:
		if debug_collapse:
			print("[StructuralManager] collapsed %d chunks (%d still standing, %d grounded)"
				% [collapsed, _links.size(), _grounded.size()])
		collapse_occurred.emit(collapsed)


# One-time full scan at level load. This is the only moment we pay for every
# chunk at once.
func _build_graph() -> void:
	var space := get_world_3d().direct_space_state
	var skipped := 0
	for destructible in _destructibles:
		if not is_instance_valid(destructible):
			continue
		# Non-load-bearing objects (furniture) never enter the graph, so they
		# are never collapse-checked and never counted as support.
		if not destructible.is_load_bearing:
			skipped += destructible.get_chunk_count()
			continue
		for chunk in destructible.get_supported_chunks():
			_probe_into_graph(space, chunk)
	_graph_built = true
	_dirty.clear()

	if debug_collapse:
		print("[StructuralManager] graph: %d chunks, %d grounded, %d skipped (not load-bearing)"
			% [_links.size(), _grounded.size(), skipped])
		if _grounded.is_empty() and not _links.is_empty():
			push_warning(
				"StructuralManager: nothing is touching a StaticBody3D. "
				+ "Everything will collapse. Is there a ground StaticBody3D, "
				+ "and is it on a layer the chunks' collision_mask includes?"
			)


func _reprobe_dirty() -> void:
	if _dirty.is_empty():
		return
	var space := get_world_3d().direct_space_state
	for chunk in _dirty.keys():
		if is_instance_valid(chunk) and chunk.freeze:
			_probe_into_graph(space, chunk)
		else:
			_links.erase(chunk)
			_grounded.erase(chunk)
	_dirty.clear()


# Walks outward from the grounded chunks through the cached contact graph.
# Whatever it can't reach has no load path to the ground.
func _flood_fill() -> Dictionary:
	var supported: Dictionary = {}
	var queue: Array = _grounded.keys()
	for chunk in queue:
		supported[chunk] = true
	while not queue.is_empty():
		var current = queue.pop_back()
		for neighbour in _links.get(current, []):
			if supported.has(neighbour):
				continue
			supported[neighbour] = true
			queue.append(neighbour)
	return supported


# One shape query, writing straight into the cached graph. Finds both touching
# chunks and ground contact, and works across separate Destructible nodes — so
# a roof knows the walls of a different scene are holding it up.
func _probe_into_graph(space: PhysicsDirectSpaceState3D, chunk: RigidBody3D) -> void:
	var extents := _chunk_extents(chunk)
	_probe_shape.size = extents * 2.0 + Vector3.ONE * support_probe_distance

	_probe_params.shape = _probe_shape
	_probe_params.transform = Transform3D(
		chunk.global_transform.basis, chunk.global_position
	)
	_probe_params.exclude = [chunk.get_rid()]
	_probe_params.collision_mask = chunk.collision_mask
	_probe_params.collide_with_bodies = true

	var touching: Array[RigidBody3D] = []
	var is_grounded := false
	for hit in space.intersect_shape(_probe_params, 24):
		var collider = hit.get("collider")
		if collider == null:
			continue
		if collider is StaticBody3D:
			is_grounded = true
			continue
		var body := collider as RigidBody3D
		if body != null and body.freeze:
			touching.append(body)

	_links[chunk] = touching
	if is_grounded:
		_grounded[chunk] = true
	else:
		_grounded.erase(chunk)


func _chunk_extents(chunk: RigidBody3D) -> Vector3:
	for child in chunk.get_children():
		var col := child as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			return (col.shape as BoxShape3D).size * 0.5
	return Vector3.ONE * 0.5


func _owner_of(chunk: RigidBody3D) -> Destructible:
	return chunk.get_meta("destructible", null) as Destructible


func _recalculate() -> void:
	if _total_weight <= 0.0:
		return
	destruction_percentage = clampf(_destroyed_weight / _total_weight, 0.0, 1.0)
	destruction_changed.emit(destruction_percentage)
	if not _has_won and destruction_percentage >= win_threshold:
		_has_won = true
		building_demolished.emit()


func get_total_chunks() -> int:
	return _total_chunks


func get_destroyed_chunks() -> int:
	return _destroyed_chunks


func get_total_weight() -> float:
	return _total_weight


func get_destroyed_weight() -> float:
	return _destroyed_weight
