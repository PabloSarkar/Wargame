## Seeded RNG. Every run has a seed so bugs and balance cases reproduce exactly.
extends RefCounted

var _rng := RandomNumberGenerator.new()
var seed_value: int = 0


func _init(p_seed: int = 0) -> void:
	set_seed(p_seed)


func set_seed(p_seed: int) -> void:
	seed_value = p_seed
	_rng.seed = p_seed
	_rng.state = p_seed


func get_state() -> int:
	return _rng.state


func set_state(s: int) -> void:
	_rng.state = s


func randf() -> float:
	return _rng.randf()


func randf_range(a: float, b: float) -> float:
	return _rng.randf_range(a, b)


func randi_range(a: int, b: int) -> int:
	return _rng.randi_range(a, b)


## True with probability p (0..1).
func chance(p: float) -> bool:
	return _rng.randf() < p


func pick(arr: Array):
	if arr.is_empty():
		return null
	return arr[_rng.randi_range(0, arr.size() - 1)]


## Picks an index from an array of non-negative weights.
func weighted_index(weights: Array) -> int:
	var total := 0.0
	for w in weights:
		total += float(w)
	if total <= 0.0:
		return -1
	var r := _rng.randf() * total
	for i in weights.size():
		r -= float(weights[i])
		if r < 0.0:
			return i
	return weights.size() - 1


func shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var t = arr[i]
		arr[i] = arr[j]
		arr[j] = t
