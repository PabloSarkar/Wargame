## Grey-box UI for the prototype. Builds every screen in code from the campaign state.
## Presentation only: reads sim state and sends player commands.
extends Control

const GameData := preload("res://sim/game_data.gd")
const Campaign := preload("res://sim/campaign.gd")
const Contracts := preload("res://sim/contracts.gd")
const BattleView := preload("res://ui/battle_view.gd")
const MapView := preload("res://ui/map_view.gd")

const SAVE_PATH := "user://save.json"
const INK := Color("#3b2f22")
const PAPER := Color("#efe4c8")
const PAPER_DARK := Color("#e0d0a8")
const ACCENT := Color("#8a2f1d")

var c  # Campaign
var status_label: Label
var main_split: HBoxContainer
var content: VBoxContainer
var scroll: ScrollContainer
var map_view
var log_label: RichTextLabel
var battle_box: VBoxContainer
var battle_view
var battle_controls: HBoxContainer
var battle_info: Label
var battle
var message: String = ""


func _ready() -> void:
	theme = _make_theme()
	var bg = ColorRect.new()
	bg.color = PAPER_DARK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var margin = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)
	var root = VBoxContainer.new()
	margin.add_child(root)
	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 16)
	root.add_child(status_label)
	root.add_child(HSeparator.new())
	main_split = HBoxContainer.new()
	main_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(main_split)
	scroll = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_stretch_ratio = 1.6
	main_split.add_child(scroll)
	content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)
	var right = VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_split.add_child(right)
	map_view = MapView.new()
	map_view.custom_minimum_size = Vector2(380, 470)
	right.add_child(map_view)
	log_label = RichTextLabel.new()
	log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_label.scroll_following = true
	log_label.add_theme_color_override("default_color", INK)
	log_label.add_theme_font_size_override("normal_font_size", 12)
	right.add_child(log_label)
	battle_box = VBoxContainer.new()
	battle_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	battle_box.visible = false
	root.add_child(battle_box)
	battle_view = BattleView.new()
	battle_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	battle_view.mouse_filter = Control.MOUSE_FILTER_STOP
	battle_view.selection_changed.connect(func(_id): _refresh_battle_controls())
	battle_box.add_child(battle_view)
	battle_info = Label.new()
	battle_box.add_child(battle_info)
	battle_controls = HBoxContainer.new()
	battle_box.add_child(battle_controls)
	_show_title()


func _make_theme() -> Theme:
	var t = Theme.new()
	t.set_color("font_color", "Label", INK)
	t.set_color("font_color", "Button", INK)
	t.set_color("font_hover_color", "Button", ACCENT)
	t.set_color("font_disabled_color", "Button", Color(INK, 0.4))
	t.set_color("font_color", "CheckBox", INK)
	t.set_color("font_color", "LineEdit", INK)
	var sb = StyleBoxFlat.new()
	sb.bg_color = PAPER
	sb.border_color = Color("#9c8a62")
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(6)
	t.set_stylebox("normal", "Button", sb)
	var hover = sb.duplicate()
	hover.bg_color = Color("#f7eed8")
	t.set_stylebox("hover", "Button", hover)
	var pressed = sb.duplicate()
	pressed.bg_color = Color("#d8c59a")
	t.set_stylebox("pressed", "Button", pressed)
	var disabled = sb.duplicate()
	disabled.bg_color = Color("#e3d8bb")
	t.set_stylebox("disabled", "Button", disabled)
	var panel = StyleBoxFlat.new()
	panel.bg_color = PAPER
	panel.border_color = Color("#9c8a62")
	panel.set_border_width_all(1)
	panel.set_content_margin_all(10)
	t.set_stylebox("panel", "PanelContainer", panel)
	var le = sb.duplicate()
	le.bg_color = Color("#fbf5e6")
	t.set_stylebox("normal", "LineEdit", le)
	return t


# ---------------------------------------------------------------- helpers

func _clear() -> void:
	for ch in content.get_children():
		ch.queue_free()


func _label(text: String, size := 14, color := INK) -> Label:
	var l = Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _heading(text: String) -> Label:
	return _label(text, 22, ACCENT)


func _button(text: String, cb: Callable, enabled := true) -> Button:
	var b = Button.new()
	b.text = text
	b.disabled = not enabled
	b.pressed.connect(cb)
	return b


func _row(children: Array) -> HBoxContainer:
	var h = HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	for ch in children:
		if ch is Label and ch.custom_minimum_size.x == 0:
			ch.autowrap_mode = TextServer.AUTOWRAP_OFF
		h.add_child(ch)
	return h


func _panel(children: Array) -> PanelContainer:
	var p = PanelContainer.new()
	var v = VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	p.add_child(v)
	for ch in children:
		v.add_child(ch)
	return p


func _add(n: Node) -> void:
	content.add_child(n)


func _msg() -> void:
	if message != "":
		_add(_label(message, 14, ACCENT))
		message = ""


# ---------------------------------------------------------------- title

func _show_title() -> void:
	c = null
	_clear()
	main_split.visible = true
	battle_box.visible = false
	status_label.text = "Condottiere — grey-box prototype"
	_add(_heading("Condottiere"))
	_add(_label("Run a mercenary company in 1440s Italy, sell it to warring city-states, and decide every season whether loyalty or betrayal pays better. The campaign runs from spring 1440 to the Peace of Lodi in 1454."))
	var seed_edit = LineEdit.new()
	seed_edit.placeholder_text = "Seed (blank for random)"
	seed_edit.custom_minimum_size.x = 220
	_add(_row([_label("Seed:"), seed_edit]))
	_add(_button("New campaign", func():
		var sd = int(seed_edit.text) if seed_edit.text.is_valid_int() else randi() % 1000000
		c = Campaign.new()
		c.new_campaign(sd)
		refresh()))
	_add(_button("Continue saved campaign", func():
		c = Campaign.new()
		if c.load_from(SAVE_PATH) == OK:
			refresh()
		else:
			c = null
			message = "No saved campaign found."
			_show_title(), FileAccess.file_exists(SAVE_PATH)))
	_add(_button("Quit", func(): get_tree().quit()))
	_msg()
	map_view.campaign = null
	map_view.queue_redraw()
	log_label.text = ""


# ---------------------------------------------------------------- dispatcher

func refresh() -> void:
	if c == null:
		_show_title()
		return
	_update_status()
	main_split.visible = c.phase != "battle"
	battle_box.visible = c.phase == "battle"
	_clear()
	match c.phase:
		"board":
			_show_board()
		"prepare":
			_show_prepare()
		"march":
			_show_march()
		"battle":
			_show_battle()
		"siege":
			_show_siege()
		"aftermath":
			_show_aftermath()
		"payday":
			_show_payday()
		"winter":
			_show_winter()
		"ended":
			_show_ended()
	_msg()
	map_view.campaign = c
	map_view.queue_redraw()
	log_label.text = "\n".join(c.log.slice(maxi(0, c.log.size() - 60)))
	scroll.scroll_vertical = 0


func _update_status() -> void:
	var co = c.company
	var cont = "no contract"
	if not c.contract.is_empty():
		cont = "%s (%d/%d)" % [GameData.employer(c.contract.employer).name, c.contract.seasons_served, c.contract.term]
	status_label.text = "%d  ·  %d florins  ·  upkeep %d  ·  %d bands, %d men  ·  Pennants %d (%s)  ·  Infamy %d  ·  %s%s" % [
		c.year, co.florins, co.upkeep(), co.bands.size(), co.total_soldiers(), co.pennants,
		Contracts.tier_name(co.pennants), co.infamy, cont, ("  ·  ARREARS %d" % co.arrears) if co.arrears > 0 else ""]


# ---------------------------------------------------------------- 1. board

func _show_board() -> void:
	_add(_heading("Contract board — spring %d" % c.year))
	_add(_label("Sign one condotta. Every contract is a dilemma: gold, reputation and your men's lives never all point the same way.", 13))
	if c.offers.is_empty():
		_add(_label("Nobody is hiring. Your reputation or your infamy closes every door."))
	for i in c.offers.size():
		var o: Dictionary = c.offers[i]
		var e = GameData.employer(o.employer)
		var trust: int = c.world.trust(o.employer)
		var kids = [
			_label("%s — %s" % [e.name, e.personality], 16, ACCENT),
			_label(Contracts.describe(o)),
			_label("Pay reliability %d%%  ·  employer desperation %d%%  ·  their trust in you %d" % [int(o.reliability * 100), int(o.desperation * 100), trust], 12),
		]
		if o.objective == "siege" and not c.company.has_troop("siege_train"):
			kids.append(_label("Needs a siege train (hire one before marching: %d florins)." % c.hire_cost("siege_train"), 12, ACCENT))
		kids.append(_button("Sign and take the advance (%d florins)" % o.advance, func():
			c.sign_contract(i)
			refresh()))
		_add(_panel(kids))
	_add(_button("Wait this year without a contract", func():
		c.skip_contract()
		refresh()))


# ---------------------------------------------------------------- 2. prepare

func _show_prepare() -> void:
	var co = c.company
	_add(_heading("Prepare the company — %s" % GameData.provinces()[c.location].name))
	if not c.contract.is_empty():
		_add(_label(Contracts.describe(c.contract), 13))
	_add(_label("Bands (tick up to 5 to field in battle; each captain leads one band):", 15, ACCENT))
	var cap_names = ["(no captain)"]
	var cap_ids = [-1]
	for cap in co.captains:
		cap_names.append(cap.name)
		cap_ids.append(cap.id)
	for b in co.bands:
		var t = GameData.troop(b.type)
		var chk = CheckBox.new()
		chk.button_pressed = b.id in co.battle_selection
		chk.disabled = not t.get("field", true)
		chk.toggled.connect(func(on):
			var sel: Array = co.battle_selection.duplicate()
			if on and not b.id in sel:
				if sel.size() >= 5:
					message = "Only 5 bands take the field."
					refresh()
					return
				sel.append(b.id)
			elif not on:
				sel.erase(b.id)
			c.set_battle_selection(sel)
			_update_status())
		var opt = OptionButton.new()
		for n in cap_names:
			opt.add_item(n)
		opt.selected = maxi(0, cap_ids.find(b.captain_id))
		opt.item_selected.connect(func(idx):
			if cap_ids[idx] >= 0:
				c.assign_captain(cap_ids[idx], b.id)
			else:
				b.captain_id = -1
			refresh())
		var name_l = _label("%s  %d/%d  rank %d  upkeep %d" % [t.name, b.soldiers, b.max, b.rank, t.upkeep])
		name_l.custom_minimum_size.x = 300
		var refill_cost: int = c.refill_cost(b)
		var bid: int = b.id
		_add(_row([chk, name_l, opt,
			_button("Refill (%d)" % refill_cost, func():
				message = c.refill(bid)
				refresh(), refill_cost > 0 and co.florins >= refill_cost),
			_button("Dismiss", func():
				c.dismiss(bid)
				refresh())]))
	_add(_label("Hire a band (prices depend on local horses and iron):", 15, ACCENT))
	var hire_row = HFlowContainer.new()
	for type in GameData.troops():
		var t = GameData.troop(type)
		var cost: int = c.hire_cost(type)
		var ok: bool = c.can_hire(type) and co.florins >= cost
		var label = "%s %d (+%d/season)" % [t.name, cost, t.upkeep]
		if c.year < t.get("unlock_year", 1440) and not type in co.unlocked:
			label = "%s (from %d)" % [t.name, t.unlock_year]
		var tp: String = type
		var btn = _button(label, func():
			message = c.hire(tp)
			refresh(), ok)
		btn.tooltip_text = "%s. Strong vs %s; weak vs %s." % [t.role, ", ".join(t.strong_vs), ", ".join(t.weak_vs)]
		hire_row.add_child(btn)
	_add(hire_row)
	_add(_label("Captains:", 15, ACCENT))
	for cap in co.captains:
		var traits = []
		for tr in cap.traits:
			traits.append(GameData.traits()[tr].name)
		var led: Array = co.bands_of_captain(cap.id)
		_add(_label("%s%s — Command %d, Valor %d, Cunning %d, Loyalty %d. %s. Ability: %s. %s" % [
			cap.name, " (commander)" if cap.is_commander else "", cap.command, cap.valor, cap.cunning,
			cap.loyalty, ", ".join(traits), cap.ability.replace("_", " "),
			("Leads the %s." % GameData.troop(led[0].type).name) if not led.is_empty() else "Leads no band."], 13))
	_add(_label("Baggage train (%d/%d): trade is side income, not a second game." % [c.cargo_total(), c.cargo_capacity()], 15, ACCENT))
	for g in co.cargo:
		var gg: String = g
		_add(_row([_label("%s: %d carried, %d florins here" % [g.capitalize(), co.cargo[g], c.good_price(g)]),
			_button("Buy 5", func():
				message = c.buy_good(gg, 5)
				refresh()),
			_button("Sell all", func():
				c.sell_good(gg)
				refresh(), co.cargo[g] > 0)]))
	_add(HSeparator.new())
	_add(_row([
		_button("March", func():
			message = c.finish_prepare()
			refresh()),
		_button("Save", func():
			message = "Saved." if c.save_to(SAVE_PATH) == OK else "Save failed."
			refresh()),
		_button("Main menu", _show_title)]))


# ---------------------------------------------------------------- 3. march

func _show_march() -> void:
	_add(_heading("On the march"))
	if c.last_outcome != "":
		_add(_label(c.last_outcome, 13, ACCENT))
	match c.march_pending():
		"event":
			_show_letter()
		"betrayal":
			var o: Dictionary = c.betrayal_offer
			var old = GameData.employer(c.contract.employer)
			var risk = ""
			if "supervisor" in c.contract.clauses:
				risk = " A %s proveditore rides with you: if he uncovers the plot (about %d%%), it may cost your head." % [old.name, int(c.detection_chance(c.contract.employer, true) * 100)]
			_add(_panel([
				_label("A sealed letter from %s" % GameData.employer(o.employer).name, 16, ACCENT),
				_label("They offer %d florins per season (%.0f%% of your pay) for %d season%s if you turn your banners against %s now. You would forfeit the %d-florin advance, gain 15+ Infamy and lose a pennant, and %s would never trust you again.%s" % [
					o.pay, o.mult * 100, o.term, "" if o.term == 1 else "s", old.name, c.contract.advance, old.name, risk]),
				_row([_button("Accept: turn your coat", func():
					c.accept_betrayal()
					refresh()),
					_button("Refuse", func():
						c.reject_betrayal()
						refresh())])]))
		"sham":
			var supervised: bool = "supervisor" in c.contract.clauses
			_add(_panel([
				_label("A quiet word from the enemy camp", 16, ACCENT),
				_label("The enemy army is led by a fellow condottiere. He proposes a staged battle: a noisy, bloodless day, then both companies claim their pay. Detection risk about %d%%%s." % [
					int(c.detection_chance(c.contract.employer, supervised) * (1.0 if supervised else 0.5) * 100),
					" (a supervisor is watching)" if supervised else ""]),
				_row([_button("Agree to the sham battle", func():
					c.accept_sham()
					refresh()),
					_button("Refuse: fight it out", func():
						c.reject_sham()
						refresh())])]))
		"ready":
			if not c.contract.is_empty():
				_add(_label("You arrive before %s." % GameData.provinces()[c.contract.target].name))
			for g in c.company.cargo:
				if c.company.cargo[g] > 0:
					var gg: String = g
					_add(_row([_label("%d %s: %d florins each here" % [c.company.cargo[g], g, c.good_price(g)]),
						_button("Sell", func():
							c.sell_good(gg)
							refresh())]))
			_add(_button("Continue", func():
				message = c.finish_march()
				refresh()))


func _show_letter() -> void:
	var ev: Dictionary = c.current_event
	var kids = [_label(ev.title, 16, ACCENT), _label(ev.text)]
	for i in ev.choices.size():
		var idx = i
		kids.append(_button(ev.choices[i].text, func():
			c.choose_event(idx)
			refresh(), ev.choices[i].available))
	_add(_panel(kids))


# ---------------------------------------------------------------- 4. battle

func _show_battle() -> void:
	# Captains fight their bands on their own until you give them an order.
	battle = c.create_battle(true)
	battle_view.setup(battle)
	battle_info.text = "%s — deploy your formations: select one (left click) and click inside the blue zone. Scouts %s." % [
		c.engagement.kind.capitalize(), "have revealed the enemy" if battle.scouted else "are missing: enemy bands show as unknown banners"]
	_refresh_battle_controls()


func _refresh_battle_controls() -> void:
	for ch in battle_controls.get_children():
		ch.queue_free()
	if battle == null:
		return
	if battle.finished:
		var r: Dictionary = battle.result()
		battle_info.text = "%s after %d seconds." % [["Victory", "Defeat", "Draw"][battle.winner], int(battle.time)]
		battle_controls.add_child(_button("Continue", func():
			c.finish_battle(r)
			battle = null
			refresh()))
		return
	if battle_view.deploying:
		battle_controls.add_child(_button("Begin battle", func():
			battle_view.deploying = false
			battle_view.paused = false
			battle_info.text = "Space pauses. Left click selects; right click moves or attacks. Captains act on their own until you give their band an order."
			_refresh_battle_controls()))
		battle_controls.add_child(_button("Auto-resolve", func():
			c.auto_resolve()
			battle = null
			refresh()))
		return
	battle_controls.add_child(_button("Resume" if battle_view.paused else "Pause", func():
		battle_view.paused = not battle_view.paused
		_refresh_battle_controls()))
	for sp in [1.0, 2.0, 4.0]:
		var spv: float = sp
		battle_controls.add_child(_button("x%d" % int(sp), func(): battle_view.speed = spv, battle_view.speed != sp))
	battle_controls.add_child(VSeparator.new())
	var f = battle.get_formation(battle_view.selected)
	if f != null and f.state == "ok":
		var fl = _label("%s:" % f.label)
		fl.autowrap_mode = TextServer.AUTOWRAP_OFF
		battle_controls.add_child(fl)
		for o in ["advance", "hold", "brace", "charge", "withdraw"]:
			var ov: String = o
			battle_controls.add_child(_button(o.capitalize(), func():
				battle.set_order(f.id, ov)
				f.ai = false
				_refresh_battle_controls(), f.order != o))
		if f.t.get("range", 0) > 0:
			battle_controls.add_child(_button("Hold fire" if f.fire else "Loose", func():
				battle.toggle_fire(f.id)
				_refresh_battle_controls()))
		if not f.captain.is_empty():
			battle_controls.add_child(_button("%s: %s" % [f.captain.name, f.captain.ability.replace("_", " ")], func():
				battle.use_ability(f.id)
				_refresh_battle_controls(), not f.ability_used))
		battle_controls.add_child(_button("Let captain decide", func():
			f.ai = true
			_refresh_battle_controls(), not f.ai))
	elif f != null and f.state == "routing" and not f.captain.is_empty() and not f.ability_used and f.captain.ability == "rally":
		battle_controls.add_child(_button("Rally!", func():
			battle.use_ability(f.id)
			_refresh_battle_controls()))


func _process(_delta: float) -> void:
	if battle != null and battle.finished and c != null and c.phase == "battle":
		if battle_controls.get_child_count() == 0 or not battle_info.text.ends_with("seconds."):
			_refresh_battle_controls()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE and battle != null and not battle_view.deploying:
		battle_view.paused = not battle_view.paused
		_refresh_battle_controls()


# ---------------------------------------------------------------- siege

func _show_siege() -> void:
	var s = c.siege
	_add(_heading("Siege of %s — week %d" % [GameData.provinces()[s.town].name, s.week]))
	_add(_label("Walls %d%%  ·  garrison morale %d  ·  garrison supplies %d weeks  ·  your supplies %d weeks" % [int(s.walls), int(s.garrison_morale), s.garrison_supply, s.our_supply]))
	for line in s.log.slice(maxi(0, s.log.size() - 6)):
		_add(_label(line, 13))
	var acts = {
		"bombard": "Bombard" + ("" if s.has_train else " (needs siege train)"),
		"starve": "Tighten the blockade",
		"bribe": "Bribe a gatekeeper (%d)" % s.bribe_cost(),
		"storm": "Storm the breach",
	}
	var row = []
	for a in acts:
		var av: String = a
		row.append(_button(acts[a], func():
			message = c.siege_action(av)
			refresh(), s.can(a, c.company.florins)))
	_add(_row(row))


# ---------------------------------------------------------------- aftermath

func _show_aftermath() -> void:
	var a: Dictionary = c.aftermath
	_add(_heading("After the battle: %s" % a.result_text))
	_add(_label("Most routed men are captured, not killed."))
	if a.get("prisoners", 0) > 0:
		_add(_panel([_label("You hold %d enemy prisoners." % a.prisoners),
			_row([_button("Ransom them", func():
				message = c.resolve_prisoners("ransom")
				refresh()),
				_button("Recruit them", func():
					message = c.resolve_prisoners("recruit")
					refresh()),
				_button("Release them (trust, less infamy)", func():
					message = c.resolve_prisoners("release")
					refresh())])]))
	if a.get("own_captured", 0) > 0:
		var cost: int = c.own_ransom_cost()
		_add(_panel([_label("The enemy holds %d of your men." % a.own_captured),
			_row([_button("Ransom them back (%d)" % cost, func():
				message = c.ransom_own_men(true)
				refresh(), c.company.florins >= cost),
				_button("Leave them", func():
					message = c.ransom_own_men(false)
					refresh())])]))
	_add(_button("Continue", func():
		c.finish_aftermath()
		refresh()))


# ---------------------------------------------------------------- 5. payday

func _show_payday() -> void:
	_add(_heading("Payday"))
	for line in c.report:
		_add(_label(line))
	if not c.contract.is_empty() and c.contract.get("defaulted", false):
		_add(_button("Walk away from the contract", func():
			c.walk_away()
			refresh()))
	_add(_button("To winter quarters", func():
		c.finish_payday()
		refresh()))


# ---------------------------------------------------------------- 6. winter

func _show_winter() -> void:
	_add(_heading("Winter quarters, %d" % c.year))
	for line in c.report:
		_add(_label(line))
	if c.last_outcome != "":
		_add(_label(c.last_outcome, 13, ACCENT))
	match c.winter_pending():
		"event":
			_show_letter()
			return
		"lordship":
			var lo: Dictionary = c.lordship_offer
			_add(_panel([_label("A city without a master", 16, ACCENT), _label(lo.text),
				_label("Seizing %s needs %d florins and %d men." % [GameData.provinces()[lo.town].name, lo.cost, lo.min_soldiers]),
				_row([_button("Seize the city", func():
					c.seize_lordship(true)
					refresh(), c.can_seize_lordship()),
					_button("Not yet", func():
						c.seize_lordship(false)
						refresh())])]))
			return
	var row = [_button("Next year", func():
		c.finish_winter()
		refresh())]
	row.append(_button("Retire (needs %d florins)" % Campaign.RETIRE_FLORINS, func():
		c.retire()
		refresh(), c.can_retire()))
	row.append(_button("Save", func():
		message = "Saved." if c.save_to(SAVE_PATH) == OK else "Save failed."
		refresh()))
	_add(_row(row))


# ---------------------------------------------------------------- ended

func _show_ended() -> void:
	_add(_heading("Victory" if c.won else "The end"))
	_add(_label(Campaign.ENDING_TEXT.get(c.ending, c.ending), 18, ACCENT))
	var st: Dictionary = c.stats
	_add(_label("Seasons %d · battles won %d, lost %d · contracts completed %d, broken %d · betrayals %d · sham battles %d · pennants %d · infamy %d · florins %d" % [
		st.seasons, st.battles_won, st.battles_lost, st.contracts_completed, st.contracts_broken,
		st.betrayals, st.shams, c.company.pennants, c.company.infamy, c.company.florins]))
	_add(_button("New campaign", _show_title))
