## The player's mercenary company: bands (formations), captains, money and reputation.
## Plain dictionaries so the whole thing serialises to a save file directly.
extends RefCounted

const GameData := preload("res://sim/game_data.gd")

const MAX_BANDS := 8
const MAX_CAPTAINS := 4
const FIELD_BANDS := 5
const RANK_XP := [0, 3, 7]  # xp needed for rank 1, 2, 3

var florins: int = 2000
var pennants: int = 0
var infamy: int = 0
var arrears: int = 0  # unpaid seasons of upkeep owed to the men
var bands: Array = []  # of Dictionary
var captains: Array = []  # of Dictionary; index 0 is normally the commander
var battle_selection: Array = []  # band ids fielded in battle (max 5)
var cargo: Dictionary = {"grain": 0, "iron": 0, "horses": 0}
var unlocked: Array = []  # troop types unlocked early by events
var _next_id: int = 1


func new_id() -> int:
	_next_id += 1
	return _next_id


func add_band(type: String, soldiers: int = -1) -> Dictionary:
	var t := GameData.troop(type)
	var maxs: int = t.get("soldiers", 50)
	var b := {
		"id": new_id(), "type": type,
		"soldiers": maxs if soldiers < 0 else mini(soldiers, maxs),
		"max": maxs, "xp": 0, "rank": 1, "captain_id": -1,
	}
	bands.append(b)
	if battle_selection.size() < FIELD_BANDS and t.get("field", true):
		battle_selection.append(b.id)
	return b


func remove_band(id: int) -> void:
	for i in bands.size():
		if bands[i].id == id:
			bands.remove_at(i)
			break
	battle_selection.erase(id)


func band(id: int) -> Dictionary:
	for b in bands:
		if b.id == id:
			return b
	return {}


func captain(id: int) -> Dictionary:
	for c in captains:
		if c.id == id:
			return c
	return {}


func commander() -> Dictionary:
	for c in captains:
		if c.get("is_commander", false):
			return c
	return {}


func captain_of_band(b: Dictionary) -> Dictionary:
	if b.is_empty() or b.captain_id < 0:
		return {}
	return captain(b.captain_id)


func bands_of_captain(cid: int) -> Array:
	var out := []
	for b in bands:
		if b.captain_id == cid:
			out.append(b)
	return out


func has_troop(type: String) -> bool:
	for b in bands:
		if b.type == type and b.soldiers > 0:
			return true
	return false


func has_trait(trait_id: String) -> bool:
	for c in captains:
		if trait_id in c.traits:
			return true
	return false


func band_upkeep(b: Dictionary) -> int:
	var t := GameData.troop(b.type)
	return int(t.get("upkeep", 0))


func upkeep() -> int:
	var total := 0
	for b in bands:
		total += band_upkeep(b)
	return total


func total_soldiers() -> int:
	var n := 0
	for b in bands:
		n += b.soldiers
	return n


func make_captain(rng, name: String = "", traits_list: Array = [], commander_flag: bool = false) -> Dictionary:
	if name == "":
		var used := []
		for c in captains:
			used.append(c.name)
		var pool := []
		for n in GameData.CAPTAIN_NAMES:
			if not n in used:
				pool.append(n)
		name = rng.pick(pool) if not pool.is_empty() else "Captain %d" % _next_id
	if traits_list.is_empty():
		var keys: Array = GameData.traits().keys()
		keys.sort()
		rng.shuffle(keys)
		traits_list = keys.slice(0, rng.randi_range(2, 3))
	var ability: String = rng.pick(["rally", "countercharge", "steady_volley"])
	var c := {
		"id": new_id(), "name": name,
		"command": rng.randi_range(35, 75), "valor": rng.randi_range(35, 75),
		"cunning": rng.randi_range(25, 75), "loyalty": rng.randi_range(50, 80),
		"traits": traits_list, "is_commander": commander_flag, "wounded": 0,
		"ability": ability,
	}
	if commander_flag:
		c.loyalty = 100
		c.command = maxi(c.command, 60)
	return c


func add_captain(c: Dictionary) -> void:
	captains.append(c)


func remove_captain(cid: int) -> void:
	for b in bands:
		if b.captain_id == cid:
			b.captain_id = -1
	for i in captains.size():
		if captains[i].id == cid:
			captains.remove_at(i)
			return


## Each captain commands one wing (band) in battle.
func assign_captain(cid: int, band_id: int) -> void:
	for b in bands:
		if b.captain_id == cid:
			b.captain_id = -1
	var b := band(band_id)
	if not b.is_empty():
		b.captain_id = cid


func trait_value(c: Dictionary, key: String, default_value = null):
	var traits := GameData.traits()
	for t in c.get("traits", []):
		var td: Dictionary = traits.get(t, {})
		if td.has(key):
			return td[key]
	return default_value


func add_xp(b: Dictionary, amount: int) -> void:
	b.xp += amount
	var r := 1
	for i in RANK_XP.size():
		if b.xp >= RANK_XP[i]:
			r = i + 1
	b.rank = r


func clamp_loyalty(c: Dictionary) -> void:
	var floor_v = trait_value(c, "loyalty_floor", 0)
	c.loyalty = clampi(c.loyalty, int(floor_v), 100)
	if c.get("is_commander", false):
		c.loyalty = 100


func field_bands() -> Array:
	var out := []
	for id in battle_selection:
		var b := band(id)
		if not b.is_empty() and b.soldiers > 0:
			out.append(b)
	# Fill empty slots automatically so a battle never starts short-handed.
	if out.size() < FIELD_BANDS:
		for b in bands:
			if out.size() >= FIELD_BANDS:
				break
			if b in out or b.soldiers <= 0:
				continue
			if GameData.troop(b.type).get("field", true):
				out.append(b)
	return out


func to_dict() -> Dictionary:
	return {
		"florins": florins, "pennants": pennants, "infamy": infamy, "arrears": arrears,
		"bands": bands.duplicate(true), "captains": captains.duplicate(true),
		"battle_selection": battle_selection.duplicate(), "cargo": cargo.duplicate(),
		"unlocked": unlocked.duplicate(), "next_id": _next_id,
	}


func from_dict(d: Dictionary) -> void:
	florins = int(d.florins)
	pennants = int(d.pennants)
	infamy = int(d.infamy)
	arrears = int(d.arrears)
	bands = _intify(d.bands)
	captains = _intify(d.captains)
	battle_selection = []
	for x in d.battle_selection:
		battle_selection.append(int(x))
	cargo = {}
	for k in d.cargo:
		cargo[k] = int(d.cargo[k])
	unlocked = d.unlocked.duplicate()
	_next_id = int(d.next_id)


## JSON turns ints into floats; restore the integer fields.
static func _intify(arr: Array) -> Array:
	var out := []
	for item in arr:
		var dd: Dictionary = item.duplicate(true)
		for k in dd:
			if typeof(dd[k]) == TYPE_FLOAT and k != "loyalty_f":
				dd[k] = int(dd[k])
		out.append(dd)
	return out
