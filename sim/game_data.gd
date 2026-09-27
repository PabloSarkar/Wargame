## Loads the JSON data files once. Everything here is editable without code.
extends RefCounted

const DATA_DIR := "res://data/"

static var _cache: Dictionary = {}


static func _load(name: String) -> Dictionary:
	if _cache.has(name):
		return _cache[name]
	var path := DATA_DIR + name + ".json"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Missing data file: " + path)
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Bad JSON in " + path)
		return {}
	var d: Dictionary = parsed
	d.erase("_note")
	_cache[name] = d
	return d


static func troops() -> Dictionary:
	return _load("troops")


static func troop(type: String) -> Dictionary:
	return troops().get(type, {})


static func employers() -> Dictionary:
	return _load("employers")


static func employer(id: String) -> Dictionary:
	return employers().get(id, {})


static func provinces() -> Dictionary:
	return _load("provinces")


static func traits() -> Dictionary:
	return _load("traits")


static func events() -> Array:
	return _load("events").get("events", [])


const CAPTAIN_NAMES := [
	"Niccolò da Tolentino", "Bartolomeo Colleoni", "Gattamelata", "Jacopo Piccinino",
	"Micheletto Attendolo", "Astorre Manfredi", "Guidantonio da Montefeltro", "Carlo Fortebraccio",
	"Taliano Furlano", "Luigi dal Verme", "Pietro Navarrino", "Ciarpellone",
	"Roberto da Sanseverino", "Tiberto Brandolini", "Guido Rangoni", "Antonello da Corneto",
	"Bosio Sforza", "Giovanni Conti", "Ranuccio Farnese", "Orso Orsini",
	"Cristoforo da Tolentino", "Ludovico Malvezzi", "Gentile da Leonessa", "Matteo da Capua",
]

const SOLDIER_NICKNAMES := ["the Red", "Iron-Hand", "the Fox", "the Old", "Longsword", "the Bold", "the Deacon", "Crookback"]
