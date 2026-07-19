# Stores and persists the top 3 fastest completion times for each level.
extends Node

signal leaderboard_updated(level_id: String, times: Array)
signal new_record(level_id: String, time: float, rank: int)

const SAVE_PATH := "user://leaderboard.save"
const MAX_ENTRIES := 3

# level_id -> Array[float], sorted ascending (fastest first).
var _times: Dictionary = {}


func _ready() -> void:
	_load()


func submit_time(level_id: String, time: float) -> int:
	var entries: Array = _times.get(level_id, []).duplicate()
	entries.append(time)
	entries.sort()
	if entries.size() > MAX_ENTRIES:
		entries.resize(MAX_ENTRIES)
	_times[level_id] = entries
	_save()
	leaderboard_updated.emit(level_id, entries)

	var rank := entries.find(time)
	if rank != -1:
		new_record.emit(level_id, time, rank + 1)
		return rank + 1
	return -1


func get_times(level_id: String) -> Array:
	return _times.get(level_id, []).duplicate()


func get_best_time(level_id: String) -> float:
	var entries: Array = get_times(level_id)
	return entries[0] if not entries.is_empty() else -1.0


func clear_level(level_id: String) -> void:
	_times.erase(level_id)
	_save()


func _save() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("LeaderboardManager: could not open save file for writing.")
		return
	file.store_string(JSON.stringify(_times))
	file.close()


func _load() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	for key in parsed.keys():
		var floats: Array = []
		for v in parsed[key]:
			floats.append(float(v))
		_times[key] = floats
