extends Node
## Headless unit tests — run via run_tests.sh.
## Uses a scene so autoloads (GameConfig etc.) are available during compilation.

var _passed := 0
var _failed := 0


func _ready() -> void:
	print("\n=== Deadly Pool Test Suite ===\n")

	test_powerup_meta()
	test_powerup_handler_dispatch()
	test_powerup_random_type()
	test_game_config_roundtrip()

	print("\n--- %d passed, %d failed ---\n" % [_passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)


# --- Assertion helpers ---

func ok(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
		print("  [pass] %s" % msg)
	else:
		_failed += 1
		print("  [FAIL] %s" % msg)


func eq(a: Variant, b: Variant, msg: String) -> void:
	if a == b:
		_passed += 1
		print("  [pass] %s" % msg)
	else:
		_failed += 1
		print("  [FAIL] %s  (got %s, want %s)" % [msg, a, b])


# --- Tests ---

func test_powerup_meta() -> void:
	print("powerup meta lookups:")

	eq(Powerup.get_powerup_name(Powerup.Type.BOMB),        "Bomb",         "BOMB name")
	eq(Powerup.get_powerup_name(Powerup.Type.FREEZE),      "Freeze",       "FREEZE name")
	eq(Powerup.get_powerup_name(Powerup.Type.PORTAL_TRAP), "Portal Trap",  "PORTAL_TRAP name")
	eq(Powerup.get_powerup_name(Powerup.Type.SWAP),        "Swap",         "SWAP name")
	eq(Powerup.get_powerup_name(Powerup.Type.GRAVITY_WELL),"Gravity Well", "GRAVITY_WELL name")
	eq(Powerup.get_powerup_name(99),                       "(type99)",     "unknown type name fallback")

	ok(Powerup.get_color(Powerup.Type.BOMB).r > 0.5,   "BOMB color is reddish")
	ok(Powerup.get_color(Powerup.Type.FREEZE).b > 0.5, "FREEZE color is blueish")
	eq(Powerup.get_color(99), Color.WHITE,              "unknown type color is WHITE")

	ok(not Powerup.get_symbol(Powerup.Type.BOMB).is_empty(), "BOMB has symbol")
	eq(Powerup.get_symbol(99), "?",                                "unknown type symbol is ?")

	ok(not Powerup.get_desc(Powerup.Type.BOMB).is_empty(), "BOMB has desc")
	eq(Powerup.get_desc(99), "",                            "unknown type desc is empty")


func test_powerup_handler_dispatch() -> void:
	print("powerup handler dispatch:")

	ok(Powerup.get_handler(Powerup.Type.BOMB)        is Powerup.BombHandler,        "BOMB → BombHandler")
	ok(Powerup.get_handler(Powerup.Type.FREEZE)      is Powerup.FreezeHandler,      "FREEZE → FreezeHandler")
	ok(Powerup.get_handler(Powerup.Type.PORTAL_TRAP) is Powerup.PortalTrapHandler,  "PORTAL_TRAP → PortalTrapHandler")
	ok(Powerup.get_handler(Powerup.Type.SWAP)        is Powerup.SwapHandler,        "SWAP → SwapHandler")
	ok(Powerup.get_handler(Powerup.Type.GRAVITY_WELL)is Powerup.GravityWellHandler, "GRAVITY_WELL → GravityWellHandler")
	ok(Powerup.get_handler(99)                       is Powerup.Handler,            "unknown type → base Handler")

	# Handlers are singletons — same object returned each call
	ok(Powerup.get_handler(Powerup.Type.BOMB) == Powerup.get_handler(Powerup.Type.BOMB),
		"get_handler returns same singleton instance")

	# Each type maps to a DIFFERENT handler instance
	ok(Powerup.get_handler(Powerup.Type.FREEZE) != Powerup.get_handler(Powerup.Type.BOMB),
		"distinct types have distinct handler instances")


func test_powerup_random_type() -> void:
	print("powerup random_type:")

	var valid: Array = [
		Powerup.Type.BOMB, Powerup.Type.FREEZE,
		Powerup.Type.PORTAL_TRAP, Powerup.Type.SWAP, Powerup.Type.GRAVITY_WELL,
	]
	var all_valid := true
	for _i in 200:
		if Powerup.random_type() not in valid:
			all_valid = false
			break
	ok(all_valid, "random_type always returns a valid type (200 samples)")

	var seen: Dictionary = {}
	for _i in 100:
		seen[Powerup.random_type()] = true
	ok(seen.size() >= 3, "random_type produces at least 3 distinct values in 100 rolls (got %d)" % seen.size())

	# Weighted: zero out all except BOMB — every roll must be BOMB
	var orig_fr:  float = GameConfig.powerup_weight_freeze
	var orig_pt:  float = GameConfig.powerup_weight_portal_trap
	var orig_sw:  float = GameConfig.powerup_weight_swap
	var orig_gw:  float = GameConfig.powerup_weight_gravity_well
	GameConfig.powerup_weight_freeze      = 0.0
	GameConfig.powerup_weight_portal_trap = 0.0
	GameConfig.powerup_weight_swap        = 0.0
	GameConfig.powerup_weight_gravity_well = 0.0
	var only_bomb := true
	for _i in 50:
		if Powerup.random_type() != Powerup.Type.BOMB:
			only_bomb = false
			break
	ok(only_bomb, "weight=0 excludes types: only BOMB spawns when others are zeroed")
	GameConfig.powerup_weight_freeze      = orig_fr
	GameConfig.powerup_weight_portal_trap = orig_pt
	GameConfig.powerup_weight_swap        = orig_sw
	GameConfig.powerup_weight_gravity_well = orig_gw

	# Fallback: all weights zeroed → still returns a valid type
	GameConfig.powerup_weight_bomb        = 0.0
	GameConfig.powerup_weight_freeze      = 0.0
	GameConfig.powerup_weight_portal_trap = 0.0
	GameConfig.powerup_weight_swap        = 0.0
	GameConfig.powerup_weight_gravity_well = 0.0
	var fallback_valid := true
	for _i in 20:
		if Powerup.random_type() not in valid:
			fallback_valid = false
			break
	ok(fallback_valid, "all-zero weights fallback still returns a valid type")
	GameConfig.powerup_weight_bomb        = 1.0
	GameConfig.powerup_weight_freeze      = orig_fr
	GameConfig.powerup_weight_portal_trap = orig_pt
	GameConfig.powerup_weight_swap        = orig_sw
	GameConfig.powerup_weight_gravity_well = orig_gw


func test_game_config_roundtrip() -> void:
	print("game_config roundtrip:")

	# Instantiate a fresh config (not the autoload) so we can mutate freely
	var cfg: Node = load("res://scripts/game_config.gd").new()

	var d: Dictionary = cfg.to_dict()
	ok(d.has("ball_mass"),    "dict contains ball_mass")
	ok(d.has("bomb_force"),   "dict contains bomb_force")
	ok(d.has("freeze_duration"), "dict contains freeze_duration")
	ok(d.size() >= 20,        "dict has at least 20 keys (got %d)" % d.size())

	# Float field roundtrip
	var orig_mass: float = cfg.ball_mass
	cfg.ball_mass = orig_mass * 3.0
	cfg.from_dict(d)
	eq(cfg.ball_mass, orig_mass, "from_dict restores float field (ball_mass)")

	# Bool field roundtrip
	var orig_smart: bool = cfg.bot_smart_targeting
	cfg.bot_smart_targeting = not orig_smart
	cfg.from_dict(d)
	eq(cfg.bot_smart_targeting, orig_smart, "from_dict restores bool field (bot_smart_targeting)")

	# Sanity: key values are in plausible ranges
	ok(cfg.ball_mass > 0.0 and cfg.ball_mass < 10.0,     "ball_mass in plausible range")
	ok(cfg.bomb_force > 0.0,                              "bomb_force is positive")
	ok(cfg.powerup_spawn_min_delay < cfg.powerup_spawn_max_delay,
		"spawn min_delay < max_delay")

	cfg.free()
