## Reads event files: conditions, choices and effects. Events arrive as letters.
##
## Condition keys: phase, min_year, max_year, min_infamy, max_infamy, min_pennants,
##   min_florins, has_troop, employer, under_contract, has_supervisor, min_captains,
##   max_captains, max_bands, min_arrears, has_trait.
## Choice "requires" keys: florins, troop, no_clause, under_contract.
## Effect keys: florins, pennants, infamy, trust, trust_faction, loyalty_all,
##   loyalty_captain, loyalty_other, soldiers_all_pct, soldiers_troop_pct, add_band,
##   remove_band, add_captain, wound_captain, wound_commander, xp_troop, weather,
##   unlock, skirmish, plunder.
extends RefCounted

const GameData := preload("res://sim/game_data.gd")


static func eligible(ev: Dictionary, c) -> bool:
	var cond: Dictionary = ev.get("conditions", {})
	var company = c.company
	if ev.get("once", false) and ev.id in c.seen_events:
		return false
	if cond.has("min_year") and c.year < cond.min_year:
		return false
	if cond.has("max_year") and c.year > cond.max_year:
		return false
	if cond.has("min_infamy") and company.infamy < cond.min_infamy:
		return false
	if cond.has("max_infamy") and company.infamy > cond.max_infamy:
		return false
	if cond.has("min_pennants") and company.pennants < cond.min_pennants:
		return false
	if cond.has("min_florins") and company.florins < cond.min_florins:
		return false
	if cond.has("has_troop") and not company.has_troop(cond.has_troop):
		return false
	if cond.has("has_trait") and not company.has_trait(cond.has_trait):
		return false
	if cond.has("under_contract") and bool(cond.under_contract) != (not c.contract.is_empty()):
		return false
	if cond.has("employer") and (c.contract.is_empty() or c.contract.employer != cond.employer):
		return false
	if cond.has("has_supervisor") and (c.contract.is_empty() or not "supervisor" in c.contract.clauses):
		return false
	var non_cmd = c.non_commander_captains().size()
	if cond.has("min_captains") and non_cmd < cond.min_captains:
		return false
	if cond.has("max_captains") and non_cmd > cond.max_captains:
		return false
	if cond.has("max_bands") and company.bands.size() > cond.max_bands:
		return false
	if cond.has("min_arrears") and company.arrears < cond.min_arrears:
		return false
	return true


static func pick_event(rng, c, phase: String) -> Dictionary:
	var pool = []
	var weights = []
	for ev in GameData.events():
		if ev.get("phase", "march") != phase:
			continue
		if ev.id in c.events_this_year:
			continue
		if eligible(ev, c):
			pool.append(ev)
			weights.append(ev.get("weight", 1))
	var i: int = rng.weighted_index(weights)
	if i < 0:
		return {}
	return pool[i]


## Binds placeholders to concrete things (which captain, which town) when the letter arrives.
static func instantiate(rng, ev: Dictionary, c) -> Dictionary:
	var inst = {"id": ev.id, "def": ev, "captain_id": -1, "other_id": -1}
	var caps: Array = c.non_commander_captains()
	if not caps.is_empty():
		var cap: Dictionary = rng.pick(caps)
		inst.captain_id = cap.id
		var others = []
		for o in caps:
			if o.id != cap.id:
				others.append(o)
		if not others.is_empty():
			inst.other_id = rng.pick(others).id
	inst.title = _fill(ev.title, inst, c)
	inst.text = _fill(ev.text, inst, c)
	inst.choices = []
	for ch in ev.choices:
		inst.choices.append({"text": _fill(ch.text, inst, c), "available": choice_available(ch, c)})
	return inst


static func _fill(s: String, inst: Dictionary, c) -> String:
	var cap: Dictionary = c.company.captain(inst.captain_id)
	s = s.replace("{captain}", cap.get("name", "your captain"))
	var emp = ""
	var enemy = ""
	if not c.contract.is_empty():
		emp = GameData.employer(c.contract.employer).name
		enemy = GameData.employer(c.contract.enemy).name
	s = s.replace("{employer}", emp if emp != "" else "your employer")
	s = s.replace("{enemy}", enemy if enemy != "" else "the enemy")
	var town = c.location
	if not c.contract.is_empty():
		town = c.contract.target
	s = s.replace("{town}", GameData.provinces().get(town, {}).get("name", "the town"))
	return s


static func choice_available(ch: Dictionary, c) -> bool:
	var req: Dictionary = ch.get("requires", {})
	if req.has("florins") and c.company.florins < req.florins:
		return false
	if req.has("troop") and not c.company.has_troop(req.troop):
		return false
	if req.has("no_clause") and not c.contract.is_empty() and req.no_clause in c.contract.clauses:
		return false
	if req.has("under_contract") and c.contract.is_empty():
		return false
	return true


## Applies a choice; returns the outcome text.
static func resolve(rng, inst: Dictionary, choice_index: int, c) -> String:
	var ch: Dictionary = inst.def.choices[choice_index]
	var outs: Array = ch.outcomes
	var weights = []
	for o in outs:
		weights.append(o.get("weight", 1))
	var out: Dictionary = outs[rng.weighted_index(weights)]
	apply_effects(rng, out.get("effects", {}), inst, c)
	return _fill(out.get("text", ""), inst, c)


static func apply_effects(rng, fx: Dictionary, inst: Dictionary, c) -> void:
	var company = c.company
	for k in fx:
		var v = fx[k]
		match k:
			"florins":
				company.florins += int(v)
			"pennants":
				company.pennants = maxi(0, company.pennants + int(v))
			"infamy":
				company.infamy = clampi(company.infamy + int(v), 0, 100)
			"trust":
				if not c.contract.is_empty():
					c.world.add_trust(c.contract.employer, int(v))
			"trust_faction":
				c.world.add_trust(v.faction, int(v.amount))
			"loyalty_all":
				for cap in company.captains:
					cap.loyalty += int(v)
					company.clamp_loyalty(cap)
			"loyalty_captain":
				var cap: Dictionary = company.captain(inst.captain_id)
				if not cap.is_empty():
					cap.loyalty += int(v)
					company.clamp_loyalty(cap)
			"loyalty_other":
				var cap2: Dictionary = company.captain(inst.other_id)
				if not cap2.is_empty():
					cap2.loyalty += int(v)
					company.clamp_loyalty(cap2)
			"soldiers_all_pct":
				for b in company.bands:
					b.soldiers = maxi(1, int(round(b.soldiers * (1.0 + float(v)))))
			"soldiers_troop_pct":
				for b in company.bands:
					if b.type == v.type:
						b.soldiers = maxi(1, int(round(b.soldiers * (1.0 + float(v.pct)))))
			"add_band":
				if company.bands.size() < company.MAX_BANDS:
					var nb: Dictionary = company.add_band(str(v))
					nb.soldiers = int(nb.max * 0.8)
			"remove_band":
				if not company.bands.is_empty():
					var rb: Dictionary = rng.pick(company.bands)
					c.log_line("The %s band walks away." % GameData.troop(rb.type).name)
					company.remove_band(rb.id)
			"add_captain":
				if company.captains.size() < company.MAX_CAPTAINS + 1:
					var nc: Dictionary = company.make_captain(rng, "", [str(v)] if str(v) != "" else [])
					company.add_captain(nc)
					c.log_line("%s joins the company." % nc.name)
			"wound_captain":
				var wc: Dictionary = company.captain(inst.captain_id)
				if not wc.is_empty():
					wc.wounded = 1
			"wound_commander":
				var cm: Dictionary = company.commander()
				if not cm.is_empty():
					cm.wounded = 1
			"xp_troop":
				for b in company.bands:
					if b.type == str(v):
						company.add_xp(b, 1)
			"weather":
				c.weather = str(v)
			"unlock":
				if not str(v) in company.unlocked:
					company.unlocked.append(str(v))
			"skirmish":
				c.pending_skirmish = str(v)
			"plunder":
				c.plundered = true
				for cap in company.captains:
					cap.loyalty += 3 if "greedy" in cap.traits else 0
					company.clamp_loyalty(cap)
