extends RefCounted
class_name Powerup

enum Type {
	NONE = 0,
	BOMB = 2,          # Arm with SPACE - explodes on collision
	FREEZE = 3,        # Arm with SPACE - freeze in place, acts as wall for 2s
	PORTAL_TRAP = 4,   # SPACE to place blue portal, SPACE again to place orange portal
	SWAP = 6,          # SPACE - swap positions + velocity with cursor-targeted enemy
	GRAVITY_WELL = 7,  # SPACE - place a temporary field that curves nearby trajectories
}

const META := {
	2: {"name": "Bomb", "symbol": "(*)", "color": Color(1.0, 0.3, 0.1), "desc": "SPACE to arm - explode on hit"},
	3: {"name": "Freeze", "symbol": "[*]", "color": Color(0.5, 0.85, 1.0), "desc": "SPACE to arm - freeze in place, acts as wall for 2s"},
	4: {"name": "Portal Trap", "symbol": "{O}", "color": Color(0.2, 0.6, 1.0), "desc": "SPACE to place blue portal, SPACE again for orange"},
	6: {"name": "Swap", "symbol": "<>", "color": Color(1.0, 0.45, 0.1), "desc": "SPACE - aim at enemy and swap positions + velocity"},
	7: {"name": "Gravity Well", "symbol": "(@)", "color": Color(0.62, 0.38, 1.0), "desc": "SPACE at cursor - pull nearby balls toward center"},
}

static func get_powerup_name(type: int) -> String:
	var t := int(type)
	if META.has(t):
		return META[t]["name"]
	return "(type%d)" % t

static func get_symbol(type: int) -> String:
	var t := int(type)
	if META.has(t):
		return META[t]["symbol"]
	return "?"

static func get_color(type: int) -> Color:
	var t := int(type)
	if META.has(t):
		return META[t]["color"]
	return Color.WHITE

static func get_desc(type: int) -> String:
	var t := int(type)
	if META.has(t):
		return META[t]["desc"]
	return ""

static func random_type(bomb_weight_override: float = -1.0) -> int:
	var types := [Type.BOMB, Type.FREEZE, Type.PORTAL_TRAP, Type.SWAP, Type.GRAVITY_WELL]
	var weights := [
		bomb_weight_override if bomb_weight_override >= 0.0 else GameConfig.powerup_weight_bomb,
		GameConfig.powerup_weight_freeze,
		GameConfig.powerup_weight_portal_trap,
		GameConfig.powerup_weight_swap,
		GameConfig.powerup_weight_gravity_well,
	]
	var total: float = 0.0
	for w in weights:
		total += maxf(w, 0.0)
	if total <= 0.0:
		return types[randi() % types.size()]  # fallback: all zeroed, equal chance
	var roll := randf() * total
	var cumulative: float = 0.0
	for i in types.size():
		cumulative += maxf(weights[i], 0.0)
		if roll < cumulative:
			return types[i]
	return types[-1]


static func random_type_from_allowed(allowed_types: Array[int], bomb_weight_override: float = -1.0) -> int:
	var default_types: Array[int] = [Type.BOMB, Type.FREEZE, Type.PORTAL_TRAP, Type.SWAP, Type.GRAVITY_WELL]
	var allowed: Array[int] = []
	for t in allowed_types:
		if t in default_types and t not in allowed:
			allowed.append(t)
	if allowed.is_empty():
		allowed = default_types

	var weights: Array[float] = []
	for t in allowed:
		var w := 1.0
		match t:
			Type.BOMB:
				w = bomb_weight_override if bomb_weight_override >= 0.0 else GameConfig.powerup_weight_bomb
			Type.FREEZE:
				w = GameConfig.powerup_weight_freeze
			Type.PORTAL_TRAP:
				w = GameConfig.powerup_weight_portal_trap
			Type.SWAP:
				w = GameConfig.powerup_weight_swap
			Type.GRAVITY_WELL:
				w = GameConfig.powerup_weight_gravity_well
		weights.append(maxf(w, 0.0))

	var total: float = 0.0
	for w in weights:
		total += w
	if total <= 0.0:
		return allowed[randi() % allowed.size()]

	var roll := randf() * total
	var cumulative: float = 0.0
	for i in allowed.size():
		cumulative += weights[i]
		if roll < cumulative:
			return allowed[i]
	return allowed[-1]


class PowerupItem extends Node3D:
	var powerup_id: int = -1
	var powerup_type: int = Type.NONE
	var _base_y: float = 0.45
	var _timer: float = 0.0

	static func create(id: int, type: int, pos: Vector3) -> PowerupItem:
		var item := PowerupItem.new()
		item.powerup_id = id
		item.powerup_type = type
		item.position = Vector3(pos.x, item._base_y, pos.z)

		var color: Color = Powerup.get_color(type)

		# Glowing cylinder
		var mesh_inst := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.25
		cyl.bottom_radius = 0.25
		cyl.height = 0.15
		mesh_inst.mesh = cyl

		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 2.0
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.85
		mesh_inst.material_override = mat
		item.add_child(mesh_inst)

		# Label3D removed for web performance — color + glow distinguish powerup types

		return item

	func _process(delta: float) -> void:
		_timer += delta
		rotation.y = _timer * 2.0
		position.y = _base_y + sin(_timer * 3.0) * 0.08


# --- Per-type powerup handlers ---
# To add a new powerup: add enum + META entry + a Handler subclass below + register in _static_init.
# PowerupSystem dispatch calls Powerup.get_handler(type).method(ball, ps).

class Handler:
	## on_activate: called server-side when the player presses SPACE.
	## Return true → standard arm-and-broadcast; false → skip (instant-trigger powerups).
	func on_activate(_ball: PoolBall, _ps: PowerupSystem) -> bool:
		return true

	## on_timeout: called server-side when armed_timer expires.
	func on_timeout(ball: PoolBall, ps: PowerupSystem) -> void:
		ball.held_powerup = Powerup.Type.NONE
		ball.powerup_armed = false
		ball.armed_timer = 0.0
		ps._rpc_consumed(ball.slot)

	## on_armed_visual: called client-side when the armed RPC arrives.
	func on_armed_visual(_ball: PoolBall, _type: int, _ps: PowerupSystem) -> void:
		pass


class BombHandler extends Handler:
	func on_timeout(ball: PoolBall, ps: PowerupSystem) -> void:
		ps.trigger_bomb(ball)  # trigger_bomb clears held_powerup/armed state internally

	func on_armed_visual(ball: PoolBall, type: int, ps: PowerupSystem) -> void:
		ps._spawn_arm_visual(ball.global_position, Powerup.get_color(type), true, 0.45, 2.5)


class FreezeHandler extends Handler:
	func on_activate(ball: PoolBall, _ps: PowerupSystem) -> bool:
		ball.freeze_timer = GameConfig.freeze_duration
		ball.linear_velocity = Vector3.ZERO
		ball.angular_velocity = Vector3.ZERO
		ball.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		ball.freeze = true
		return true

	func on_timeout(ball: PoolBall, ps: PowerupSystem) -> void:
		ball.powerup_armed = false
		ball.freeze = false
		ball.held_powerup = Powerup.Type.NONE
		ball.armed_timer = 0.0
		ps._rpc_consumed(ball.slot)

	func on_armed_visual(ball: PoolBall, type: int, ps: PowerupSystem) -> void:
		ball.freeze_timer = GameConfig.freeze_duration  # client-side freeze visual countdown
		ps._spawn_arm_visual(ball.global_position, Powerup.get_color(type), true, 0.35, 2.0)


class PortalTrapHandler extends Handler:
	# Portal placement is handled directly in try_activate / server_activate with cursor_world_pos.
	# on_activate is never called for portal_trap — the two-step SPACE logic bypasses the Handler.
	func on_timeout(ball: PoolBall, ps: PowerupSystem) -> void:
		# Armed timeout fired (blue placed, orange never placed) — cancel and clean up
		ps.cancel_portal(ball.slot)
		ball.held_powerup = Powerup.Type.NONE
		ball.powerup_armed = false
		ball.armed_timer = 0.0
		ps._rpc_consumed(ball.slot)


class SwapHandler extends Handler:
	func on_activate(_ball: PoolBall, _ps: PowerupSystem) -> bool:
		return false  # cursor-targeted — handled in PowerupSystem.try_activate / server_activate


class GravityWellHandler extends Handler:
	func on_activate(_ball: PoolBall, _ps: PowerupSystem) -> bool:
		return false  # cursor-targeted — handled in PowerupSystem.try_activate / server_activate


static var handlers: Dictionary = {}

static func _static_init() -> void:
	handlers[Type.BOMB]         = BombHandler.new()
	handlers[Type.FREEZE]       = FreezeHandler.new()
	handlers[Type.PORTAL_TRAP]  = PortalTrapHandler.new()
	handlers[Type.SWAP]         = SwapHandler.new()
	handlers[Type.GRAVITY_WELL] = GravityWellHandler.new()


static func get_handler(type: int) -> Handler:
	return handlers.get(type, Handler.new())
