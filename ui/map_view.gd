## Grey-box parchment map of northern and central Italy: city seals coloured by owner,
## the company's banner, and the current contract's target.
extends Control

const GameData := preload("res://sim/game_data.gd")

var campaign


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#e6d7b0"))
	if campaign == null:
		return
	var provs := GameData.provinces()
	var s := minf(size.x / 1000.0, size.y / 960.0)
	var off := Vector2((size.x - 1000.0 * s) / 2.0, 6)
	var font := get_theme_default_font()
	for pid in provs:
		var p: Dictionary = provs[pid]
		var a := off + Vector2(p.x, p.y) * s
		for adj in p.adj:
			var q: Dictionary = provs[adj]
			draw_line(a, off + Vector2(q.x, q.y) * s, Color(0.4, 0.33, 0.22, 0.35), 1.0)
	var target := ""
	if not campaign.contract.is_empty():
		target = campaign.contract.target
	for pid in provs:
		var p: Dictionary = provs[pid]
		var t: Dictionary = campaign.world.towns[pid]
		var a := off + Vector2(p.x, p.y) * s
		var col := Color(GameData.employer(t.owner).color)
		var r := 9.0 * s + 4.0
		draw_circle(a, r, col)
		draw_arc(a, r, 0, TAU, 20, Color("#3b2f22"), 1.5)
		if t.under_siege:
			draw_arc(a, r + 3, 0, TAU, 20, Color("#b0301e"), 2.0)
		if pid == target:
			draw_arc(a, r + 6, 0, TAU, 24, Color("#f2d24b"), 2.5)
		draw_string(font, a + Vector2(r + 2, 4), p.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color("#3b2f22"))
	# Company banner.
	var lp: Dictionary = provs.get(campaign.location, {})
	if not lp.is_empty():
		var a := off + Vector2(lp.x, lp.y) * s
		draw_line(a, a + Vector2(0, -26), Color("#1d1710"), 2.0)
		draw_colored_polygon(PackedVector2Array([a + Vector2(0, -26), a + Vector2(16, -21), a + Vector2(0, -16)]), Color("#1d1710"))
