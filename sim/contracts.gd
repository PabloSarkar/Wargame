## Contract (condotta) generation and the offer formula.
##   Offer = Upkeep * (1.1 + 0.4 * Desperation) * (1 + 0.03 * Pennants) * Reliability
extends RefCounted

const GameData := preload("res://sim/game_data.gd")

const ADVANCE_SHARE := 0.25
const TERM_MULT := {1: 1.0, 2: 0.92, 3: 0.85}  # longer terms pay less per season
const OBJECTIVE_MULT := {"field": 1.0, "siege": 1.2, "garrison": 0.75, "raid": 0.85, "escort": 0.7}
const OBJECTIVES := ["field", "siege", "garrison", "raid", "escort"]
const OBJECTIVE_TEXT := {
	"field": "Meet the enemy army in the field",
	"siege": "Besiege and take the town",
	"garrison": "Hold the town against attack",
	"raid": "Raid enemy lands",
	"escort": "Escort a supply convoy",
}


## Pennant tier (who hires you): 0 = minor lords only, 1 = major powers small contracts,
## 2 = captain-general offers, 3 = lordship opportunities.
static func pennant_tier(pennants: int) -> int:
	if pennants >= 20:
		return 3
	if pennants >= 10:
		return 2
	if pennants >= 5:
		return 1
	return 0


static func tier_name(pennants: int) -> String:
	return ["Minor lords only", "Major powers, small contracts", "Captain-general offers", "Lordship opportunities"][pennant_tier(pennants)]


static func offer_pay(upkeep: int, desperation: float, pennants: int, reliability: float) -> int:
	return int(round(upkeep * (1.1 + 0.4 * desperation) * (1.0 + 0.03 * pennants) * reliability))


static func reliability(employer_id: String, world) -> float:
	var e = GameData.employer(employer_id)
	var r: float = e.reliability
	if e.get("desperation_unreliable", false):
		r -= 0.25 * world.desperation(employer_id)
	return clampf(r, 0.6, 1.0)


## Builds 3-4 offers for the contract board.
static func generate_offers(rng, company, world, year: int, location: String) -> Array:
	var tier = pennant_tier(company.pennants)
	var candidates = []
	for id in GameData.employers():
		if not world.is_alive(id):
			continue
		var e = GameData.employer(id)
		if world.enemies_of(id).is_empty():
			continue  # only employers at war need a company
		if world.trust(id) < -20:
			continue  # hostile
		if e.major and tier == 0:
			continue
		# High infamy closes doors, except with the desperate.
		if company.infamy >= 40 and world.trust(id) < 20 and world.desperation(id) < 0.6:
			continue
		candidates.append(id)
	candidates.sort()
	rng.shuffle(candidates)
	var offers = []
	var count = rng.randi_range(3, 4)
	var i = 0
	while offers.size() < count and not candidates.is_empty() and i < 12:
		var emp: String = candidates[i % candidates.size()]
		i += 1
		var o = make_offer(rng, emp, company, world, year, tier)
		if not o.is_empty():
			offers.append(o)
	return offers


static func make_offer(rng, emp: String, company, world, year: int, tier: int) -> Dictionary:
	var e = GameData.employer(emp)
	var foes: Array = world.enemies_of(emp)
	if foes.is_empty():
		return {}
	foes.sort()
	var enemy: String = rng.pick(foes)
	var objective: String = rng.pick(OBJECTIVES)
	var target = ""
	if objective == "garrison" or objective == "escort":
		var own: Array = world.border_towns(enemy, emp)
		target = rng.pick(own) if not own.is_empty() else ""
	else:
		var theirs: Array = world.border_towns(emp, enemy)
		target = rng.pick(theirs) if not theirs.is_empty() else ""
	if target == "":
		return {}
	var term = rng.randi_range(1, 3)
	var desp: float = world.desperation(emp)
	var rel = reliability(emp, world)
	var base_upkeep: int = maxi(company.upkeep(), 600)
	var pay = float(offer_pay(base_upkeep, desp, company.pennants, rel))
	pay *= TERM_MULT[term] * OBJECTIVE_MULT[objective] * e.size
	var captain_general = false
	if e.major and tier == 1:
		pay *= 0.85
		term = mini(term, 2)
	elif e.major and tier >= 2 and rng.chance(0.4):
		captain_general = true
		pay *= 1.35
		term = maxi(term, 2)
	if company.infamy >= 40:
		pay *= 0.85  # only cheap offers for the untrustworthy
	var clauses = []
	var supervisor: bool = rng.chance(e.supervisor_chance)
	if supervisor:
		clauses.append("supervisor")
	if rng.chance(0.25):
		clauses.append("exclusivity")
	if rng.chance(0.2 if objective != "raid" else 0.0):
		clauses.append("no_plunder")
	var pay_i = int(round(pay / 10.0)) * 10
	var total = pay_i * term
	return {
		"employer": emp, "enemy": enemy, "objective": objective, "target": target,
		"pay": pay_i, "term": term, "advance": int(round(total * ADVANCE_SHARE / 10.0)) * 10,
		"clauses": clauses, "captain_general": captain_general,
		"reliability": rel, "desperation": desp,
		"seasons_served": 0, "owed": 0, "paid": 0, "year_signed": year,
	}


static func describe(o: Dictionary) -> String:
	var e = GameData.employer(o.employer)
	var s = "%s against %s: %s at %s. %d florins per season for %d season%s, advance %d." % [
		e.name, GameData.employer(o.enemy).name, OBJECTIVE_TEXT[o.objective],
		GameData.provinces()[o.target].name, o.pay, o.term, "" if o.term == 1 else "s", o.advance]
	if o.captain_general:
		s += " Captain-general's baton."
	if not o.clauses.is_empty():
		s += " Clauses: " + ", ".join(o.clauses) + "."
	return s
