## One campaign, spring 1440 to the Peace of Lodi in 1454: 15 yearly loops.
## Each loop: contract board -> prepare company -> march and events -> battle or siege
## -> payday and ransom -> winter quarters. Betrayal is the one move that skips back
## to the board mid-year.
##
## Pure rules, no scene dependencies: the UI and the balance harness both drive it
## through the public methods below.
extends RefCounted

const GameData := preload("res://sim/game_data.gd")
const Rng := preload("res://sim/rng.gd")
const Company := preload("res://sim/company.gd")
const World := preload("res://sim/world.gd")
const Contracts := preload("res://sim/contracts.gd")
const EventEngine := preload("res://sim/event_engine.gd")
const BattleSim := preload("res://sim/battle_sim.gd")
const SiegeSim := preload("res://sim/siege_sim.gd")

const START_YEAR := 1440
const END_YEAR := 1454
const SAVE_VERSION := 1
const RETIRE_FLORINS := 15000
const LORDSHIP_PENNANTS := 20
const CAPTAIN_GENERAL_PENNANTS := 10
const START_LOCATION := "ferrara"
const REBUILD_COST := 250  # rough price of one cheap band, for the ruin check
const LORDSHIP_COST := 5000
const LORDSHIP_SOLDIERS := 300

var rng
var seed_value: int
var year: int = START_YEAR
var phase: String = "board"  # board, prepare, march, battle, siege, aftermath, payday, winter, ended
var company
var world
var location: String = START_LOCATION
var offers: Array = []
var contract: Dictionary = {}
var weather: String = "clear"
var pending_skirmish: String = ""
var plundered: bool = false
var won_this_year: bool = false
var lost_this_year: bool = false
var season_result: Dictionary = {}  # what the company did for the world tick

var event_queue: Array = []  # event ids still to arrive this phase
var current_event: Dictionary = {}
var last_outcome: String = ""
var betrayal_offer: Dictionary = {}
var sham_offer: bool = false
var sham_done: bool = false
var lordship_offer: Dictionary = {}

var engagements: Array = []  # queue of {kind, ...}
var engagement: Dictionary = {}
var siege
var aftermath: Dictionary = {}
var report: Array = []  # payday / winter report lines
var log: Array = []
var seen_events: Array = []
var events_this_year: Array = []

var ended: bool = false
var ending: String = ""
var won: bool = false
var captain_general_held: bool = false
var stats: Dictionary = {}


# ================================================================ setup

func new_campaign(p_seed: int) -> void:
	seed_value = p_seed
	rng = Rng.new(p_seed)
	company = Company.new()
	world = World.new()
	world.setup(rng)
	year = START_YEAR
	location = START_LOCATION
	stats = {"betrayals": 0, "shams": 0, "shams_caught": 0, "battles_won": 0, "battles_lost": 0,
		"battles_drawn": 0, "contracts_completed": 0, "contracts_broken": 0, "seasons": 0,
		"low_bank_seasons": 0, "defaults": 0, "late_payments": 0, "desertions": 0, "defections": 0,
		"income": 0, "sieges_taken": 0}
	# Starting state: 2,000 florins and 6 bands (2 lances, 2 crossbows, 2 pikemen).
	company.florins = 2000
	var cmd = company.make_captain(rng, "You", ["old_soldier"], true)
	cmd.name = "The Commander"
	company.add_captain(cmd)
	for i in 2:
		company.add_captain(company.make_captain(rng))
	for t in ["lances", "lances", "crossbows", "crossbows", "pikes", "pikes"]:
		company.add_band(t)
	company.battle_selection = []
	for b in company.bands:
		if company.battle_selection.size() < Company.FIELD_BANDS:
			company.battle_selection.append(b.id)
	var caps = company.captains
	for i in caps.size():
		company.assign_captain(caps[i].id, company.bands[i].id)
	log_line("Spring %d. Your company of %d men looks for work." % [year, company.total_soldiers()])
	_start_year()


func _start_year() -> void:
	events_this_year.clear()
	weather = "clear"
	plundered = false
	won_this_year = false
	lost_this_year = false
	sham_done = false
	season_result = {}
	betrayal_offer = {}
	lordship_offer = {}
	if contract.is_empty():
		offers = Contracts.generate_offers(rng, company, world, year, location)
		phase = "board"
	else:
		offers = []
		phase = "prepare"
		log_line("Your condotta with %s continues (season %d of %d)." % [GameData.employer(contract.employer).name, contract.seasons_served + 1, contract.term])


func log_line(s: String) -> void:
	log.append("%d: %s" % [year, s])


func non_commander_captains() -> Array:
	var out = []
	for c in company.captains:
		if not c.get("is_commander", false):
			out.append(c)
	return out


# ================================================================ 1. contract board

func sign_contract(i: int) -> String:
	if phase != "board" or i < 0 or i >= offers.size():
		return "No such offer."
	contract = offers[i].duplicate(true)
	offers = []
	company.florins += contract.advance
	contract.paid = contract.advance
	stats.income += contract.advance
	log_line("Signed with %s: %s" % [GameData.employer(contract.employer).name, Contracts.describe(contract)])
	phase = "prepare"
	return ""


func skip_contract() -> void:
	if phase != "board":
		return
	offers = []
	log_line("No condotta this year. The company waits in %s." % GameData.provinces()[location].name)
	phase = "prepare"


# ================================================================ 2. prepare company

func hire_cost(type: String) -> int:
	var t = GameData.troop(type)
	return int(round(t.hire * world.recruit_mult(location, t.get("cavalry", false))))


func can_hire(type: String) -> bool:
	var t = GameData.troop(type)
	if t.is_empty():
		return false
	if year < t.get("unlock_year", START_YEAR) and not type in company.unlocked:
		return false
	return company.bands.size() < Company.MAX_BANDS


func hire(type: String) -> String:
	if phase != "prepare":
		return "You can only hire while preparing."
	if not can_hire(type):
		return "Cannot hire that band now."
	var cost = hire_cost(type)
	if company.florins < cost:
		return "Not enough florins."
	company.florins -= cost
	company.add_band(type)
	return ""


func refill_cost(b: Dictionary) -> int:
	var missing: int = b.max - b.soldiers
	if missing <= 0:
		return 0
	return int(ceil(hire_cost(b.type) * float(missing) / b.max * 0.8))


func refill(band_id: int) -> String:
	var b: Dictionary = company.band(band_id)
	if b.is_empty() or phase != "prepare":
		return "Cannot refill now."
	var cost = refill_cost(b)
	if cost <= 0:
		return ""
	if company.florins < cost:
		return "Not enough florins."
	company.florins -= cost
	# Fresh recruits dilute experience.
	var frac = float(b.soldiers) / b.max
	b.xp = int(b.xp * (0.5 + 0.5 * frac))
	company.add_xp(b, 0)
	b.soldiers = b.max
	return ""


func dismiss(band_id: int) -> void:
	if phase == "prepare":
		company.remove_band(band_id)


func assign_captain(cid: int, band_id: int) -> void:
	company.assign_captain(cid, band_id)


func set_battle_selection(ids: Array) -> void:
	company.battle_selection = ids.slice(0, Company.FIELD_BANDS)


func good_price(g: String, pid: String = "") -> int:
	if pid == "":
		pid = location
	return world.towns[pid].price[g]


func cargo_capacity() -> int:
	var cap = 10
	for b in company.bands:
		if b.type == "light_horse":
			cap += 15
	return cap


func cargo_total() -> int:
	var n = 0
	for g in company.cargo:
		n += company.cargo[g]
	return n


func buy_good(g: String, n: int = 1) -> String:
	var price = good_price(g)
	n = mini(n, cargo_capacity() - cargo_total())
	if n <= 0:
		return "No room in the baggage train."
	if company.florins < price * n:
		return "Not enough florins."
	company.florins -= price * n
	company.cargo[g] += n
	return ""


func sell_good(g: String, n: int = -1) -> int:
	if n < 0:
		n = company.cargo[g]
	n = mini(n, company.cargo[g])
	var got = good_price(g) * n
	company.cargo[g] -= n
	company.florins += got
	return got


func finish_prepare() -> String:
	if phase != "prepare":
		return "Not preparing."
	if not contract.is_empty() and contract.objective == "siege" and not company.has_troop("siege_train"):
		return "A siege contract needs a siege train. Hire one first."
	if company.field_bands().is_empty():
		_check_losing()
		return "You have no bands to field."
	_start_march()
	return ""


# ================================================================ 3. march and events

func _start_march() -> void:
	phase = "march"
	event_queue = []
	var n = 1 + (1 if rng.chance(0.5) else 0)
	if not contract.is_empty() and GameData.employer(contract.employer).get("far", false):
		n += 1
	for i in n:
		event_queue.append("march")
	if not contract.is_empty():
		location = contract.target
	current_event = {}
	last_outcome = ""
	# A rival may try to buy the company mid-contract.
	if not contract.is_empty() and rng.chance(0.35):
		betrayal_offer = _make_betrayal_offer()
	# Sham battles: when the enemy is also led by a condottiere.
	sham_offer = not contract.is_empty() and contract.objective == "field" and rng.chance(0.6)
	_next_event()


func _next_event() -> void:
	current_event = {}
	while not event_queue.is_empty() and current_event.is_empty():
		var ph: String = event_queue.pop_front()
		var ev = EventEngine.pick_event(rng, self, ph)
		if not ev.is_empty():
			events_this_year.append(ev.id)
			if not ev.id in seen_events:
				seen_events.append(ev.id)
			current_event = EventEngine.instantiate(rng, ev, self)


## What the march step is waiting on: "event", "betrayal", "sham" or "ready".
func march_pending() -> String:
	if not current_event.is_empty():
		return "event"
	if not betrayal_offer.is_empty():
		return "betrayal"
	if sham_offer and not sham_done:
		return "sham"
	return "ready"


func choose_event(i: int) -> String:
	if current_event.is_empty():
		return ""
	var ch: Dictionary = current_event.choices[i]
	if not EventEngine.choice_available(current_event.def.choices[i], self):
		return ""
	last_outcome = EventEngine.resolve(rng, current_event, i, self)
	log_line("%s: %s %s" % [current_event.title, ch.text, last_outcome])
	_next_event()
	return last_outcome


func _make_betrayal_offer() -> Dictionary:
	var rivals = []
	for f in world.enemies_of(contract.employer):
		if world.is_alive(f) and world.trust(f) > -20:
			rivals.append(f)
	if rivals.is_empty():
		return {}
	rivals.sort()
	var rival: String = rng.pick(rivals)
	var mult = rng.randf_range(1.5, 2.0)
	var remaining: int = maxi(1, contract.term - contract.seasons_served)
	return {"employer": rival, "mult": mult, "pay": int(round(contract.pay * mult / 10.0)) * 10, "term": remaining}


## Detection chance when betraying or staging a sham battle under a watchful employer.
func detection_chance(employer_id: String, supervised: bool) -> float:
	var e = GameData.employer(employer_id)
	var cunning = best_cunning()
	var base: float = e.vigilance / 100.0
	if supervised:
		base += 0.25
	return clampf(base - (cunning - 50) / 200.0, 0.03, 0.8)


func best_cunning() -> int:
	var best = 0
	for c in company.captains:
		var v: int = c.cunning + int(company.trait_value(c, "cunning_bonus", 0))
		best = maxi(best, v)
	return best


func accept_betrayal() -> String:
	if betrayal_offer.is_empty():
		return ""
	var old: String = contract.employer
	var old_e = GameData.employer(old)
	var offer = betrayal_offer
	betrayal_offer = {}
	stats.betrayals += 1
	# Being caught plotting can end a run.
	if "supervisor" in contract.clauses and rng.chance(detection_chance(old, true)):
		world.add_trust(old, -60)
		company.infamy = clampi(company.infamy + 20, 0, 100)
		if old == "venice" or rng.chance(0.25):
			log_line("The %s proveditore uncovers your letters. You are summoned, arrested and beheaded between the columns, as Carmagnola was." % old_e.name)
			_end("executed", false)
			return "executed"
		company.florins = int(company.florins * 0.6)
		log_line("Your plot is discovered. You buy your way out of %s's prison, but the new contract is gone." % old_e.name)
		contract = {}
		stats.contracts_broken += 1
		return "caught"
	# Forfeit the advance.
	var refund: int = mini(contract.advance, company.florins)
	company.florins -= refund
	if refund < contract.advance:
		company.infamy += 5
	company.pennants = maxi(0, company.pennants - 1)
	company.infamy = clampi(company.infamy + 15 + (5 if "exclusivity" in contract.clauses else 0), 0, 100)
	world.add_trust(old, -60)
	for c in company.captains:
		c.loyalty += int(company.trait_value(c, "betrayal_loyalty", 0))
		company.clamp_loyalty(c)
	stats.contracts_broken += 1
	var targets: Array = world.border_towns(offer.employer, old)
	var new_c = {
		"employer": offer.employer, "enemy": old, "objective": "field",
		"target": rng.pick(targets) if not targets.is_empty() else contract.target,
		"pay": offer.pay, "term": offer.term, "advance": 0, "clauses": [],
		"captain_general": false, "reliability": Contracts.reliability(offer.employer, world),
		"desperation": world.desperation(offer.employer), "seasons_served": 0, "owed": 0, "paid": 0,
		"year_signed": year,
	}
	log_line("You turn your banners. %s now pays you %d florins per season; %s will not forget." % [GameData.employer(offer.employer).name, offer.pay, old_e.name])
	contract = new_c
	location = contract.target
	sham_offer = rng.chance(0.6)
	return "betrayed"


func reject_betrayal() -> void:
	if not betrayal_offer.is_empty():
		log_line("You refuse %s's gold." % GameData.employer(betrayal_offer.employer).name)
		world.add_trust(contract.employer, 3)
	betrayal_offer = {}


func accept_sham() -> String:
	sham_done = true
	sham_offer = false
	stats.shams += 1
	var supervised: bool = "supervisor" in contract.clauses
	var p = detection_chance(contract.employer, supervised) * (1.0 if supervised else 0.5)
	# Few losses either way.
	for b in company.field_bands():
		b.soldiers = maxi(1, int(round(b.soldiers * 0.97)))
	engagements = []
	if rng.chance(p):
		stats.shams_caught += 1
		world.add_trust(contract.employer, -50)
		company.infamy = clampi(company.infamy + 20, 0, 100)
		company.pennants = maxi(0, company.pennants - 2)
		if contract.employer == "venice" and rng.chance(0.5) or world.trust(contract.employer) < -40 and rng.chance(0.25):
			log_line("The sham battle is exposed. %s tries you for treachery and you are executed." % GameData.employer(contract.employer).name)
			_end("executed", false)
			return "executed"
		log_line("The sham battle is exposed. %s is furious." % GameData.employer(contract.employer).name)
		season_result = {"side": contract.employer, "against": contract.enemy, "won": false}
		return "caught"
	log_line("You and the enemy captain stage a noisy, bloodless day. Honour is satisfied; nobody is hurt.")
	season_result = {"side": contract.employer, "against": contract.enemy, "won": false}
	contract["sham_this_season"] = true
	return "ok"


func reject_sham() -> void:
	sham_done = true
	sham_offer = false


func finish_march() -> String:
	if march_pending() != "ready":
		return "Deal with the letters first."
	if ended:
		return ""
	engagements = []
	if pending_skirmish != "":
		engagements.append({"kind": "skirmish", "size": 2})
		pending_skirmish = ""
	if not contract.is_empty() and not contract.get("sham_this_season", false):
		match contract.objective:
			"field":
				engagements.append({"kind": "field", "size": 5})
			"siege":
				engagements.append({"kind": "siege"})
			"garrison":
				if rng.chance(0.5):
					engagements.append({"kind": "garrison", "size": 4})
				else:
					log_line("The garrison season passes quietly.")
			"raid":
				engagements.append({"kind": "raid", "size": 3 if rng.chance(0.6) else 0})
			"escort":
				if rng.chance(0.5):
					engagements.append({"kind": "escort", "size": 3})
				else:
					log_line("The convoy arrives without incident.")
	if contract.is_empty():
		season_result = {}
	_next_engagement()
	return ""


func _next_engagement() -> void:
	engagement = {}
	while not engagements.is_empty():
		var e: Dictionary = engagements.pop_front()
		if e.kind == "raid":
			if not "no_plunder" in contract.clauses:
				var loot = rng.randi_range(200, 450)
				company.florins += loot
				plundered = true
				stats.income += loot
				log_line("Your raiders burn and loot the countryside: %d florins." % loot)
			if e.size == 0:
				_mark_objective(true)
				continue
		if e.kind == "siege":
			_start_siege()
			return
		engagement = e
		engagement.enemy = make_enemy_army(e.kind, e.get("size", 5))
		engagement.terrain = "breach" if e.kind == "storm" else rng.pick(["open", "hills", "woods", "river", "open"])
		phase = "battle"
		return
	phase = "payday"
	_do_payday()


# ================================================================ 4. battle or siege

func make_enemy_army(kind: String, size: int) -> Array:
	var pool = ["lances", "pikes", "crossbows", "swords", "light_horse", "pikes", "crossbows"]
	if year >= 1448:
		pool.append("handguns")
	var diff = 0.9 + 0.022 * (year - START_YEAR) + 0.04 * Contracts.pennant_tier(company.pennants)
	if kind in ["skirmish", "raid", "escort"]:
		diff *= 0.9
	if kind == "storm" and siege != null:
		diff *= siege.defender_strength_mult()
	var rank = 1 + int((year - START_YEAR) / 6)
	var army = []
	var cap = {"name": rng.pick(GameData.CAPTAIN_NAMES), "command": rng.randi_range(35, 70), "valor": rng.randi_range(35, 70), "cunning": 50, "loyalty": 50, "traits": [], "ability": rng.pick(["rally", "countercharge", "steady_volley"])}
	for i in size:
		var type: String = pool[i] if i < 3 and kind == "field" else rng.pick(pool)
		var maxs: int = GameData.troop(type).soldiers
		army.append({"type": type, "soldiers": int(maxs * diff * rng.randf_range(0.85, 1.05)), "rank": rank, "captain": cap if i < 2 else {}})
	return army


func create_battle(player_ai: bool = false):
	var b = BattleSim.new(rng)
	b.player_ai = player_ai
	b.weather = weather
	b.setup_terrain(engagement.get("terrain", "open"))
	if engagement.kind == "storm" and siege != null:
		b.walls_bonus = siege.storm_walls_bonus()
	var scouted = false
	for band in company.field_bands():
		var cap: Dictionary = company.captain_of_band(band)
		if not cap.is_empty() and cap.wounded > 0:
			cap = {}
		b.add_formation(0, band.type, band.soldiers, band.rank, cap.duplicate(true), band.id)
		if band.type == "light_horse":
			scouted = true
	b.scouted = scouted
	for e in engagement.enemy:
		b.add_formation(1, e.type, e.soldiers, e.rank, e.captain)
	b.auto_deploy(0)
	b.auto_deploy(1)
	return b


func auto_resolve() -> Dictionary:
	var b = create_battle(true)
	b.run_to_end()
	var r: Dictionary = b.result()
	finish_battle(r)
	return r


func finish_battle(r: Dictionary) -> void:
	if phase != "battle":
		return
	var kind: String = engagement.kind
	var won_battle: bool = r.winner == 0
	var lost_battle: bool = r.winner == 1
	# Update bands.
	var own_captured = 0
	for bid in r.bands:
		var info: Dictionary = r.bands[bid]
		var band: Dictionary = company.band(int(bid))
		if band.is_empty():
			continue
		band.soldiers = maxi(0, info.soldiers)
		own_captured += info.captured
		if info.fought:
			company.add_xp(band, 2 if won_battle else 1)
	for band in company.bands.duplicate():
		if band.soldiers <= 0:
			log_line("The %s band is gone." % GameData.troop(band.type).name)
			company.remove_band(band.id)
	_check_losing()
	if ended:
		return
	var text = "draw"
	if won_battle:
		text = "victory"
		stats.battles_won += 1
		won_this_year = true
		company.pennants += 3 if r.famous else 1
		for c in company.captains:
			c.loyalty += 5 + int(company.trait_value(c, "victory_loyalty", 0))
			company.clamp_loyalty(c)
	elif lost_battle:
		text = "defeat"
		stats.battles_lost += 1
		lost_this_year = true
		if r.crushing:
			company.pennants = maxi(0, company.pennants - 2)
			text = "crushing defeat"
		for c in company.captains:
			c.loyalty += -3 + int(company.trait_value(c, "defeat_loyalty", 0))
			company.clamp_loyalty(c)
	else:
		stats.battles_drawn += 1
	log_line("Battle (%s): %s. Enemy prisoners %d, your men captured %d." % [kind, text, r.enemy_prisoners, own_captured])
	if r.famous:
		log_line("A famous victory against the odds!")
	# The commander may fall.
	if r.commander_exposed or (lost_battle and rng.chance(0.08)):
		var cmd: Dictionary = company.commander()
		var p = 0.25 * float(company.trait_value(cmd, "death_chance_mult", 1.0))
		if rng.chance(p):
			_commander_dies("cut down in the rout")
			if ended:
				return
	aftermath = {"kind": kind, "won": won_battle, "lost": lost_battle, "prisoners": r.enemy_prisoners if won_battle else 0, "own_captured": own_captured, "result_text": text}
	if kind == "storm":
		if won_battle:
			_siege_taken()
		else:
			log_line("The assault fails at the breach.")
			_mark_objective(false)
	elif kind in ["field", "garrison", "escort", "raid"]:
		_mark_objective(won_battle)
		if not contract.is_empty():
			season_result = {"side": contract.employer, "against": contract.enemy, "won": won_battle}
	phase = "aftermath"


func _mark_objective(success: bool) -> void:
	if contract.is_empty():
		return
	contract["success"] = contract.get("success", 0) + (1 if success else 0)
	contract["failures"] = contract.get("failures", 0) + (0 if success else 1)


func _start_siege() -> void:
	siege = SiegeSim.new()
	var walls: int = GameData.provinces()[contract.target].walls
	var cunning = best_cunning()
	var mult = 1.0
	for c in company.captains:
		mult = maxf(mult, float(company.trait_value(c, "siege_mult", 1.0)))
	siege.setup(rng, contract.target, walls, company.has_troop("siege_train"), cunning, mult, company.has_troop("light_horse"))
	phase = "siege"


func siege_action(action: String) -> String:
	if phase != "siege" or siege == null:
		return "No siege."
	if not siege.can(action, company.florins):
		return "You cannot do that."
	var spent: int = siege.act(rng, action)
	company.florins -= spent
	if siege.done:
		match siege.result:
			"taken":
				_siege_taken()
				_next_engagement()
			"failed":
				log_line("The siege of %s fails." % GameData.provinces()[siege.town].name)
				_mark_objective(false)
				season_result = {"side": contract.employer, "against": contract.enemy, "won": false}
				_next_engagement()
			"storm":
				engagement = {"kind": "storm", "size": 4}
				engagement.enemy = make_enemy_army("storm", 4)
				engagement.terrain = "breach"
				phase = "battle"
	return ""


func _siege_taken() -> void:
	stats.sieges_taken += 1
	won_this_year = true
	company.pennants += 1
	var loot = 0
	if not "no_plunder" in contract.clauses:
		loot = rng.randi_range(400, 900)
		company.florins += loot
		plundered = true
		company.infamy = clampi(company.infamy + 2, 0, 100)
	log_line("%s falls to your company.%s" % [GameData.provinces()[siege.town].name, (" The sack brings %d florins." % loot) if loot > 0 else ""])
	_mark_objective(true)
	season_result = {"side": contract.employer, "against": contract.enemy, "won": true, "town": siege.town, "captured": true}


# ================================================================ aftermath: prisoners and ransom

func prisoner_value(soldiers: int) -> int:
	# Ransom for a captured enemy band: 30-60% of its hire cost (about 4 florins a man).
	return int(soldiers * 5.0 * rng.randf_range(0.3, 0.6))


func own_ransom_cost() -> int:
	return int(aftermath.get("own_captured", 0) * 3.5)


## choice: "ransom", "recruit" or "release"
func resolve_prisoners(choice: String) -> String:
	var n: int = aftermath.get("prisoners", 0)
	if n <= 0:
		return ""
	var msg = ""
	match choice:
		"ransom":
			var v = prisoner_value(n)
			company.florins += v
			stats.income += v
			msg = "Prisoners ransomed for %d florins." % v
		"recruit":
			var left = n
			for b in company.bands:
				var room: int = b.max - b.soldiers
				var take = mini(room, left / 2)
				b.soldiers += take
				left -= take
			msg = "%d prisoners take your pay." % (n - left)
		"release":
			if not contract.is_empty():
				world.add_trust(contract.enemy, 5)
			company.infamy = maxi(0, company.infamy - 2)
			msg = "You release the prisoners without ransom. Word of your chivalry spreads."
	aftermath.prisoners = 0
	log_line(msg)
	return msg


func ransom_own_men(pay: bool) -> String:
	var n: int = aftermath.get("own_captured", 0)
	if n <= 0:
		return ""
	var msg = ""
	if pay and company.florins >= own_ransom_cost():
		company.florins -= own_ransom_cost()
		var left = n
		for b in company.bands:
			var room: int = b.max - b.soldiers
			var take = mini(room, left)
			b.soldiers += take
			left -= take
		msg = "You pay %d florins and your men come home." % own_ransom_cost()
	else:
		msg = "Your captured men are left to their fate."
		for c in company.captains:
			c.loyalty -= 2
			company.clamp_loyalty(c)
	aftermath.own_captured = 0
	log_line(msg)
	return msg


func finish_aftermath() -> void:
	if phase != "aftermath":
		return
	if aftermath.get("prisoners", 0) > 0:
		resolve_prisoners("ransom")
	if aftermath.get("own_captured", 0) > 0:
		ransom_own_men(false)
	aftermath = {}
	_next_engagement()


# ================================================================ 5. payday

func _do_payday() -> void:
	report = []
	if contract.is_empty():
		report.append("No employer, no pay.")
		return
	var e = GameData.employer(contract.employer)
	contract.seasons_served += 1
	var due = int(round(float(contract.pay * contract.term - contract.advance) / contract.term))
	var desp: float = world.desperation(contract.employer)
	var cash_share: float = e.get("cash_share", 1.0)
	var roll = rng.randf()
	var default_p: float = e.default_chance + 0.1 * desp
	var late_p: float = e.late_chance + 0.2 * desp
	if contract.get("failures", 0) > contract.get("success", 0):
		late_p += 0.1
	if roll < default_p:
		stats.defaults += 1
		report.append("%s defaults: no pay this season. You may walk away from the contract without shame." % e.name)
		contract.defaulted = true
	elif roll < default_p + late_p:
		stats.late_payments += 1
		contract.owed += due
		report.append("%s pays late: %d florins owed." % [e.name, due])
	else:
		var cash = int(due * cash_share) + contract.owed
		company.florins += cash
		stats.income += cash
		contract.paid += cash
		if contract.owed > 0:
			report.append("Back pay of %d florins arrives." % contract.owed)
		contract.owed = 0
		report.append("%s pays %d florins." % [e.name, cash])
		if cash_share < 1.0:
			report.append("The rest is paid in titles and land.")
			if rng.chance(0.5):
				company.pennants += 1
				report.append("A papal title: +1 pennant.")
	if contract.get("success", 0) > 0:
		world.add_trust(contract.employer, 5)
	if contract.get("failures", 0) > 0:
		world.add_trust(contract.employer, -5)
	if contract.captain_general:
		captain_general_held = true
	if contract.seasons_served >= contract.term or contract.get("defaulted", false):
		_close_contract()


func _close_contract() -> void:
	var e = GameData.employer(contract.employer)
	if contract.get("defaulted", false) and contract.seasons_served < contract.term:
		report.append("The contract with %s lapses." % e.name)
	else:
		# Any owed pay is settled at the end, if the employer can.
		if contract.owed > 0:
			if rng.chance(0.7):
				company.florins += contract.owed
				stats.income += contract.owed
				report.append("%s settles %d florins of back pay." % [e.name, contract.owed])
			else:
				report.append("%s never pays the last %d florins." % [e.name, contract.owed])
		company.pennants += 2
		stats.contracts_completed += 1
		world.add_trust(contract.employer, 10)
		report.append("Contract completed: +2 pennants.")
		if contract.captain_general:
			company.pennants += 1
			report.append("You end the contract as captain-general: +1 pennant.")
	contract = {}


func finish_payday() -> void:
	if phase != "payday":
		return
	_start_winter()


func walk_away() -> void:
	## Break a contract whose employer defaulted, without infamy.
	if not contract.is_empty() and contract.get("defaulted", false):
		contract = {}


# ================================================================ 6. winter quarters

func _start_winter() -> void:
	phase = "winter"
	report = []
	stats.seasons += 1
	# Upkeep is the constant pressure.
	var up: int = company.upkeep()
	if company.florins >= up:
		company.florins -= up
		company.arrears = 0
		report.append("Paid %d florins of upkeep." % up)
	else:
		report.append("You cannot pay the men: %d florins owed, %d in the chest." % [up, company.florins])
		company.florins = 0
		company.arrears += 1
	if company.florins < up:
		stats.low_bank_seasons += 1
	# Victory or plunder resets arrears anger.
	var anger: int = company.arrears
	if anger > 0 and (won_this_year or plundered):
		report.append("Victory and plunder keep the men in good spirits despite the arrears.")
		anger = 0
	# Desertion roll per band: 15% per unpaid season, minus the band captain's Loyalty / 10 points.
	if anger > 0:
		for b in company.bands.duplicate():
			var cap: Dictionary = company.captain_of_band(b)
			if not cap.is_empty() and company.trait_value(cap, "no_desertion", false):
				continue
			var p = desertion_chance(anger, cap.get("loyalty", 0) if not cap.is_empty() else 0)
			if rng.chance(p):
				stats.desertions += 1
				report.append("The %s band deserts." % GameData.troop(b.type).name)
				company.remove_band(b.id)
	# Captains.
	for c in company.captains.duplicate():
		if c.get("is_commander", false):
			c.wounded = 0
			continue
		c.wounded = 0
		var drift: int = int(company.trait_value(c, "loyalty_drift", 0))
		if company.arrears > 0:
			drift -= int(10 * company.arrears * float(company.trait_value(c, "unpaid_loyalty_mult", 1.0)))
		c.loyalty += drift
		company.clamp_loyalty(c)
		var retire: float = company.trait_value(c, "retire_chance", 0.0)
		if retire > 0.0 and rng.chance(retire):
			report.append("%s retires to his vineyard." % c.name)
			company.remove_captain(c.id)
			continue
		# A captain with Loyalty under 25 can defect and take his bands with him.
		if c.loyalty < 25 and rng.chance(0.35):
			stats.defections += 1
			var taken: Array = company.bands_of_captain(c.id)
			report.append("%s defects and takes %d band%s with him." % [c.name, taken.size(), "" if taken.size() == 1 else "s"])
			for b in taken:
				company.remove_band(b.id)
			company.remove_captain(c.id)
	event_queue = ["winter"] if rng.chance(0.7) else []
	_next_event()
	# Lordship opportunities.
	_check_lordship()
	_check_losing()


static func desertion_chance(arrears: int, loyalty: int) -> float:
	return clampf(0.15 * arrears - loyalty / 10.0 / 100.0, 0.0, 0.95)


func winter_pending() -> String:
	if not current_event.is_empty():
		return "event"
	if not lordship_offer.is_empty():
		return "lordship"
	return "ready"


func _check_lordship() -> void:
	if company.pennants < LORDSHIP_PENNANTS:
		return
	var candidates = []
	# Filippo Maria Visconti dies in 1447 and Milan falls into chaos; Sforza seized it.
	if year >= 1447 and world.is_alive("milan"):
		candidates.append({"town": "milano", "text": "The last Visconti duke is dead and Milan's republic is failing."})
	for f in ["mantua", "ferrara", "rimini", "siena"]:
		if world.is_alive(f) and world.desperation(f) > 0.6 and rng.chance(0.25):
			var ts: Array = world.towns_of(f)
			if not ts.is_empty():
				candidates.append({"town": ts[0], "text": "The lord of %s has fallen and the city is leaderless." % GameData.provinces()[ts[0]].name})
	if candidates.is_empty() or not rng.chance(0.35):
		return
	lordship_offer = rng.pick(candidates)
	lordship_offer.cost = LORDSHIP_COST
	lordship_offer.min_soldiers = LORDSHIP_SOLDIERS


func can_seize_lordship() -> bool:
	return not lordship_offer.is_empty() and company.florins >= lordship_offer.cost and company.total_soldiers() >= lordship_offer.min_soldiers


func seize_lordship(accept: bool) -> void:
	if lordship_offer.is_empty():
		return
	if accept and can_seize_lordship():
		company.florins -= lordship_offer.cost
		log_line("You march into %s and are acclaimed its lord. A dynasty begins." % GameData.provinces()[lordship_offer.town].name)
		lordship_offer = {}
		_end("lordship", true)
		return
	lordship_offer = {}


func can_retire() -> bool:
	return company.florins >= RETIRE_FLORINS


func retire() -> void:
	if can_retire():
		log_line("You hang up your sword and buy an estate. The company passes to others.")
		_end("retirement", true)


func _commander_dies(how: String) -> void:
	var cmd: Dictionary = company.commander()
	log_line("Your commander is %s." % how)
	# A successor captain takes over with a loyalty penalty.
	var best = {}
	for c in non_commander_captains():
		if c.loyalty >= 50 and (best.is_empty() or c.loyalty > best.loyalty):
			best = c
	company.remove_captain(cmd.id)
	if best.is_empty():
		_end("died", false)
		return
	best.is_commander = true
	best.loyalty = 100
	for c in non_commander_captains():
		c.loyalty -= 15
		company.clamp_loyalty(c)
	log_line("%s takes command of the company." % best.name)


## The company falls under 3 bands and can't pay to keep or rebuild it.
func _check_losing() -> void:
	if ended:
		return
	var missing: int = maxi(0, 3 - company.bands.size())
	if company.bands.size() < 3 and company.florins < company.upkeep() + missing * REBUILD_COST:
		log_line("The company has dwindled to nothing and cannot pay its last men.")
		_end("ruin", false)


func finish_winter() -> void:
	if phase != "winter" or ended:
		return
	if winter_pending() != "ready":
		if not current_event.is_empty():
			return
		seize_lordship(false)
	_check_losing()
	if ended:
		return
	world.season_tick(rng, year, season_result)
	for n in world.news:
		log_line(n)
	year += 1
	if year > END_YEAR:
		_peace_of_lodi()
		return
	_start_year()


func _peace_of_lodi() -> void:
	year = END_YEAR
	log_line("The Peace of Lodi is signed. Italy's great wars are over.")
	if captain_general_held and company.pennants >= CAPTAIN_GENERAL_PENNANTS:
		log_line("You end the war as a captain-general of a great power.")
		_end("captain_general", true)
	elif company.florins >= RETIRE_FLORINS:
		log_line("You retire with enough wealth for an estate and a legacy.")
		_end("retirement", true)
	else:
		log_line("The company is disbanded. Nobody writes your name down.")
		_end("forgotten", false)


func _end(kind: String, p_won: bool) -> void:
	ended = true
	ending = kind
	won = p_won
	phase = "ended"


const ENDING_TEXT := {
	"lordship": "The Lordship: you seized a city and founded a dynasty.",
	"captain_general": "The Captain-General: you ended the war as a great power's supreme commander.",
	"retirement": "The Retirement: you left with enough wealth for an estate and a legacy.",
	"executed": "Executed for treachery.",
	"died": "Your commander died, and no captain was loyal enough to take his place.",
	"ruin": "Ruin: the company fell apart for want of pay.",
	"forgotten": "Forgotten: you survived the wars, but history does not remember you.",
}


# ================================================================ save / load

func to_dict() -> Dictionary:
	return {
		"version": SAVE_VERSION, "seed": seed_value, "rng_state": str(rng.get_state()),
		"year": year, "phase": phase, "location": location,
		"company": company.to_dict(), "world": world.to_dict(),
		"offers": offers.duplicate(true), "contract": contract.duplicate(true),
		"weather": weather, "plundered": plundered, "won_this_year": won_this_year,
		"lost_this_year": lost_this_year, "season_result": season_result.duplicate(true),
		"seen_events": seen_events.duplicate(), "events_this_year": events_this_year.duplicate(),
		"captain_general_held": captain_general_held, "stats": stats.duplicate(),
		"ended": ended, "ending": ending, "won": won, "log": log.slice(maxi(0, log.size() - 200)),
	}


## Saves are only taken at the start of a phase that needs no pending decisions
## (board, prepare, winter-done); pending letters are re-rolled deterministically.
func save_to(path: String) -> Error:
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(to_dict(), "\t"))
	return OK


func load_from(path: String) -> Error:
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return FileAccess.get_open_error()
	var d = JSON.parse_string(f.get_as_text())
	if typeof(d) != TYPE_DICTIONARY or int(d.get("version", 0)) != SAVE_VERSION:
		return ERR_FILE_UNRECOGNIZED
	from_dict(d)
	return OK


func from_dict(d: Dictionary) -> void:
	seed_value = int(d.seed)
	rng = Rng.new(seed_value)
	rng.set_state(int(d.rng_state))
	year = int(d.year)
	phase = d.phase
	location = d.location
	company = Company.new()
	company.from_dict(d.company)
	world = World.new()
	world.from_dict(d.world)
	offers = _fix_contracts(d.offers)
	var cs = _fix_contracts([d.contract]) if not d.contract.is_empty() else [{}]
	contract = cs[0]
	weather = d.weather
	plundered = d.plundered
	won_this_year = d.won_this_year
	lost_this_year = d.lost_this_year
	season_result = d.season_result
	seen_events = d.seen_events
	events_this_year = d.events_this_year
	captain_general_held = d.captain_general_held
	stats = {}
	for k in d.stats:
		stats[k] = int(d.stats[k])
	ended = d.ended
	ending = d.ending
	won = d.won
	log = d.log
	current_event = {}
	betrayal_offer = {}
	lordship_offer = {}
	# Mid-phase saves resume at the start of that phase.
	if phase in ["march", "battle", "siege", "aftermath"]:
		phase = "prepare"
	elif phase in ["payday", "winter"]:
		phase = "winter"
		event_queue = []


static func _fix_contracts(arr: Array) -> Array:
	var out = []
	for o in arr:
		var c: Dictionary = o.duplicate(true)
		for k in ["pay", "term", "advance", "seasons_served", "owed", "paid", "year_signed", "success", "failures"]:
			if c.has(k):
				c[k] = int(c[k])
		out.append(c)
	return out
