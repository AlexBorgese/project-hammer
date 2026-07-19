# Persists the player's coin balance and awards Gold/Silver/Bronze payouts based
# on level completion time.
extends Node

signal balance_changed(new_balance: int)
signal coins_awarded(amount: int, tier: String)

const SAVE_PATH := "user://currency.save"

const GOLD_TIME := 60.0
const SILVER_TIME := 120.0
const GOLD_REWARD := 150
const SILVER_REWARD := 75
const BRONZE_REWARD := 25

var _balance: int = 0


func _ready() -> void:
	_load()


func get_balance() -> int:
	return _balance


func add_coins(amount: int) -> void:
	if amount <= 0:
		return
	_balance += amount
	_save()
	balance_changed.emit(_balance)


func spend_coins(amount: int) -> bool:
	if amount <= 0 or amount > _balance:
		return false
	_balance -= amount
	_save()
	balance_changed.emit(_balance)
	return true


# Returns the tier name so the level-complete screen can show it.
func award_for_time(time: float) -> String:
	var tier := get_tier(time)
	var reward := get_reward(time)
	add_coins(reward)
	coins_awarded.emit(reward, tier)
	return tier


func get_tier(time: float) -> String:
	if time < GOLD_TIME:
		return "Gold"
	if time < SILVER_TIME:
		return "Silver"
	return "Bronze"


func get_reward(time: float) -> int:
	if time < GOLD_TIME:
		return GOLD_REWARD
	if time < SILVER_TIME:
		return SILVER_REWARD
	return BRONZE_REWARD


func _save() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("CurrencyManager: could not open save file for writing.")
		return
	file.store_string(JSON.stringify({"balance": _balance}))
	file.close()


func _load() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) == TYPE_DICTIONARY and parsed.has("balance"):
		_balance = int(parsed["balance"])
