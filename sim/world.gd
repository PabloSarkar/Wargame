## The living campaign. The world moves without the player: each season the powers
## declare wars, march armies and besiege towns by simple rules (strength, money, grudges),
## so borders shift across a run. Towns produce grain, iron and horses; raids and sieges
## cut supply, which raises recruit and equipment prices in that region.
extends RefCounted

const GameData := preload("res://sim/game_data.gd")

const GOODS := ["grain", "iron", "horses"]
const BASE_PRICE := 10
const STOCK_TARGET := 12
const INCOME_PER_TOWN := 700
const WAR_COST := 900

var factions: Dictionary = {}  # id -> {treasury, trust, start_towns, alive}
var towns: Dictionary = {}  # id -> {owner, under_siege, stock{}, price{}}
var wars: Array = []  # of [a, b] with a < b
var grudges: Dictionary = {}  # "a|b" -> int
var news: Array = []  # this season's headlines


func setup(rng) -> void:
	factions.clear()
	towns.clear()
	wars.clear()
	grudges.clear()
	for id in GameData.employers():
		var e := GameData.employer(id)
		factions[id] = {"treasury": int(e.treasury), "trust": 30, "start_towns": 0, "alive": true, "bonus": 0.0}
	for pid in GameData.provinces():
		var p: Dictionary = GameData.provinces()[pid]
		var stock := {}
		var price := {}
		for g in GOODS:
			stock[g] = STOCK_TARGET
			price[g] = BASE_PRICE
		towns[pid] = {"owner": p.owner, "under_siege": false, "stock": stock, "price": price}
		factions[p.owner].start_towns += 1
	# Italy in 1440: Milan against the Venetian-Florentine league, Naples in its succession war.
	declare_war("milan", "venice")
	declare_war("milan", "florence")
	declare_war("mantua", "venice")
	declare_war("naples", "papal")
	declare_war("rimini", "papal")
	for w in wars:
		grudges[_key(w[0], w[1])] = 3


static func _key(a: String, b: String) -> String:
	return a + "|" + b if a < b else b + "|" + a


func declare_war(a: String, b: String) -> void:
	if a == b or at_war(a, b):
		return
	wars.append([a, b] if a < b else [b, a])


func make_peace(a: String, b: String) -> void:
	for i in wars.size():
		if wars[i] == ([a, b] if a < b else [b, a]):
			wars.remove_at(i)
			return


func at_war(a: String, b: String) -> bool:
	return wars.has([a, b] if a < b else [b, a])


func enemies_of(f: String) -> Array:
	var out := []
	for w in wars:
		if w[0] == f:
			out.append(w[1])
		elif w[1] == f:
			out.append(w[0])
	return out


func towns_of(f: String) -> Array:
	var out := []
	for pid in towns:
		if towns[pid].owner == f:
			out.append(pid)
	out.sort()
	return out


## Towns of `victim` that border territory held by `attacker`.
func border_towns(attacker: String, victim: String) -> Array:
	var out := []
	for pid in towns_of(victim):
		for adj in GameData.provinces()[pid].adj:
			if towns[adj].owner == attacker:
				out.append(pid)
				break
	if out.is_empty():
		out = towns_of(victim)
	return out


func strength(f: String) -> float:
	var e := GameData.employer(f)
	var fd: Dictionary = factions[f]
	var start: int = maxi(fd.start_towns, 1)
	var owned := towns_of(f).size()
	var s: float = e.base_strength * sqrt(float(owned) / start) + fd.treasury / 2000.0 + fd.bonus
	return maxf(s, 1.0)


## How badly the employer's war is going, 0..1.
func desperation(f: String) -> float:
	var foes := enemies_of(f)
	if foes.is_empty():
		return 0.0
	var fd: Dictionary = factions[f]
	var lost := 1.0 - float(towns_of(f).size()) / maxf(fd.start_towns, 1)
	var own := strength(f)
	var foe_str := 0.0
	for o in foes:
		foe_str += strength(o)
	var d := 0.15 + lost + (foe_str - own) / (foe_str + own) * 0.6
	if fd.treasury < 4000:
		d += 0.15
	return clampf(d, 0.0, 1.0)


func trust(f: String) -> int:
	return factions[f].trust


func add_trust(f: String, amount: int) -> void:
	if factions.has(f):
		factions[f].trust = clampi(factions[f].trust + amount, -100, 100)


func is_alive(f: String) -> bool:
	return factions[f].alive


## One season of the world. `player` describes what the player's company did:
## {"side": faction, "against": faction, "won": bool, "town": province or "", "captured": bool}
func season_tick(rng, year: int, player: Dictionary) -> void:
	news.clear()
	for f in factions:
		factions[f].bonus = 0.0
	if not player.is_empty() and player.get("side", "") != "":
		var side: String = player.side
		if factions.has(side):
			factions[side].bonus = 25.0 if player.get("won", false) else -5.0
	# Player-captured town changes hands first.
	if player.get("captured", false) and player.get("town", "") != "":
		_transfer(player.town, player.side, "falls to %s, taken by your company" % GameData.employer(player.side).name)
	# Wars: each war, the stronger side may take a border town.
	for w in wars.duplicate():
		var a: String = w[0]
		var b: String = w[1]
		if not at_war(a, b):
			continue
		var sa := strength(a)
		var sb := strength(b)
		var attacker := a
		var victim := b
		if rng.randf() * (sa + sb) >= sa:
			attacker = b
			victim = a
		var ratio := strength(attacker) / maxf(strength(victim), 1.0)
		var p_take := clampf(0.12 * ratio, 0.04, 0.4)
		var targets := border_towns(attacker, victim)
		if targets.is_empty():
			continue
		var target: String = rng.pick(targets)
		if rng.chance(p_take):
			_transfer(target, attacker, "falls to %s" % GameData.employer(attacker).name)
		elif rng.chance(0.4):
			towns[target].under_siege = true
			news.append("%s besieges %s" % [GameData.employer(attacker).name, GameData.provinces()[target].name])
	# Money.
	for f in factions:
		var fd: Dictionary = factions[f]
		fd.treasury += towns_of(f).size() * INCOME_PER_TOWN
		fd.treasury -= enemies_of(f).size() * WAR_COST
		fd.treasury = maxi(fd.treasury, 0)
		if towns_of(f).is_empty() and fd.alive:
			fd.alive = false
			news.append("%s is no more" % GameData.employer(f).name)
			for foe in enemies_of(f):
				make_peace(f, foe)
	# Peace and new wars.
	for w in wars.duplicate():
		var poor: bool = factions[w[0]].treasury < 3000 or factions[w[1]].treasury < 3000
		if rng.chance(0.08 + (0.15 if poor else 0.0)):
			make_peace(w[0], w[1])
			news.append("Peace between %s and %s" % [GameData.employer(w[0]).name, GameData.employer(w[1]).name])
	var alive := []
	for f in factions:
		if factions[f].alive:
			alive.append(f)
	alive.sort()
	var tries := 0
	while (wars.size() < 3 or rng.chance(0.15)) and tries < 10:
		tries += 1
		var a: String = rng.pick(alive)
		var neighbours := _neighbours(a)
		if neighbours.is_empty():
			continue
		var b: String = rng.pick(neighbours)
		if at_war(a, b) or not factions[b].alive:
			continue
		declare_war(a, b)
		grudges[_key(a, b)] = grudges.get(_key(a, b), 0) + 1
		news.append("%s declares war on %s" % [GameData.employer(a).name, GameData.employer(b).name])
		break
	_update_goods(rng)


func _neighbours(f: String) -> Array:
	var out := []
	for pid in towns_of(f):
		for adj in GameData.provinces()[pid].adj:
			var o: String = towns[adj].owner
			if o != f and not o in out:
				out.append(o)
	out.sort()
	return out


func _transfer(pid: String, new_owner: String, text: String) -> void:
	var t: Dictionary = towns[pid]
	if t.owner == new_owner:
		return
	var old: String = t.owner
	t.owner = new_owner
	t.under_siege = false
	for g in GOODS:
		t.stock[g] = int(t.stock[g] / 2)
	grudges[_key(old, new_owner)] = grudges.get(_key(old, new_owner), 0) + 2
	news.append("%s %s" % [GameData.provinces()[pid].name, text])


func _update_goods(rng) -> void:
	for pid in towns:
		var t: Dictionary = towns[pid]
		var prod: Dictionary = GameData.provinces()[pid].goods
		for g in GOODS:
			var made: int = prod.get(g, 0)
			if t.under_siege:
				made = int(made / 3)
			t.stock[g] = clampi(t.stock[g] + made - 5 + rng.randi_range(-1, 1), 0, 40)
			var scarcity := float(STOCK_TARGET - t.stock[g]) / STOCK_TARGET
			t.price[g] = clampi(int(round(BASE_PRICE * (1.0 + scarcity * 0.8))), 5, 30)
		if t.under_siege and rng.chance(0.5):
			t.under_siege = false


## Recruit and equipment price multiplier in a region, from local horse and iron prices.
func recruit_mult(pid: String, cavalry: bool) -> float:
	if not towns.has(pid):
		return 1.0
	var p: Dictionary = towns[pid].price
	var key := "horses" if cavalry else "iron"
	return clampf(0.7 + 0.3 * p[key] / BASE_PRICE, 0.8, 1.5)


func to_dict() -> Dictionary:
	return {"factions": factions.duplicate(true), "towns": towns.duplicate(true), "wars": wars.duplicate(true), "grudges": grudges.duplicate()}


func from_dict(d: Dictionary) -> void:
	factions = {}
	for f in d.factions:
		var fd: Dictionary = d.factions[f]
		factions[f] = {"treasury": int(fd.treasury), "trust": int(fd.trust), "start_towns": int(fd.start_towns), "alive": fd.alive, "bonus": float(fd.bonus)}
	towns = {}
	for pid in d.towns:
		var t: Dictionary = d.towns[pid]
		var stock := {}
		var price := {}
		for g in GOODS:
			stock[g] = int(t.stock[g])
			price[g] = int(t.price[g])
		towns[pid] = {"owner": t.owner, "under_siege": t.under_siege, "stock": stock, "price": price}
	wars = []
	for w in d.wars:
		wars.append([str(w[0]), str(w[1])])
	grudges = {}
	for k in d.grudges:
		grudges[k] = int(d.grudges[k])
