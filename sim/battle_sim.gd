## Real-time formation battle, fixed 20 ticks per second, separate from rendering.
## Formations move and fight as blocks. Runs headless for auto-resolve and balance testing.
##
## Contact losses per second (design doc):
##   Losses/s = k * Attack_att * Matchup * Facing / (Defence_def + Armour_def)
## Facing is 1 from the front, 1.5 on the flank, 2 from the rear.
extends RefCounted

const GameData := preload("res://sim/game_data.gd")

const TICK := 0.05  # 20 ticks per second
const FIELD := Vector2(1000, 600)
const DEPLOY_WIDTH := 230.0
const MAX_TIME := 300.0
const K_MELEE := 0.63  # tuned so an even frontal fight lasts about 60 seconds
const K_RANGED := 0.32
const MORALE_PER_LOSS := 170.0  # morale lost per 100% of max soldiers lost
const MELEE_MORALE_DRAIN := 0.35
const FLANK_MORALE_DRAIN := 1.6
const REAR_MORALE_DRAIN := 3.2
const RALLY_AFTER := 5.0
const PURSUIT_RANGE := 70.0
const CHARGE_IMPACT_TIME := 3.0
const ORDERS := ["advance", "hold", "brace", "charge", "withdraw"]


class Formation:
	var id: int
	var side: int  # 0 = player, 1 = enemy
	var type: String
	var t: Dictionary
	var band_id: int = -1
	var label: String = ""
	var soldiers: float
	var start_soldiers: float
	var max_soldiers: float
	var pos: Vector2
	var facing: Vector2
	var order: String = "hold"
	var fire: bool = true
	var target_id: int = -1
	var move_target = null  # Vector2 or null
	var state: String = "ok"  # ok, routing, fled, destroyed
	var morale: float
	var max_morale: float
	var stamina: float
	var max_stamina: float
	var rank: int = 1
	var captain: Dictionary = {}
	var ability_used: bool = false
	var impact_timer: float = 0.0
	var impact_mult: float = 1.0
	var volley_timer: float = 0.0
	var steady_timer: float = 0.0
	var unpursued: float = 0.0
	var pursued: bool = false
	var reserve: bool = false
	var ai: bool = true
	var engaged: Array = []  # ids of enemy formations in melee contact
	var primary_foe: int = -1
	var killed: float = 0.0
	var wounded: float = 0.0  # fall in fighting; captured if the side loses
	var captured: float = 0.0  # taken while routing
	var routed_once: bool = false
	var commander: bool = false
	var commander_exposed: bool = false
	var revealed: bool = false
	var last_fire_target: int = -1
	var ai_timer: float = 0.0
	var rear_hit: bool = false

	func radius() -> float:
		return 12.0 + sqrt(maxf(soldiers, 1.0)) * 2.2

	func is_cav() -> bool:
		return t.get("cavalry", false)

	func is_ranged() -> bool:
		return t.get("range", 0) > 0

	func active() -> bool:
		return state == "ok"

	func on_field() -> bool:
		return state == "ok" or state == "routing"


var formations: Array = []
var _by_id: Dictionary = {}
var time: float = 0.0
var finished: bool = false
var winner: int = -1  # 0 player, 1 enemy, 2 draw
var weather: String = "clear"
var terrain: Array = []  # of {type, rect: Rect2}
var terrain_name: String = "open plain"
var walls_bonus: float = 0.0  # enemy defenders behind walls (siege storm)
var player_ai: bool = false
var scouted: bool = false
var log: Array = []
var rng
var _next_id := 1
var _tick := 0


func _init(p_rng) -> void:
	rng = p_rng


# ---------------------------------------------------------------- setup

func add_formation(side: int, type: String, soldiers: int, rank: int = 1, captain: Dictionary = {}, band_id: int = -1) -> Formation:
	var f := Formation.new()
	f.id = _next_id
	_next_id += 1
	f.side = side
	f.type = type
	f.t = GameData.troop(type)
	f.band_id = band_id
	f.label = f.t.get("name", type)
	f.soldiers = soldiers
	f.start_soldiers = soldiers
	f.max_soldiers = f.t.get("soldiers", soldiers)
	f.rank = rank
	f.captain = captain
	var morale_bonus := 0.0
	if not captain.is_empty():
		morale_bonus += captain.get("command", 50) * 0.15
		morale_bonus += _trait(captain, "morale_bonus", 0)
		f.commander = captain.get("is_commander", false)
	f.max_morale = f.t.get("morale", 60) * (1.0 + 0.1 * (rank - 1)) + morale_bonus
	f.morale = f.max_morale
	f.max_stamina = f.t.get("stamina", 80)
	f.stamina = f.max_stamina
	f.facing = Vector2.RIGHT if side == 0 else Vector2.LEFT
	f.ai = side == 1 or player_ai
	f.revealed = side == 0
	formations.append(f)
	_by_id[f.id] = f
	return f


func setup_terrain(kind: String) -> void:
	terrain.clear()
	terrain_name = kind
	match kind:
		"hills":
			terrain.append({"type": "hill", "rect": Rect2(380 + rng.randf_range(-60, 60), 80, 160, 170)})
			terrain.append({"type": "hill", "rect": Rect2(420 + rng.randf_range(-60, 60), 360, 150, 160)})
		"woods":
			terrain.append({"type": "woods", "rect": Rect2(420 + rng.randf_range(-80, 80), rng.randf_range(20, 380), 150, 200)})
		"river":
			terrain.append({"type": "river", "rect": Rect2(480, 0, 40, 240)})
			terrain.append({"type": "ford", "rect": Rect2(480, 240, 40, 120)})
			terrain.append({"type": "river", "rect": Rect2(480, 360, 40, 240)})
		"breach":
			terrain.append({"type": "walls", "rect": Rect2(720, 0, 30, 250)})
			terrain.append({"type": "walls", "rect": Rect2(720, 350, 30, 250)})
		_:
			terrain_name = "open plain"


func terrain_at(p: Vector2) -> String:
	for tr in terrain:
		if tr.rect.has_point(p):
			return tr.type
	return ""


## Default deployment: ranged in front, infantry centre, cavalry on the wings, last one in reserve.
func auto_deploy(side: int) -> void:
	var mine := side_formations(side)
	var x_front := 170.0 if side == 0 else FIELD.x - 170.0
	var x_back := 80.0 if side == 0 else FIELD.x - 80.0
	var ranged := []
	var inf := []
	var cav := []
	for f: Formation in mine:
		if f.is_ranged():
			ranged.append(f)
		elif f.is_cav():
			cav.append(f)
		else:
			inf.append(f)
	var line: Array = []
	# Keep one infantry band in reserve if there are enough.
	var reserve_f = null
	if inf.size() >= 3:
		reserve_f = inf.pop_back()
	var centre: Array = inf + ranged
	var wings: Array = cav
	var ys := _spread(centre.size(), 220, 380)
	for i in centre.size():
		centre[i].pos = Vector2(x_front, ys[i])
	for i in wings.size():
		var y := 90.0 + 70.0 * (i / 2) if i % 2 == 0 else FIELD.y - 90.0 - 70.0 * (i / 2)
		wings[i].pos = Vector2(x_front - (30 if side == 0 else -30), y)
	for f in ranged:
		f.pos.x += 40 if side == 0 else -40
	if reserve_f != null:
		reserve_f.pos = Vector2(x_back, FIELD.y / 2)
		reserve_f.reserve = true
	for f: Formation in mine:
		f.pos = clamp_deploy(side, f.pos)


func _spread(n: int, a: float, b: float) -> Array:
	var out := []
	if n <= 0:
		return out
	if n == 1:
		return [(a + b) / 2.0]
	var lo := a - 40.0 * (n - 2)
	var hi := b + 40.0 * (n - 2)
	lo = maxf(lo, 60.0)
	hi = minf(hi, FIELD.y - 60.0)
	for i in n:
		out.append(lerpf(lo, hi, float(i) / float(n - 1)))
	return out


func clamp_deploy(side: int, p: Vector2) -> Vector2:
	var x0 := 30.0 if side == 0 else FIELD.x - DEPLOY_WIDTH
	var x1 := DEPLOY_WIDTH if side == 0 else FIELD.x - 30.0
	return Vector2(clampf(p.x, x0, x1), clampf(p.y, 30.0, FIELD.y - 30.0))


func side_formations(side: int) -> Array:
	var out := []
	for f: Formation in formations:
		if f.side == side:
			out.append(f)
	return out


func get_formation(id: int) -> Formation:
	return _by_id.get(id, null)


# ---------------------------------------------------------------- orders

func set_order(id: int, order: String, target_id: int = -1) -> void:
	var f := get_formation(id)
	if f == null or not f.active():
		return
	if order == "charge" and f.order != "charge" and f.engaged.is_empty():
		f.impact_mult = 2.0 if f.is_cav() else 1.4
	f.order = order
	f.target_id = target_id
	f.move_target = null
	f.reserve = false
	if order == "withdraw":
		_disengage(f)


func move_to(id: int, p: Vector2) -> void:
	var f := get_formation(id)
	if f == null or not f.active():
		return
	f.order = "move"
	f.move_target = Vector2(clampf(p.x, 10, FIELD.x - 10), clampf(p.y, 10, FIELD.y - 10))
	f.reserve = false
	_disengage(f)


func toggle_fire(id: int) -> void:
	var f := get_formation(id)
	if f != null:
		f.fire = not f.fire


func use_ability(id: int) -> bool:
	var f := get_formation(id)
	if f == null or f.ability_used or f.captain.is_empty() or f.state == "fled" or f.state == "destroyed":
		return false
	var ab: String = f.captain.get("ability", "rally")
	match ab:
		"rally":
			f.morale = minf(f.max_morale, f.morale + 40.0)
			if f.state == "routing":
				f.state = "ok"
				f.order = "hold"
				f.morale = maxf(f.morale, 40.0)
		"countercharge":
			if not f.active():
				return false
			f.order = "charge"
			f.impact_mult = 2.2
			f.stamina = minf(f.max_stamina, f.stamina + 30.0)
		"steady_volley":
			if not f.active():
				return false
			if f.is_ranged():
				f.volley_timer = 10.0
			else:
				f.steady_timer = 10.0
		_:
			return false
	f.ability_used = true
	_log("%s: %s uses %s" % [f.label, f.captain.get("name", "captain"), ab.replace("_", " ")])
	return true


# ---------------------------------------------------------------- simulation

func run_to_end() -> void:
	while not finished:
		step()


func step() -> void:
	if finished:
		return
	time += TICK
	_tick += 1
	for f: Formation in formations:
		if f.ai and f.active():
			f.ai_timer -= TICK
			if f.ai_timer <= 0.0:
				f.ai_timer = 1.0
				_ai(f)
	if _tick % 10 == 0:
		_update_reveal()
	for f: Formation in formations:
		_move(f)
	_separate()
	_contacts()
	_combat()
	_morale_and_state()
	_check_end()


func _update_reveal() -> void:
	for e: Formation in formations:
		if e.side != 1 or e.revealed:
			continue
		if scouted:
			e.revealed = true
			continue
		for f: Formation in formations:
			if f.side == 0 and f.on_field() and f.pos.distance_to(e.pos) < 220.0:
				e.revealed = true
				break


func nearest_enemy(f: Formation, only_active := true, pred := Callable()) -> Formation:
	var best: Formation = null
	var bd := INF
	for e: Formation in formations:
		if e.side == f.side:
			continue
		if only_active and not e.active():
			continue
		if not only_active and not e.on_field():
			continue
		if pred.is_valid() and not pred.call(e):
			continue
		var d := f.pos.distance_to(e.pos)
		if d < bd:
			bd = d
			best = e
	return best


func _speed(f: Formation) -> float:
	var s: float = f.t.get("speed", 15)
	s *= 0.6 + 0.4 * f.stamina / f.max_stamina
	if not f.captain.is_empty():
		s *= _trait(f.captain, "speed_mult", 1.0)
		if f.is_cav():
			s *= _trait(f.captain, "cavalry_speed_mult", 1.0)
	match terrain_at(f.pos):
		"woods":
			s *= 0.6
		"river":
			s *= 0.35
		"hill":
			s *= 0.85
		"walls":
			s *= 0.3
	if f.order == "charge":
		s *= 1.5
	if f.state == "routing":
		s *= 1.1
	return s


func _move(f: Formation) -> void:
	if f.state == "fled" or f.state == "destroyed":
		return
	var dest = null
	if f.state == "routing":
		dest = Vector2(-50.0 if f.side == 0 else FIELD.x + 50.0, f.pos.y)
	elif not f.engaged.is_empty():
		var foe := get_formation(f.primary_foe)
		if foe != null:
			f.facing = (foe.pos - f.pos).normalized()
		_drain(f, 1.0 if f.order != "charge" else 1.5)
		return
	else:
		match f.order:
			"advance", "charge":
				var tgt := get_formation(f.target_id)
				if tgt == null or not tgt.active():
					tgt = nearest_enemy(f)
				if tgt != null:
					dest = tgt.pos
			"move":
				dest = f.move_target
				if dest != null and f.pos.distance_to(dest) < 4.0:
					f.order = "hold"
					f.move_target = null
					dest = null
			"withdraw":
				dest = Vector2(40.0 if f.side == 0 else FIELD.x - 40.0, f.pos.y)
				if absf(f.pos.x - dest.x) < 4.0:
					f.order = "hold"
					dest = null
			_:
				pass
	if dest == null:
		# Stationary: face the nearest threat and rest.
		if _tick % 5 == 0 and f.state == "ok" and f.order != "brace":
			var e := nearest_enemy(f)
			if e != null:
				f.facing = f.facing.lerp((e.pos - f.pos).normalized(), 0.4).normalized()
		f.stamina = minf(f.max_stamina, f.stamina + 1.5 * TICK)
		return
	var dir: Vector2 = (dest - f.pos)
	var dist := dir.length()
	if dist < 0.01:
		return
	dir /= dist
	var step_len := minf(_speed(f) * TICK, dist)
	f.pos += dir * step_len
	f.pos.y = clampf(f.pos.y, 5.0, FIELD.y - 5.0)
	if f.state != "routing":
		f.facing = dir
		_drain(f, 2.0 if f.order == "charge" else 0.4)
	else:
		f.facing = dir
		if f.pos.x < 0.0 or f.pos.x > FIELD.x:
			f.state = "fled"
			f.engaged.clear()


func _drain(f: Formation, per_sec: float) -> void:
	f.stamina = maxf(0.0, f.stamina - per_sec * TICK)


func _separate() -> void:
	for i in formations.size():
		var a: Formation = formations[i]
		if not a.on_field():
			continue
		for j in range(i + 1, formations.size()):
			var b: Formation = formations[j]
			if not b.on_field() or a.side != b.side:
				continue
			var d: float = a.pos.distance_to(b.pos)
			var min_d: float = (a.radius() + b.radius()) * 0.9
			if d < min_d and d > 0.001:
				var push := (a.pos - b.pos).normalized() * (min_d - d) * 0.5
				if a.engaged.is_empty():
					a.pos += push
				if b.engaged.is_empty():
					b.pos -= push


func _contacts() -> void:
	for f: Formation in formations:
		if not f.active():
			continue
		for e: Formation in formations:
			if e.side == f.side or not e.on_field():
				continue
			if e.id in f.engaged:
				continue
			if e.state == "routing":
				continue
			var rr := f.radius() + e.radius()
			if f.pos.distance_squared_to(e.pos) <= rr * rr:
				_engage(f, e)


func _engage(a: Formation, b: Formation) -> void:
	# a made contact with b.
	if not b.id in a.engaged:
		a.engaged.append(b.id)
	if not a.id in b.engaged:
		b.engaged.append(a.id)
	if a.primary_foe < 0:
		a.primary_foe = b.id
	var b_first := b.primary_foe < 0
	if b_first:
		b.primary_foe = a.id
	# Charge impact, unless the defender is braced and struck from the front.
	var fac := facing_mult(a, b)
	if b_first and fac <= 1.0:
		b.facing = (a.pos - b.pos).normalized()
		fac = 1.0
	if a.order == "charge" and a.impact_mult > 1.0:
		if b.order == "brace" and fac <= 1.0:
			a.impact_timer = 0.0
			b.impact_timer = CHARGE_IMPACT_TIME
			b.impact_mult = 1.6
			_log("%s charge breaks on braced %s" % [a.label, b.label])
		else:
			a.impact_timer = CHARGE_IMPACT_TIME
	if fac >= 2.0:
		b.morale -= 12.0
		b.rear_hit = true
		_log("%s hit %s in the rear" % [a.label, b.label])
	elif fac > 1.0:
		b.morale -= 6.0
	# Once in contact a charge becomes a melee.
	if a.order == "charge":
		a.order = "advance"


func _disengage(f: Formation) -> void:
	for oid in f.engaged:
		var o := get_formation(oid)
		if o != null:
			o.engaged.erase(f.id)
			if o.primary_foe == f.id:
				o.primary_foe = o.engaged[0] if not o.engaged.is_empty() else -1
	f.engaged.clear()
	f.primary_foe = -1


func facing_mult(att: Formation, def: Formation) -> float:
	var dir := (att.pos - def.pos).normalized()
	var dot := dir.dot(def.facing)
	if dot >= 0.5:
		return 1.0
	if dot <= -0.5:
		return 2.0
	return 1.5


func matchup(att: Formation, def: Formation) -> float:
	var m := 1.0
	var def_key := "routing" if def.state == "routing" else def.type
	var bonus: bool = def_key in att.t.get("strong_vs", []) or att.type in def.t.get("weak_vs", [])
	var malus: bool = def.type in att.t.get("weak_vs", []) or att.type in def.t.get("strong_vs", [])
	if bonus and not malus:
		m = 1.5
	elif malus and not bonus:
		m = 0.67
	return m


func _attack_value(f: Formation) -> float:
	var a: float = f.t.get("attack", 5)
	a *= 1.0 + 0.1 * (f.rank - 1)
	if not f.captain.is_empty():
		a *= 1.0 + (f.captain.get("valor", 50) - 50) / 250.0
		a *= _trait(f.captain, "attack_mult", 1.0)
	a *= 0.5 + 0.5 * f.stamina / f.max_stamina
	if terrain_at(f.pos) == "hill":
		a *= 1.2
	if terrain_at(f.pos) == "woods" and f.is_cav():
		a *= 0.7
	return a


func _defence_value(def: Formation, ranged: bool, armour_piercing: bool) -> float:
	var d: float = def.t.get("defence", 5)
	var arm: float = def.t.get("armour", 0)
	if armour_piercing:
		arm *= 0.4
	if ranged:
		d += def.t.get("pavise", 0)
		if terrain_at(def.pos) == "woods":
			d *= 1.6
	if def.side == 1 and walls_bonus > 0.0:
		d += walls_bonus
	if def.order == "brace":
		d *= 1.15
	return maxf(d + arm, 1.0)


func _size_factor(f: Formation) -> float:
	return sqrt(maxf(f.soldiers, 0.0) / 50.0)


func _combat() -> void:
	var dmg := {}
	for f: Formation in formations:
		dmg[f.id] = 0.0
	for a: Formation in formations:
		if not a.active():
			continue
		a.impact_timer = maxf(0.0, a.impact_timer - TICK)
		a.volley_timer = maxf(0.0, a.volley_timer - TICK)
		a.steady_timer = maxf(0.0, a.steady_timer - TICK)
		if not a.engaged.is_empty():
			for bid in a.engaged:
				var b := get_formation(bid)
				if b == null or not b.on_field():
					continue
				var l := K_MELEE * _attack_value(a) * matchup(a, b) * facing_mult(a, b) / _defence_value(b, false, false)
				l *= _size_factor(a)
				if a.impact_timer > 0.0:
					l *= a.impact_mult
				dmg[b.id] += l * TICK
		elif a.is_ranged() and a.fire and a.order != "withdraw" and a.order != "move":
			var rng_range: float = a.t.get("range", 0) * (1.2 if terrain_at(a.pos) == "hill" else 1.0)
			var tgt := get_formation(a.target_id)
			if tgt == null or not tgt.on_field() or tgt.pos.distance_to(a.pos) > rng_range:
				tgt = nearest_enemy(a, false)
			if tgt != null and tgt.pos.distance_to(a.pos) <= rng_range:
				a.last_fire_target = tgt.id
				var ra: float = a.t.get("ranged_attack", 0) * (1.0 + 0.1 * (a.rank - 1))
				if weather == "rain":
					ra *= a.t.get("rain_penalty", 0.6)
				if a.volley_timer > 0.0:
					ra *= 2.0
				var l := K_RANGED * ra * matchup(a, tgt) * facing_mult(a, tgt) / _defence_value(tgt, true, a.t.get("armour_piercing", false))
				l *= _size_factor(a)
				dmg[tgt.id] += l * TICK
			else:
				a.last_fire_target = -1
	for f: Formation in formations:
		var l: float = minf(dmg[f.id], f.soldiers)
		if l <= 0.0:
			continue
		f.soldiers -= l
		if f.state == "routing":
			f.captured += l
		else:
			f.killed += l * 0.4
			f.wounded += l * 0.6
		var ml: float = l / f.max_soldiers * MORALE_PER_LOSS
		f.morale -= ml * _morale_mult(f)


func _morale_mult(f: Formation) -> float:
	var m := 1.5 - 0.5 * f.stamina / f.max_stamina
	if not f.captain.is_empty():
		m *= 1.0 - f.captain.get("command", 50) / 250.0
	if f.steady_timer > 0.0:
		m *= 0.5
	return m


func _morale_and_state() -> void:
	for f: Formation in formations:
		if f.state == "fled" or f.state == "destroyed":
			continue
		if f.soldiers < 3.0:
			f.captured += f.soldiers
			f.soldiers = 0.0
			f.state = "destroyed"
			_disengage(f)
			_log("%s destroyed" % f.label)
			continue
		if f.state == "ok":
			if not f.engaged.is_empty():
				var drain := MELEE_MORALE_DRAIN
				for oid in f.engaged:
					var o := get_formation(oid)
					if o == null:
						continue
					var fm := facing_mult(o, f)
					if fm >= 2.0:
						drain += REAR_MORALE_DRAIN
					elif fm > 1.0:
						drain += FLANK_MORALE_DRAIN
				f.morale -= drain * _morale_mult(f) * TICK
			elif f.last_fire_target < 0:
				f.morale = minf(f.max_morale, f.morale + 0.8 * TICK)
			if f.morale <= 0.0:
				_rout(f)
		elif f.state == "routing":
			# Pursued routers are captured; unpursued ones may rally.
			var chaser := nearest_enemy(f, true)
			f.pursued = chaser != null and chaser.pos.distance_to(f.pos) < PURSUIT_RANGE
			if f.pursued:
				f.unpursued = 0.0
				var rate := 2.5 * (2.0 if chaser.t.get("strong_vs", []).has("routing") else 1.0)
				if not f.captain.is_empty():
					rate *= _trait(f.captain, "rout_loss_mult", 1.0)
				var l := minf(rate * TICK, f.soldiers)
				f.soldiers -= l
				f.captured += l
				if f.commander:
					f.commander_exposed = true
			else:
				f.unpursued += TICK
				if f.unpursued >= RALLY_AFTER and f.soldiers >= f.start_soldiers * 0.3:
					f.state = "ok"
					f.morale = f.max_morale * 0.35
					f.order = "hold"
					f.unpursued = 0.0
					_log("%s rallies" % f.label)


func _rout(f: Formation) -> void:
	f.state = "routing"
	f.routed_once = true
	f.morale = 0.0
	f.unpursued = 0.0
	_disengage(f)
	_log("%s routs!" % f.label)
	for o: Formation in formations:
		if o.side == f.side and o.active() and o.pos.distance_to(f.pos) < 160.0:
			o.morale -= 8.0


func side_alive(side: int) -> bool:
	for f: Formation in formations:
		if f.side == side and f.active():
			return true
	return false


func side_strength(side: int) -> float:
	var s := 0.0
	for f: Formation in formations:
		if f.side == side and f.active():
			s += f.soldiers * (f.morale / maxf(f.max_morale, 1.0))
	return s


func _check_end() -> void:
	var a0 := side_alive(0)
	var a1 := side_alive(1)
	if a0 and a1 and time < MAX_TIME:
		return
	finished = true
	if not a0 and not a1:
		winner = 2
	elif not a1:
		winner = 0
	elif not a0:
		winner = 1
	else:
		var s0 := side_strength(0)
		var s1 := side_strength(1)
		if s0 > s1 * 1.3:
			winner = 0
		elif s1 > s0 * 1.3:
			winner = 1
		else:
			winner = 2
	_log("Battle over after %d s: %s" % [int(time), ["victory", "defeat", "draw"][winner]])


# ---------------------------------------------------------------- AI

func _ai(f: Formation) -> void:
	if not f.engaged.is_empty():
		if not f.ability_used and not f.captain.is_empty() and f.morale < f.max_morale * 0.35:
			use_ability(f.id)
		return
	var allies_routing := 0
	for o: Formation in formations:
		if o.side == f.side and o.routed_once:
			allies_routing += 1
	if f.reserve:
		if allies_routing > 0 or time > 45.0:
			f.reserve = false
		else:
			f.order = "hold"
			return
	if f.is_ranged():
		var e := nearest_enemy(f)
		if e == null:
			return
		var d := f.pos.distance_to(e.pos)
		var r: float = f.t.get("range", 100)
		if d > r * 0.95 and time > 8.0:
			f.order = "move"
			f.move_target = f.pos + (e.pos - f.pos).normalized() * (d - r * 0.85)
		elif d < 60.0 and e.is_cav():
			f.order = "withdraw"
		else:
			f.order = "hold"
			f.move_target = null
		if f.volley_timer <= 0.0 and not f.ability_used and not f.captain.is_empty() and f.captain.get("ability") == "steady_volley" and d <= r:
			use_ability(f.id)
		return
	if f.type == "light_horse":
		var router := nearest_enemy(f, false, func(e): return e.state == "routing")
		if router != null:
			f.order = "move"
			f.move_target = router.pos
			return
	if f.type == "pikes":
		var cav := nearest_enemy(f, true, func(e): return e.is_cav())
		if cav != null and cav.pos.distance_to(f.pos) < 150.0 and cav.order == "charge":
			f.order = "brace"
			return
	var tgt := _pick_target(f)
	if tgt == null:
		f.order = "hold"
		return
	var d := f.pos.distance_to(tgt.pos)
	if f.is_cav():
		# Cavalry prefers to hit engaged enemies from the flank or rear.
		if not tgt.engaged.is_empty() or d < 110.0:
			if f.order != "charge":
				set_order(f.id, "charge", tgt.id)
		else:
			var side_off := Vector2(-tgt.facing.y, tgt.facing.x) * 120.0
			if (tgt.pos + side_off).distance_to(f.pos) > (tgt.pos - side_off).distance_to(f.pos):
				side_off = -side_off
			f.order = "move"
			f.move_target = tgt.pos + side_off - tgt.facing * 40.0
			f.target_id = tgt.id
	else:
		if d < 90.0 and f.type == "swords" and f.order != "charge":
			set_order(f.id, "charge", tgt.id)
		elif f.order != "charge":
			f.order = "advance"
			f.target_id = tgt.id


func _pick_target(f: Formation) -> Formation:
	var best: Formation = null
	var best_score := -INF
	for e: Formation in formations:
		if e.side == f.side or not e.active():
			continue
		var d := f.pos.distance_to(e.pos)
		var score := -d / 100.0
		score += (matchup(f, e) - 1.0) * 4.0
		if not e.engaged.is_empty():
			score += 1.5 if f.is_cav() else 0.5
		if e.is_ranged() and f.is_cav():
			score += 1.0
		if score > best_score:
			best_score = score
			best = e
	return best


# ---------------------------------------------------------------- results

func result() -> Dictionary:
	var player_total := 0.0
	var enemy_total := 0.0
	var player_lost := 0.0
	var bands := {}
	var enemy_prisoners := 0.0
	var player_captured := 0.0
	var commander_exposed := false
	for f: Formation in formations:
		if f.side == 0:
			player_total += f.start_soldiers
		else:
			enemy_total += f.start_soldiers
	for f: Formation in formations:
		var lost_to_enemy: float = f.captured
		var dead: float = f.killed
		var returning: float = f.soldiers
		# Wounded return to the side that holds the field; otherwise they are taken.
		if (f.side == 0 and winner == 1) or (f.side == 1 and winner == 0):
			lost_to_enemy += f.wounded
		else:
			returning += f.wounded * 0.7
			dead += f.wounded * 0.3
		if f.side == 0:
			bands[f.band_id] = {"soldiers": int(round(returning)), "dead": int(round(dead)), "captured": int(round(lost_to_enemy)), "routed": f.routed_once, "fought": true}
			player_lost += f.start_soldiers - returning
			player_captured += lost_to_enemy
			if f.commander_exposed:
				commander_exposed = true
		else:
			enemy_prisoners += lost_to_enemy
	return {
		"winner": winner, "duration": time, "bands": bands,
		"enemy_prisoners": int(round(enemy_prisoners)),
		"player_captured": int(round(player_captured)),
		"famous": winner == 0 and enemy_total >= player_total * 2.0,
		"crushing": winner == 1 and player_lost >= player_total * 0.5,
		"commander_exposed": commander_exposed,
		"player_start": int(player_total), "enemy_start": int(enemy_total),
		"log": log.duplicate(),
	}


func _log(s: String) -> void:
	log.append("[%3ds] %s" % [int(time), s])


static func _trait(c: Dictionary, key: String, default_value):
	var traits := GameData.traits()
	for tid in c.get("traits", []):
		var td: Dictionary = traits.get(tid, {})
		if td.has(key):
			return td[key]
	return default_value
