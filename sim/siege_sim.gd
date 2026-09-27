## Sieges: a lighter mode on the campaign map. A supply clock against the garrison's
## morale, with a weekly choice to bombard, starve, bribe or storm. Storming plays out
## as a real-time battle at the breach.
extends RefCounted

const MAX_WEEKS := 14
const ACTIONS := ["bombard", "starve", "bribe", "storm"]

var town: String
var walls: float  # 0 = breached wide open, 100 = intact
var garrison_morale: float = 100.0
var garrison_supply: int
var our_supply: int
var week: int = 0
var done: bool = false
var result: String = ""  # "taken", "failed", "storm" (storm pending battle)
var has_train: bool = false
var siege_mult: float = 1.0
var cunning: int = 50
var log: Array = []


func setup(rng, p_town: String, p_walls: int, p_has_train: bool, p_cunning: int, p_siege_mult: float, light_horse: bool) -> void:
	town = p_town
	walls = p_walls
	has_train = p_has_train
	cunning = p_cunning
	siege_mult = p_siege_mult
	garrison_supply = rng.randi_range(7, 12)
	our_supply = 9 + (3 if light_horse else 0)


func bribe_cost() -> int:
	return int(150 + walls * 4 + garrison_morale * 3)


func can(action: String, florins: int) -> bool:
	match action:
		"bombard":
			return has_train
		"bribe":
			return florins >= bribe_cost()
	return true


## Returns florins spent this week.
func act(rng, action: String) -> int:
	if done:
		return 0
	week += 1
	var spent = 0
	match action:
		"bombard":
			var hit = 16.0 * siege_mult * rng.randf_range(0.7, 1.3)
			walls = maxf(0.0, walls - hit)
			garrison_morale -= 5.0
			_log("Week %d: the bombards knock down %d%% of the walls." % [week, int(hit)])
		"starve":
			garrison_supply -= 1
			garrison_morale -= 3.0
			_log("Week %d: the blockade tightens." % week)
		"bribe":
			spent = bribe_cost()
			var p = cunning / 200.0 + (100.0 - garrison_morale) / 200.0
			if rng.chance(clampf(p, 0.05, 0.9)):
				_log("Week %d: a gate is left unbarred at night. The town is yours." % week)
				_finish("taken")
				return spent
			garrison_morale += 5.0
			_log("Week %d: the bribe is refused, and the garrison takes heart." % week)
		"storm":
			_log("Week %d: you order the assault on the breach." % week)
			done = true
			result = "storm"
			return 0
	_week_passes()
	return spent


func _week_passes() -> void:
	garrison_supply -= 1
	our_supply -= 1
	garrison_morale -= 2.0
	if garrison_supply <= 0:
		garrison_morale -= 12.0
	if garrison_morale <= 0.0:
		_log("The garrison surrenders.")
		_finish("taken")
	elif our_supply <= 0 or week >= MAX_WEEKS:
		_log("Supplies run out and a relief army approaches. The siege is lifted.")
		_finish("failed")


## Defender bonus when storming: high walls make the breach a killing ground.
func storm_walls_bonus() -> float:
	return walls / 100.0 * 8.0


func defender_strength_mult() -> float:
	return clampf(0.4 + garrison_morale / 150.0, 0.4, 1.1)


func _finish(r: String) -> void:
	done = true
	result = r


func _log(s: String) -> void:
	log.append(s)


func auto_choose(rng, florins: int) -> String:
	if garrison_morale <= 25.0 and walls < 40.0:
		return "storm"
	if has_train and walls > 20.0:
		return "bombard"
	if can("bribe", florins) and florins > bribe_cost() * 3 and rng.chance(0.3):
		return "bribe"
	if not has_train and our_supply <= 2:
		return "storm"
	return "starve"
