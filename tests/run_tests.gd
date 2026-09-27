## Headless test runner.
##   godot --headless --path . --script res://tests/run_tests.gd
extends SceneTree

const GameData := preload("res://sim/game_data.gd")
const Rng := preload("res://sim/rng.gd")
const Company := preload("res://sim/company.gd")
const Contracts := preload("res://sim/contracts.gd")
const BattleSim := preload("res://sim/battle_sim.gd")
const SiegeSim := preload("res://sim/siege_sim.gd")
const Campaign := preload("res://sim/campaign.gd")
const AutoPlayer := preload("res://sim/auto_player.gd")

const KNOWN_EFFECTS := ["florins", "pennants", "infamy", "trust", "trust_faction", "loyalty_all",
	"loyalty_captain", "loyalty_other", "soldiers_all_pct", "soldiers_troop_pct", "add_band",
	"remove_band", "add_captain", "wound_captain", "wound_commander", "xp_troop", "weather",
	"unlock", "skirmish", "plunder"]
const KNOWN_CONDITIONS := ["min_year", "max_year", "min_infamy", "max_infamy", "min_pennants",
	"min_florins", "has_troop", "employer", "under_contract", "has_supervisor", "min_captains",
	"max_captains", "max_bands", "min_arrears", "has_trait"]

var failures := 0
var passes := 0


func _init() -> void:
	var t0 := Time.get_ticks_msec()
	test_data_integrity()
	test_starting_state()
	test_offer_formula()
	test_pennant_tiers()
	test_desertion_formula()
	test_facing()
	test_matchup()
	test_even_frontal_fight()
	test_flank_attack_wins()
	test_brace_stops_charge()
	test_rout_and_capture()
	test_siege()
	test_betrayal()
	test_determinism()
	test_save_load()
	test_full_campaigns()
	print("\n%d passed, %d failed (%.1f s)" % [passes, failures, (Time.get_ticks_msec() - t0) / 1000.0])
	quit(1 if failures > 0 else 0)


func check(cond: bool, name: String) -> void:
	if cond:
		passes += 1
	else:
		failures += 1
		print("FAIL: " + name)


func test_data_integrity() -> void:
	var troops := GameData.troops()
	check(troops.size() == 7, "7 troop types")
	for t in troops:
		for key in ["hire", "upkeep", "soldiers", "attack", "defence", "armour", "speed", "stamina", "morale"]:
			check(troops[t].has(key), "troop %s has %s" % [t, key])
	var provs := GameData.provinces()
	for pid in provs:
		check(GameData.employers().has(provs[pid].owner), "province %s owner exists" % pid)
		for a in provs[pid].adj:
			check(provs.has(a), "province %s adjacency %s exists" % [pid, a])
			check(pid in provs[a].adj, "adjacency %s<->%s is symmetric" % [pid, a])
	for ev in GameData.events():
		for k in ev.get("conditions", {}):
			check(k in KNOWN_CONDITIONS, "event %s condition %s is known" % [ev.id, k])
		for ch in ev.choices:
			for o in ch.outcomes:
				for k in o.get("effects", {}):
					check(k in KNOWN_EFFECTS, "event %s effect %s is known" % [ev.id, k])
	for tr in GameData.traits():
		check(GameData.traits()[tr].has("name"), "trait %s has a name" % tr)


func test_starting_state() -> void:
	var c := Campaign.new()
	c.new_campaign(1)
	# 2,000 florins and 6 bands (2 lances, 2 crossbows, 2 pikemen), about 940 florins of upkeep.
	check(c.company.bands.size() == 6, "start with 6 bands")
	check(c.company.upkeep() == 940, "starting upkeep is 940 (got %d)" % c.company.upkeep())
	check(c.company.florins == 2000, "start with 2000 florins")
	check(c.phase == "board", "campaign opens on the contract board")
	check(c.offers.size() >= 1 and c.offers.size() <= 4, "board has 1-4 offers (got %d)" % c.offers.size())
	for o in c.offers:
		check(not GameData.employer(o.employer).major, "0 pennants: minor lords only (%s)" % o.employer)
		check(o.advance == int(round(o.pay * o.term * 0.25 / 10.0)) * 10, "advance is 25% of contract value")


func test_offer_formula() -> void:
	# Offer = Upkeep x (1.1 + 0.4 x Desperation) x (1 + 0.03 x Pennants) x Reliability
	check(Contracts.offer_pay(1000, 0.0, 0, 1.0) == 1100, "offer: base")
	check(Contracts.offer_pay(1000, 1.0, 0, 1.0) == 1500, "offer: full desperation")
	check(Contracts.offer_pay(1000, 0.5, 10, 0.8) == int(round(1000 * 1.3 * 1.3 * 0.8)), "offer: combined")


func test_pennant_tiers() -> void:
	check(Contracts.pennant_tier(0) == 0 and Contracts.pennant_tier(4) == 0, "tier 0-4")
	check(Contracts.pennant_tier(5) == 1 and Contracts.pennant_tier(9) == 1, "tier 5-9")
	check(Contracts.pennant_tier(10) == 2 and Contracts.pennant_tier(19) == 2, "tier 10-19")
	check(Contracts.pennant_tier(20) == 3, "tier 20+")


func test_desertion_formula() -> void:
	# 15% per unpaid season, minus the band captain's Loyalty / 10 percentage points.
	check(is_equal_approx(Campaign.desertion_chance(1, 0), 0.15), "desertion 1 season, no captain")
	check(is_equal_approx(Campaign.desertion_chance(2, 50), 0.25), "desertion 2 seasons, loyalty 50")
	check(Campaign.desertion_chance(1, 100) >= 0.0, "desertion never negative")


func _duel(type_a: String, type_b: String, soldiers := 60):
	var b := BattleSim.new(Rng.new(1))
	var a = b.add_formation(0, type_a, soldiers)
	var e = b.add_formation(1, type_b, soldiers)
	a.ai = false
	e.ai = false
	a.pos = Vector2(400, 300)
	e.pos = Vector2(600, 300)
	return [b, a, e]


func test_facing() -> void:
	var r = _duel("pikes", "pikes")
	var b = r[0]
	var a = r[1]
	var e = r[2]
	e.facing = Vector2.LEFT  # facing the attacker
	check(b.facing_mult(a, e) == 1.0, "facing: front is 1")
	e.facing = Vector2.UP
	check(b.facing_mult(a, e) == 1.5, "facing: flank is 1.5")
	e.facing = Vector2.RIGHT
	check(b.facing_mult(a, e) == 2.0, "facing: rear is 2")


func test_matchup() -> void:
	var r = _duel("pikes", "lances")
	var b = r[0]
	check(b.matchup(r[1], r[2]) > 1.0, "pikes are strong vs lances")
	check(b.matchup(r[2], r[1]) < 1.0, "lances are weak vs pikes")


func test_even_frontal_fight() -> void:
	# k is tuned so an even frontal fight lasts about 60 seconds.
	var r = _duel("pikes", "pikes")
	var b = r[0]
	b.set_order(r[1].id, "advance")
	b.set_order(r[2].id, "advance")
	b.run_to_end()
	check(b.time > 40.0 and b.time < 90.0, "even frontal pike fight lasts ~60 s (got %.0f)" % b.time)


func test_flank_attack_wins() -> void:
	# Two equal swords bands fight; a third band hitting the flank decides it.
	var b := BattleSim.new(Rng.new(3))
	var a = b.add_formation(0, "swords", 70)
	var e = b.add_formation(1, "swords", 70)
	var f = b.add_formation(0, "swords", 40)
	for x in [a, e, f]:
		x.ai = false
	a.pos = Vector2(470, 300)
	e.pos = Vector2(530, 300)
	f.pos = Vector2(530, 150)
	b.set_order(a.id, "advance", e.id)
	b.set_order(e.id, "advance", a.id)
	for i in 20:
		b.step()
	b.set_order(f.id, "advance", e.id)
	b.run_to_end()
	check(b.winner == 0, "flank attack wins the fight")
	check(e.routed_once or e.state == "destroyed", "flanked band breaks")


func test_brace_stops_charge() -> void:
	var r = _duel("lances", "pikes", 40)
	var b = r[0]
	var lances = r[1]
	var pikes = r[2]
	pikes.soldiers = 80
	pikes.order = "brace"
	b.set_order(lances.id, "charge", pikes.id)
	b.run_to_end()
	check(b.winner == 1, "braced pikes beat a frontal lance charge")


func test_rout_and_capture() -> void:
	var b := BattleSim.new(Rng.new(5))
	var weak = b.add_formation(0, "crossbows", 30)
	var strong = b.add_formation(1, "lances", 40)
	var lh = b.add_formation(1, "light_horse", 50)
	weak.ai = false
	weak.pos = Vector2(300, 300)
	strong.pos = Vector2(420, 300)
	lh.pos = Vector2(420, 400)
	b.run_to_end()
	var res: Dictionary = b.result()
	check(b.winner == 1, "lances and stradiots beat a small crossbow band")
	check(weak.routed_once or weak.state == "destroyed", "beaten band routs")
	check(res.player_captured > 0, "routed men are captured, not only killed")


func test_siege() -> void:
	var rng := Rng.new(9)
	var s := SiegeSim.new()
	s.setup(rng, "brescia", 70, true, 50, 1.0, false)
	var w0 := s.walls
	s.act(rng, "bombard")
	check(s.walls < w0, "bombards knock down walls")
	var s2 := SiegeSim.new()
	s2.setup(rng, "brescia", 70, false, 50, 1.0, false)
	check(not s2.can("bombard", 10000), "no bombarding without a siege train")
	var guard := 0
	while not s2.done and guard < 30:
		s2.act(rng, "starve")
		guard += 1
	check(s2.done and s2.result in ["taken", "failed"], "starving ends the siege one way or another")


func test_betrayal() -> void:
	# Play until a betrayal offer appears, then accept it.
	for sd in range(1, 60):
		var c := Campaign.new()
		c.new_campaign(sd)
		var ap := AutoPlayer.new("honest", Rng.new(sd))
		var guard := 0
		while not c.ended and guard < 3000:
			guard += 1
			if c.phase == "march" and c.march_pending() == "betrayal":
				if "supervisor" in c.contract.clauses:
					break
				var old: String = c.contract.employer
				var infamy0: int = c.company.infamy
				var trust0: int = c.world.trust(old)
				var offer: Dictionary = c.betrayal_offer.duplicate()
				var old_pay: int = c.contract.pay
				c.accept_betrayal()
				check(c.company.infamy >= infamy0 + 15, "betrayal raises infamy by 15+")
				check(c.world.trust(old) <= trust0 - 50, "betrayal turns the old employer hostile")
				check(c.contract.employer == offer.employer, "company now serves the rival")
				check(offer.pay >= old_pay * 1.45 and offer.pay <= old_pay * 2.05, "rival offers 150-200% of current pay")
				check(c.contract.pay == offer.pay, "new contract pays the rival's offer")
				return
			ap.step(c)
	check(false, "found a betrayal offer to test")


func _play(seed_value: int, policy: String):
	var c := Campaign.new()
	c.new_campaign(seed_value)
	var ap := AutoPlayer.new(policy, Rng.new(seed_value * 31))
	ap.play(c)
	return c


func test_determinism() -> void:
	var a = _play(42, "mixed")
	var b = _play(42, "mixed")
	check(a.ending == b.ending and a.year == b.year and a.company.florins == b.company.florins, "same seed reproduces the run exactly")
	check(a.log == b.log, "same seed reproduces the log")


func test_save_load() -> void:
	var c := Campaign.new()
	c.new_campaign(7)
	var ap := AutoPlayer.new("honest", Rng.new(7))
	# Advance into year 2.
	var guard := 0
	while c.year < 1442 and not c.ended and guard < 2000:
		ap.step(c)
		guard += 1
	var path := "user://test_save.json"
	check(c.save_to(path) == OK, "save writes")
	var d := Campaign.new()
	check(d.load_from(path) == OK, "save loads")
	check(d.year == c.year and d.company.florins == c.company.florins and d.company.bands.size() == c.company.bands.size(), "save round-trips company")
	check(d.world.wars.size() == c.world.wars.size(), "save round-trips wars")
	# A loaded game must be playable to the end.
	var ap2 := AutoPlayer.new("honest", Rng.new(8))
	ap2.play(d)
	check(d.ended, "loaded campaign plays to an ending")


func test_full_campaigns() -> void:
	for policy in ["honest", "mixed", "betrayer"]:
		for sd in [11, 12]:
			var c = _play(sd, policy)
			check(c.ended and c.ending != "", "%s seed %d reaches an ending (%s, %d)" % [policy, sd, c.ending, c.year])
			check(c.year >= 1440 and c.year <= 1454, "campaign stays within 1440-1454")
