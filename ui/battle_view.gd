## Top-down 2D battle view. Only reads sim state and sends player commands.
## Left click: select your formation. Right click: move there, or attack the enemy under the cursor.
## During deployment, left click on the field places the selected formation in your zone.
extends Control

signal selection_changed(id: int)

const BattleSim := preload("res://sim/battle_sim.gd")

const SIDE_COLORS := [Color("#2f5d8a"), Color("#9b2f2f")]
const TERRAIN_COLORS := {
	"hill": Color(0.55, 0.47, 0.3, 0.35), "woods": Color(0.2, 0.4, 0.2, 0.45),
	"river": Color(0.25, 0.45, 0.7, 0.6), "ford": Color(0.4, 0.6, 0.8, 0.35),
	"walls": Color(0.35, 0.3, 0.28, 0.9),
}

var sim
var selected: int = -1
var deploying: bool = true
var paused: bool = true
var speed: float = 1.0
var _acc: float = 0.0


func setup(p_sim) -> void:
	sim = p_sim
	selected = -1
	deploying = true
	paused = true
	queue_redraw()


func _process(delta: float) -> void:
	if sim == null or deploying or paused or sim.finished:
		return
	_acc += delta * speed
	var steps := 0
	while _acc >= BattleSim.TICK and steps < 200:
		sim.step()
		_acc -= BattleSim.TICK
		steps += 1
	queue_redraw()


func _scale() -> float:
	return minf(size.x / BattleSim.FIELD.x, size.y / BattleSim.FIELD.y)


func _offset() -> Vector2:
	var s := _scale()
	return (size - BattleSim.FIELD * s) / 2.0


func to_screen(p: Vector2) -> Vector2:
	return _offset() + p * _scale()


func to_field(p: Vector2) -> Vector2:
	return (p - _offset()) / _scale()


func _draw() -> void:
	if sim == null:
		return
	var s := _scale()
	var o := _offset()
	draw_rect(Rect2(o, BattleSim.FIELD * s), Color("#cfc09a"))
	for tr in sim.terrain:
		var r: Rect2 = tr.rect
		draw_rect(Rect2(o + r.position * s, r.size * s), TERRAIN_COLORS.get(tr.type, Color.GRAY))
	if deploying:
		draw_rect(Rect2(o, Vector2(BattleSim.DEPLOY_WIDTH, BattleSim.FIELD.y) * s), Color(0.2, 0.4, 0.7, 0.12))
	var font := get_theme_default_font()
	for f in sim.formations:
		if f.state == "fled" or f.state == "destroyed":
			continue
		_draw_formation(f, s, font)
	if sim.weather == "rain":
		draw_string(font, o + Vector2(8, 18), "Rain: crossbows and handguns suffer", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#2a4d6e"))
	draw_string(font, o + Vector2(8, BattleSim.FIELD.y * s - 8), "%s   t=%ds%s" % [sim.terrain_name, int(sim.time), "   PAUSED" if paused and not deploying else ""], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#3b2f22"))


func _draw_formation(f, s: float, font: Font) -> void:
	var w := (8.0 + sqrt(maxf(f.soldiers, 1.0)) * 5.0) * s
	var d := (6.0 + sqrt(maxf(f.soldiers, 1.0)) * 2.2) * s
	var col: Color = SIDE_COLORS[f.side]
	if f.state == "routing":
		col = col.lerp(Color.WHITE, 0.55)
	var center := to_screen(f.pos)
	var ang: float = f.facing.angle()
	draw_set_transform(center, ang, Vector2.ONE)
	var rect := Rect2(Vector2(-d / 2, -w / 2), Vector2(d, w))
	draw_rect(rect, col)
	if f.t.get("cavalry", false):
		draw_rect(Rect2(Vector2(-d / 2, -w / 2), Vector2(d, w)), col.darkened(0.4), false, 2.0)
	# Front edge marker.
	draw_line(Vector2(d / 2, -w / 2), Vector2(d / 2, w / 2), Color("#1d1710"), 2.0)
	if f.order == "brace" and f.state == "ok":
		for i in 5:
			var y := -w / 2 + w * (i + 0.5) / 5.0
			draw_line(Vector2(d / 2, y), Vector2(d / 2 + 6 * s * 2, y), Color("#1d1710"), 1.0)
	if f.id == selected:
		draw_rect(rect.grow(3), Color("#f2d24b"), false, 2.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var shown: bool = f.side == 0 or f.revealed
	var label: String = f.label if shown else "?"
	if shown:
		label += " %d" % int(f.soldiers)
	draw_string(font, center + Vector2(-30, -w / 2 - 10), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#1d1710"))
	if shown:
		var bw := 36.0
		var bp := center + Vector2(-bw / 2, w / 2 + 4)
		draw_rect(Rect2(bp, Vector2(bw, 4)), Color(0, 0, 0, 0.3))
		draw_rect(Rect2(bp, Vector2(bw * clampf(f.morale / maxf(f.max_morale, 1.0), 0, 1), 4)), Color("#d9a62b"))
		draw_rect(Rect2(bp + Vector2(0, 5), Vector2(bw * clampf(f.stamina / maxf(f.max_stamina, 1.0), 0, 1), 3)), Color("#5c8a4a"))
	if f.side == 0 and f.last_fire_target >= 0 and f.state == "ok":
		var t = sim.get_formation(f.last_fire_target)
		if t != null:
			draw_line(center, to_screen(t.pos), Color(0.2, 0.2, 0.2, 0.25), 1.0)


func formation_at(p: Vector2):
	var fp := to_field(p)
	var best = null
	var bd := INF
	for f in sim.formations:
		if f.state == "fled" or f.state == "destroyed":
			continue
		var dd: float = f.pos.distance_to(fp)
		if dd < f.radius() + 8.0 and dd < bd:
			bd = dd
			best = f
	return best


func _gui_input(event: InputEvent) -> void:
	if sim == null or sim.finished:
		return
	if event is InputEventMouseButton and event.pressed:
		var f = formation_at(event.position)
		if event.button_index == MOUSE_BUTTON_LEFT:
			if f != null and f.side == 0:
				selected = f.id
				selection_changed.emit(selected)
			elif deploying and selected >= 0:
				var sf = sim.get_formation(selected)
				sf.pos = sim.clamp_deploy(0, to_field(event.position))
				sf.reserve = false
			queue_redraw()
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT and selected >= 0 and not deploying:
			var me = sim.get_formation(selected)
			if me == null:
				return
			if f != null and f.side == 1:
				sim.set_order(selected, "charge" if me.t.get("cavalry", false) else "advance", f.id)
			else:
				sim.move_to(selected, to_field(event.position))
			me.ai = false
			queue_redraw()
			accept_event()
