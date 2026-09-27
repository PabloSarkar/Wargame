## Plays a campaign headless with a simple policy, for the balance harness and tests.
## Policies: "honest" (never betrays or stages sham battles), "betrayer" (always
## accepts a better offer), "mixed" (sometimes does either).
extends RefCounted

const GameData := preload("res://sim/game_data.gd")
const Contracts := preload("res://sim/contracts.gd")

var policy: String = "honest"
var rng  # policy's own RNG, so decisions don't disturb the campaign's stream


func _init(p_policy: String, p_rng) -> void:
	policy = p_policy
	rng = p_rng


## Advances the campaign by one decision. Returns false when the run is over.
func step(c) -> bool:
	if c.ended:
		return false
	match c.phase:
		"board":
			_board(c)
		"prepare":
			_prepare(c)
			var err: String = c.finish_prepare()
			if err != "":
				# Could not afford a siege train: drop the contract rather than stall.
				c.log_line("Auto: " + err + " Contract abandoned.")
				c.contract = {}
				c.finish_prepare()
		"march":
			match c.march_pending():
				"event":
					c.choose_event(_pick_choice(c))
				"betrayal":
					if policy == "betrayer" or (policy == "mixed" and rng.chance(0.4)):
						c.accept_betrayal()
					else:
						c.reject_betrayal()
				"sham":
					if policy == "mixed" and rng.chance(0.3) or policy == "betrayer" and rng.chance(0.5):
						c.accept_sham()
					else:
						c.reject_sham()
				"ready":
					c.finish_march()
		"battle":
			c.auto_resolve()
		"siege":
			c.siege_action(c.siege.auto_choose(rng, c.company.florins))
		"aftermath":
			c.resolve_prisoners("ransom")
			var up: int = c.company.upkeep()
			c.ransom_own_men(c.company.florins - c.own_ransom_cost() > up)
			c.finish_aftermath()
		"payday":
			if not c.contract.is_empty() and c.contract.get("defaulted", false):
				c.walk_away()
			c.finish_payday()
		"winter":
			match c.winter_pending():
				"event":
					c.choose_event(_pick_choice(c))
				"lordship":
					c.seize_lordship(c.can_seize_lordship())
				"ready":
					if c.can_retire() and c.year >= 1450:
						c.retire()
					else:
						c.finish_winter()
	return not c.ended


func play(c, max_steps: int = 5000) -> void:
	var n := 0
	while step(c) and n < max_steps:
		n += 1


func _board(c) -> void:
	var best := -1
	var best_score := -INF
	var has_train: bool = c.company.has_troop("siege_train")
	for i in c.offers.size():
		var o: Dictionary = c.offers[i]
		var score: float = o.pay * o.reliability * (1.0 + 0.1 * o.term) + o.advance * 0.5
		if o.objective == "siege" and not has_train:
			if c.company.florins < c.hire_cost("siege_train") + c.company.upkeep():
				continue
			score -= 900
		if o.objective in ["garrison", "escort"]:
			score *= 1.1  # safer
		if o.captain_general:
			score *= 1.3
		if score > best_score:
			best_score = score
			best = i
	if best >= 0:
		c.sign_contract(best)
	else:
		c.skip_contract()


func _prepare(c) -> void:
	var co = c.company
	var up: int = co.upkeep()
	if not c.contract.is_empty() and c.contract.objective == "siege" and not co.has_troop("siege_train"):
		c.hire("siege_train")
	# Refill worn bands while money allows.
	for b in co.bands:
		var cost: int = c.refill_cost(b)
		if cost > 0 and co.florins - cost > co.upkeep() * 1.3:
			c.refill(b.id)
	# Grow to 6-7 bands if rich.
	var wanted := ["pikes", "crossbows", "lances", "swords", "light_horse"]
	if c.year >= 1448:
		wanted.append("handguns")
	var tries := 0
	while co.bands.size() < 7 and tries < 3:
		tries += 1
		var t: String = rng.pick(wanted)
		var cost: int = c.hire_cost(t)
		if co.florins - cost > (co.upkeep() + GameData.troop(t).upkeep) * 1.6:
			c.hire(t)
		else:
			break
	# If broke, shed the most expensive band.
	if co.florins < up * 0.3 and co.arrears > 0 and co.bands.size() > 4:
		var worst = null
		for b in co.bands:
			if worst == null or co.band_upkeep(b) > co.band_upkeep(worst):
				worst = b
		c.dismiss(worst.id)
	# Captains lead the biggest bands; field the five strongest field bands.
	var field := []
	for b in co.bands:
		if GameData.troop(b.type).get("field", true):
			field.append(b)
	field.sort_custom(func(a, b): return a.soldiers * GameData.troop(a.type).attack > b.soldiers * GameData.troop(b.type).attack)
	var ids := []
	for b in field.slice(0, 5):
		ids.append(b.id)
	c.set_battle_selection(ids)
	var i := 0
	for cap in co.captains:
		if i < field.size():
			co.assign_captain(cap.id, field[i].id)
		i += 1


func _pick_choice(c) -> int:
	var ev: Dictionary = c.current_event
	var avail := []
	for i in ev.choices.size():
		if ev.choices[i].available:
			avail.append(i)
	if avail.is_empty():
		return 0
	# Honest companies avoid choices that add infamy.
	if policy == "honest":
		var clean := []
		for i in avail:
			var bad := false
			for o in ev.def.choices[i].outcomes:
				if o.get("effects", {}).get("infamy", 0) > 0:
					bad = true
			if not bad:
				clean.append(i)
		if not clean.is_empty():
			avail = clean
	return rng.pick(avail)
