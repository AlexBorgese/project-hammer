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
## How far, in metres, a structure can reach sideways from its nearest support
## before it falls. Lower = floors drop sooner once walls go. This is the main
## knob for how "pancakey" buildings feel.
@export var max_span: float = 3.0
## Hanging *below* a supporter is weaker than spanning across from one. This
## multiplies the per-metre cost for downward hangs.
@export var hang_cost_multiplier: float = 2.0
## How many unsupported chunks are released per physics frame. Lower = smoother
## frame times during a big collapse, but a slower-looking crumble.
@export var max_collapses_per_frame: int = 40
## Print graph stats at load and on each collapse, and tint every standing
## chunk by stability (green = solid, red = about to go).
@export var debug_collapse: bool = false

const MAX_STABILITY := 100.0

var destruction_percentage: float = 0.0

# Profiling numbers, read by the F3 perf overlay.
var graph_build_ms: float = 0.0
var last_check_ms: float = 0.0
var peak_check_ms: float = 0.0

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
# Unsupported chunks waiting to be released, lowest first, and a set mirror so a
# chunk already in the queue isn't queued again by the next check.
var _collapse_queue: Array = []
var _pending_collapse: Dictionary = {}

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
		var started := Time.get_ticks_usec()
		_build_graph()
		graph_build_ms = (Time.get_ticks_usec() - started) / 1000.0

	var gm := _gm()
	if gm == null:
		push_error("StructuralManager: GameManager autoload not found at /root/GameManager.")
		return
	gm.register_structural_manager(self)
	destruction_changed.emit(0.0)
	if auto_start:
		gm.start_level(level_id)


func _physics_process(delta: float) -> void:
	_drain_collapse_queue()
	if not _check_queued:
		return
	_check_timer -= delta
	if _check_timer <= 0.0:
		_check_queued = false
		var started := Time.get_ticks_usec()
		_run_collapse_check()
		last_check_ms = (Time.get_ticks_usec() - started) / 1000.0
		peak_check_ms = maxf(peak_check_ms, last_check_ms)


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

	var stability := _compute_stability()
	if debug_collapse:
		_tint_by_stability(stability)

	var doomed: Array = []
	for chunk in _links.keys():
		if stability.get(chunk, 0.0) > 0.0 or not is_instance_valid(chunk):
			continue
		if _pending_collapse.has(chunk):
			continue
		doomed.append(chunk)

	if doomed.is_empty():
		return
	_queue_collapses(doomed)
	if debug_collapse:
		print("[StructuralManager] queued %d chunks to collapse (%d still standing, %d grounded)"
			% [doomed.size(), _links.size() - _pending_collapse.size(), _grounded.size()])
	collapse_occurred.emit(doomed.size())


# Collapses are released a batch per physics frame, lowest first, rather than
# all at once. Unfreezing ~200 touching bodies in a single step was an 80–90 ms
# physics hitch when a storey pancaked. Spread over a handful of frames the
# solver cost is smoothed out and it still reads as one collapse — lowest-first
# also means lower pieces start dropping before the ones landing on them.
func _queue_collapses(chunks_to_drop: Array) -> void:
	chunks_to_drop.sort_custom(
		func(a, b): return a.global_position.y < b.global_position.y
	)
	for chunk in chunks_to_drop:
		_pending_collapse[chunk] = true
		_collapse_queue.append(chunk)


func _drain_collapse_queue() -> void:
	var released := 0
	while released < max_collapses_per_frame and not _collapse_queue.is_empty():
		var chunk = _collapse_queue.pop_front()
		_pending_collapse.erase(chunk)
		if not is_instance_valid(chunk) or not chunk.freeze:
			continue
		var owner_node := _owner_of(chunk)
		if owner_node == null:
			continue
		owner_node.collapse_chunk(chunk)
		owner_node.mark_collapsed(chunk)
		released += 1


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
		_tint_by_stability(_compute_stability())
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


# Stability propagation over the cached contact graph. Grounded chunks start at
# MAX_STABILITY. Support passed straight up is free; support passed sideways
# costs stability per metre of horizontal distance. A chunk keeps the best value
# reachable from any path, and falls if that best value is zero.
#
# This replaced a plain flood fill, which only asked "is there ANY path to the
# ground?". Under that rule two surviving wall stubs — or the top step of a
# staircase — held up an entire storey, because everything was connected to
# them through the floor slab. Connectivity isn't capacity; span is a decent
# stand-in for it.
func _compute_stability() -> Dictionary:
	var stability: Dictionary = {}
	var queue: Array = []
	for chunk in _grounded.keys():
		if _links.has(chunk):
			stability[chunk] = MAX_STABILITY
			queue.append(chunk)

	# Relax-until-stable (SPFA). Fine at a few hundred chunks; costs are
	# non-negative so it always terminates.
	while not queue.is_empty():
		var current = queue.pop_front()
		var current_value: float = stability[current]
		for neighbour in _links.get(current, []):
			# Non-load-bearing objects (furniture, stairs) can touch the graph but
			# never relay support onward.
			if not _links.has(neighbour):
				continue
			var value := current_value - _support_cost(current, neighbour)
			if value > stability.get(neighbour, 0.0):
				stability[neighbour] = value
				queue.append(neighbour)
	return stability


# What it costs to pass support from one chunk to a touching one.
func _support_cost(from: RigidBody3D, to: RigidBody3D) -> float:
	var decay := MAX_STABILITY / maxf(max_span, 0.1)
	var offset := to.global_position - from.global_position
	var cost := Vector2(offset.x, offset.z).length() * decay
	if offset.y < -0.05:
		# Hanging under the supporter rather than resting on it.
		cost += absf(offset.y) * decay * hang_cost_multiplier
	return cost


# Debug view: green chunks are solid, red ones are close to failing. Materials
# are bucketed so we aren't allocating one per chunk per check.
var _tint_materials: Array[StandardMaterial3D] = []

func _tint_by_stability(stability: Dictionary) -> void:
	if _tint_materials.is_empty():
		for i in 11:
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color.RED.lerp(Color.GREEN, i / 10.0)
			_tint_materials.append(mat)
	for chunk in _links.keys():
		if not is_instance_valid(chunk):
			continue
		var t := clampf(stability.get(chunk, 0.0) / MAX_STABILITY, 0.0, 1.0)
		var mat := _tint_materials[roundi(t * 10.0)]
		for child in chunk.get_children():
			if child is MeshInstance3D:
				child.material_override = mat


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


# Chunks currently simulating — broken or collapsed, and not yet asleep. This is
# what physics actually pays for. Walks every chunk, so call it a few times a
# second at most.
func count_awake_chunks() -> int:
	var awake := 0
	for d in _destructibles:
		if not is_instance_valid(d):
			continue
		for chunk in d.chunks:
			if is_instance_valid(chunk) and not chunk.freeze and not chunk.sleeping:
				awake += 1
	return awake


func get_standing_chunks() -> int:
	return _links.size()


func get_total_weight() -> float:
	return _total_weight


func get_destroyed_weight() -> float:
	return _destroyed_weight
