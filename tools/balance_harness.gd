## Balance harness: auto-plays many campaigns headless and exports stats to CSV,
## then checks the design doc's tuning targets.
##
## Usage:
##   godot --headless --path . --script res://tools/balance_harness.gd -- --runs 200 --seed 1 --out balance_out
extends SceneTree

const Campaign := preload("res://sim/campaign.gd")
const AutoPlayer := preload("res://sim/auto_player.gd")
const Rng := preload("res://sim/rng.gd")
const Contracts := preload("res://sim/contracts.gd")

const POLICIES := ["honest", "mixed", "betrayer"]


func _init() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", "100"))
	var seed0 := int(args.get("seed", "1"))
	var out_dir: String = args.get("out", "balance_out")
	var policies: Array = POLICIES if not args.has("policy") else [args.policy]
	DirAccess.make_dir_recursive_absolute(out_dir)
	var seasons_f := FileAccess.open(out_dir.path_join("seasons.csv"), FileAccess.WRITE)
	var runs_f := FileAccess.open(out_dir.path_join("runs.csv"), FileAccess.WRITE)
	seasons_f.store_line("policy,run,seed,year,florins,upkeep,bands,soldiers,pennants,tier,infamy,arrears,under_contract,low_bank")
	runs_f.store_line("policy,run,seed,ending,won,final_year,florins,pennants,infamy,betrayals,shams,shams_caught,battles_won,battles_lost,contracts_completed,contracts_broken,desertions,defections,low_bank_seasons,seasons,income,max_tier")
	var t0 := Time.get_ticks_msec()
	var summary := {}
	for policy in policies:
		var s := {"runs": 0, "wins": 0, "seasons": 0, "low_bank": 0, "pennants": 0.0, "income": 0.0, "betrayals": 0, "endings": {}, "max_tier": 0.0, "first_income": 0.0}
		for r in runs:
			var sd := seed0 + r
			var c := Campaign.new()
			c.new_campaign(sd)
			var ap := AutoPlayer.new(policy, Rng.new(sd * 7919 + 13))
			var last_year := -1
			var max_tier := 0
			var steps := 0
			while not c.ended and steps < 6000:
				ap.step(c)
				steps += 1
				max_tier = maxi(max_tier, Contracts.pennant_tier(c.company.pennants))
				if c.phase == "winter" and c.year != last_year and c.winter_pending() != "event":
					last_year = c.year
					var co = c.company
					seasons_f.store_line("%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d" % [policy, r, sd, c.year, co.florins, co.upkeep(), co.bands.size(), co.total_soldiers(), co.pennants, Contracts.pennant_tier(co.pennants), co.infamy, co.arrears, 0 if c.contract.is_empty() else 1, 1 if co.florins < co.upkeep() else 0])
			var st: Dictionary = c.stats
			runs_f.store_line("%s,%d,%d,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d" % [policy, r, sd, c.ending, 1 if c.won else 0, c.year, c.company.florins, c.company.pennants, c.company.infamy, st.betrayals, st.shams, st.shams_caught, st.battles_won, st.battles_lost, st.contracts_completed, st.contracts_broken, st.desertions, st.defections, st.low_bank_seasons, st.seasons, st.income, max_tier])
			s.runs += 1
			s.wins += 1 if c.won else 0
			s.seasons += st.seasons
			s.low_bank += st.low_bank_seasons
			s.pennants += c.company.pennants
			s.income += float(st.income) / maxf(st.seasons, 1)
			s.betrayals += st.betrayals
			s.max_tier += max_tier
			s.endings[c.ending] = s.endings.get(c.ending, 0) + 1
		summary[policy] = s
	seasons_f.close()
	runs_f.close()
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	print("Balance harness: %d runs x %d policies in %.1f s. CSV in %s/" % [runs, policies.size(), secs, out_dir])
	for policy in policies:
		var s: Dictionary = summary[policy]
		print("\n[%s]" % policy)
		print("  win rate:              %5.1f%%" % (100.0 * s.wins / s.runs))
		print("  low-bank seasons:      %5.1f%%   (target ~40%%: less than one season of upkeep in the bank)" % (100.0 * s.low_bank / maxf(s.seasons, 1)))
		print("  income per season:     %6.0f florins" % (s.income / s.runs))
		print("  final pennants (avg):  %5.1f    max tier reached (avg) %.2f" % [s.pennants / s.runs, s.max_tier / s.runs])
		print("  betrayals per run:     %5.2f" % (float(s.betrayals) / s.runs))
		print("  endings:               %s" % str(s.endings))
	if summary.has("honest"):
		var h: Dictionary = summary.honest
		print("\nTarget check: a run with zero betrayals is winnable: %s" % ("YES" if h.wins > 0 else "NO"))
	if summary.has("honest") and summary.has("betrayer"):
		var dh: float = summary.honest.max_tier / summary.honest.runs
		var db: float = summary.betrayer.max_tier / summary.betrayer.runs
		print("Target check: betrayal costs future access (max tier honest %.2f vs betrayer %.2f)" % [dh, db])
	quit()


func _parse_args(argv: PackedStringArray) -> Dictionary:
	var d := {}
	var i := 0
	while i < argv.size():
		var a: String = argv[i]
		if a.begins_with("--"):
			var key := a.substr(2)
			if i + 1 < argv.size() and not argv[i + 1].begins_with("--"):
				d[key] = argv[i + 1]
				i += 1
			else:
				d[key] = "true"
		i += 1
	return d
