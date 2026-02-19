# Performance Issues Analysis & Fixes

**Document Created:** February 19, 2026  
**Game:** Deadly Pool (Godot 4.x, WebSocket multiplayer)  
**Issue Context:** Web build multiplayer — other players experience FPS drops (→20 FPS) during ball collisions

---

## 🎯 Primary Issue: Multiplayer Web Build Performance

### Symptoms
- **Host/server (you):** No performance issues (good PC, 60 FPS stable)
  - Debug overlay shows: 60 FPS, stable sync, normal draw calls
  - Accessing server via external IP, but hardware masks the issue
- **Remote clients (other players):** FPS drops to ~20 during:
  - Ball-to-ball collisions
  - Ball-to-wall collisions
  - Rapid collision sequences
- **Sync rate:** Drops to ~40 on affected clients (network sync struggling)
- **Draw calls:** Spike momentarily during collisions (on their clients)

### Critical Insight
**Your debug overlay (`game_hud.gd:update_debug()`) shows YOUR client's stats, not other players'.**

```gdscript
var fps: float = float(Engine.get_frames_per_second())  # YOUR FPS
var draw_calls: int = int(Performance.get_monitor(...))  # YOUR draw calls
```

**Other players see their own overlay with their own (dropping) FPS.**

### Root Cause Analysis

**Every client independently detects collisions and spawns effects:**

```
┌─────────────┐
│   Server    │─── Detects collisions
│   (Host)    │─── Spawns bursts locally
└──────┬──────┘─── Broadcasts state (30Hz)
       │
       ▼
┌─────────────────────────────────────────┐
│  Remote Client (Weak PC)                │
│  ├─ Receives network state              │
│  ├─ Runs own collision detection (60Hz) │
│  ├─ Spawns OWN bursts                   │
│  ├─ Receives server burst spawns        │
│  └─ DOUBLE EFFECTS = 2X draw calls      │
└─────────────────────────────────────────┘
```

**Why it affects remote players more:**

| Factor | Host (You) | Remote Clients |
|--------|------------|----------------|
| CPU/GPU | Good PC | Likely weaker |
| Bursts spawned | Local only | Local + network duplicates |
| Network overhead | Minimal (server) | Receiving state + effects |
| Draw calls | X | ~2X (duplicate effects) |
| GC pressure | Moderate | High (web + more allocations) |

---

## 🔧 Recommended Fixes (Priority Order)

### Fix 1: Server-Only Collision Detection ⭐⭐⭐

**Problem:** Every client runs collision detection and spawns bursts independently.

**Solution:** Server detects collisions and broadcasts burst events via RPC. Clients only render.

**Files to modify:**
- `scripts/game_manager.gd`
- `scripts/comic_burst.gd` (optional RPC helper)

**Code changes:**

```gdscript
# === game_manager.gd ===

# 1. Add RPC for burst spawning (add near other @rpc functions)
@rpc("any_peer", "call_remote", "reliable")
func _rpc_spawn_burst(pos: Vector3, color: Color, intensity: float, with_text: bool) -> void:
    if _is_headless:
        return
    var burst := ComicBurst.create(pos, color, intensity, with_text)
    add_child(burst)


# 2. Modify _process() to only run collision detection on server
func _process(delta: float) -> void:
    if _is_headless:
        return

    game_hud.update_debug(delta)

    if game_over:
        return

    # ... existing code ...

    # CHANGE THIS:
    # if not _is_server or NetworkManager.is_single_player:
    #     _detect_ball_collisions()

    # TO THIS (server-only):
    if _is_server:
        _detect_ball_collisions()


# 3. Modify _detect_ball_collisions() to broadcast bursts
func _detect_ball_collisions() -> void:
    var count := balls.size()

    # Ball-to-ball collisions
    for i in count:
        var a := balls[i]
        if a == null or not a.is_alive or a.is_pocketing:
            continue
        for j in range(i + 1, count):
            var b := balls[j]
            if b == null or not b.is_alive or b.is_pocketing:
                continue

            var dist := a._to_pos.distance_to(b._to_pos) if a._snapshot_count >= 1 and b._snapshot_count >= 1 else a.global_position.distance_to(b.global_position)
            var key := "%d_%d" % [i, j]
            var was_touching: bool = _collision_pairs.get(key, false)
            var is_touching := dist < BALL_TOUCH_DIST

            if is_touching and not was_touching:
                var rel_vel := (a.synced_velocity - b.synced_velocity).length()
                if rel_vel < 0.5:
                    _collision_pairs[key] = is_touching
                    continue

                var intensity := clampf(rel_vel / 10.0, 0.0, 1.0)
                var mid := a.global_position.lerp(b.global_position, 0.5)
                mid.y = 0.5
                var burst_color := a.ball_color.lerp(b.ball_color, 0.5)

                # Server spawns burst locally
                var burst := ComicBurst.create(mid, burst_color, intensity, intensity > 0.15)
                add_child(burst)

                # Broadcast to ALL clients (including server's own client)
                if not NetworkManager.is_single_player:
                    _rpc_spawn_burst.rpc(mid, burst_color, intensity, intensity > 0.15)

                # Play hit sound on the faster-moving ball
                var faster_ball: PoolBall = a if a.synced_velocity.length() >= b.synced_velocity.length() else b
                faster_ball.play_hit_ball_sound(rel_vel)

            _collision_pairs[key] = is_touching

    # ... wall collision code remains similar ...
```

**Expected impact:** +20-30 FPS for remote clients  
**Complexity:** Medium  
**Risk:** Low (server remains source of truth)

---

### Fix 2: Collision Cooldown (Alternative/Backup) ⭐⭐

**Problem:** Same collision detected multiple times, spawning duplicate bursts.

**Solution:** Add per-pair cooldown to prevent rapid re-spawning.

**Code changes:**

```gdscript
# === game_manager.gd ===

# Add member variable
var _collision_cooldowns: Dictionary = {}  # "i_j" -> float (time remaining)


# In _detect_ball_collisions(), add cooldown check:
if is_touching and not was_touching:
    var key := "%d_%d" % [i, j]

    # Skip if recently spawned (NEW)
    if key in _collision_cooldowns and _collision_cooldowns[key] > 0.0:
        _collision_pairs[key] = is_touching
        continue

    # ... existing collision code ...

    # Set cooldown after spawning (NEW)
    _collision_cooldowns[key] = 0.15  # 150ms


# In _process(), tick down cooldowns (NEW)
func _process(delta: float) -> void:
    # ... existing code ...

    # Tick down collision cooldowns
    for key in _collision_cooldowns.keys():
        _collision_cooldowns[key] -= delta
        if _collision_cooldowns[key] <= 0.0:
            _collision_cooldowns.erase(key)
```

**Expected impact:** +10-15 FPS  
**Complexity:** Low  
**Risk:** Very low

---

### Fix 3: Local-Only Bursts (Band-aid) ⭐

**Problem:** Clients spawn bursts for collisions they can't verify.

**Solution:** Only spawn bursts when YOUR ball is involved.

**Code changes:**

```gdscript
# === game_manager.gd ===

func _detect_ball_collisions() -> void:
    # ... existing code ...

    if is_touching and not was_touching:
        # Only spawn for LOCAL player collisions (NEW)
        var my_slot := NetworkManager.my_slot
        var involves_me := (i == my_slot) or (j == my_slot)

        if not involves_me and not NetworkManager.is_single_player:
            _collision_pairs[key] = is_touching
            continue

        # ... rest of existing code ...
```

**Expected impact:** +15-20 FPS (but fewer visual effects)  
**Complexity:** Very low  
**Risk:** Low (reduces visual feedback)

---

### Fix 4: Server Detection + Broadcast Collision Sounds ⭐⭐⭐

**Problem:** Both server AND clients detect collisions = duplicate audio overhead.

**Solution:** Server detects collisions and broadcasts via RPC. Clients play sounds locally.

**Why this matters:**
- Server is authoritative (single source of truth)
- Each client plays sound ONCE per collision (not multiple times)
- Players still hear all collisions (including remote ones)

**Code changes:**

```gdscript
# === game_manager.gd ===

# 1. Add RPC for collision sound broadcast (add near other @rpc functions)
@rpc("any_peer", "call_remote", "reliable")
func _rpc_collision_sound(pos: Vector3, speed: float, is_wall: bool) -> void:
    if _is_headless:
        return
    
    # Find closest ball to position for spatial audio
    var closest_ball: PoolBall = null
    var closest_dist := INF
    
    for ball in balls:
        if ball == null or not ball.is_alive:
            continue
        var dist := ball.global_position.distance_to(pos)
        if dist < closest_dist:
            closest_dist = dist
            closest_ball = ball
    
    # Play sound on closest ball
    if closest_ball:
        if is_wall:
            closest_ball.play_hit_wall_sound(speed)
        else:
            closest_ball.play_hit_ball_sound(speed)


# 2. Modify _detect_ball_collisions() to use RPC
func _detect_ball_collisions() -> void:
    # ... existing ball-to-ball code ...

    if is_touching and not was_touching:
        var rel_vel := (a.synced_velocity - b.synced_velocity).length()
        if rel_vel < 0.5:
            _collision_pairs[key] = is_touching
            continue

        # ... existing burst code ...

        # CHANGE THIS:
        # var faster_ball: PoolBall = a if ... else b
        # faster_ball.play_hit_ball_sound(rel_vel)

        # TO THIS (server broadcasts to all clients):
        if not NetworkManager.is_single_player:
            _rpc_collision_sound.rpc(mid, rel_vel, false)
        else:
            # Single player: play directly
            var faster_ball: PoolBall = a if a.synced_velocity.length() >= b.synced_velocity.length() else b
            faster_ball.play_hit_ball_sound(rel_vel)

    # ... wall collisions similar ...

    # For wall collisions:
    if near_wall and not was_near:
        var speed := ball.synced_velocity.length()
        if speed > 1.0:
            # ... existing burst code ...

            # Broadcast wall collision
            if not NetworkManager.is_single_player:
                _rpc_collision_sound.rpc(burst_pos, speed, true)
            else:
                ball.play_hit_wall_sound(speed)
```

**Alternative (simpler, less network traffic):** Only play sounds for collisions involving YOUR ball:

```gdscript
# In _detect_ball_collisions():
var my_slot := NetworkManager.my_slot
var involves_me := (i == my_slot) or (j == my_slot)

if involves_me or NetworkManager.is_single_player:
    faster_ball.play_hit_ball_sound(rel_vel)
# Else: skip sound (other players hear it on their client)
```

**Trade-offs:**

| Approach | Pros | Cons |
|----------|------|------|
| Server broadcast | Everyone hears everything | More network traffic |
| Local-only | Zero network overhead | Miss some distant collisions |

**Expected impact:** +10-20 FPS during collisions (audio is expensive on web)  
**Complexity:** Medium (requires RPC)  
**Risk:** Low (sounds still play, just not duplicated)

---

### Fix 5: Web-Specific Visual Optimizations ⭐⭐

**Problem:** `Label3D` and burst effects are expensive on web builds.

**Solution:** Remove Label3D text from comic bursts (already done).

**Code changes:**

```gdscript
# === comic_burst.gd ===

# 1. Removed _label variable and IMPACT_WORDS constant
# 2. Always set _show_text = false
# 3. Removed Label3D creation code from _ready()
# 4. Removed Label3D animation code from _process()
```

**Status:** ✅ **Implemented** - Label3D removed from all comic bursts

**Expected impact:** +5-10 FPS on web builds  
**Risk:** Very low (minor visual reduction - starburst effect remains)

---

### Fix 6: Reduce Collision Detection Frequency ⭐

**Problem:** Running collision detection at 60Hz is overkill for visual effects.

**Solution:** Run at 20-30Hz instead.

**Code changes:**

```gdscript
# === game_manager.gd ===

# Add member variables
var _collision_detect_timer: float = 0.0
var _collision_detect_interval: float = 0.05  # 20Hz (was 60Hz)


# In _process():
func _process(delta: float) -> void:
    # ... existing code ...

    # Run collision detection at reduced frequency
    _collision_detect_timer += delta
    if _collision_detect_timer >= _collision_detect_interval:
        _collision_detect_timer = 0.0
        if _is_server:
            _detect_ball_collisions()
```

**Expected impact:** +5-8 FPS  
**Complexity:** Very low  
**Risk:** Low (slightly delayed effects)

---

## 📊 Other Performance Hotspots (Future Review)

### 1. O(n²) Ball Collision Loop
**Location:** `game_manager.gd:_detect_ball_collisions()`  
**Issue:** 16 balls = 120 collision checks per frame  
**Current status:** Acceptable for ≤10 balls  
**Future fix:** Use `Area3D` signals or spatial partitioning

### 2. Powerup Pickup Polling
**Location:** `powerup_system.gd:server_check_pickups()`  
**Issue:** Nested loops (items × balls) at 60Hz  
**Current status:** Moderate cost  
**Future fix:** Use `Area3D` body-entered signals (event-driven)

### 3. Bot AI Target Selection
**Location:** `bot_ai.gd:_bot_shoot()`  
**Issue:** N bots × M targets × 6 pockets = exponential cost  
**Current status:** High cost with 4+ bots  
**Future fix:** Cache target list, update every 0.2s

### 4. Network State Serialization
**Location:** `game_manager.gd:_server_broadcast_state()`  
**Issue:** Allocates 4 × N `PackedVector3Array` at 30Hz  
**Current status:** Necessary for sync  
**Future fix:** Reuse arrays, use object pooling

### 5. String Formatting in Hot Paths
**Location:** Multiple files (`_log()` calls)  
**Issue:** String allocation every frame when logging  
**Current status:** Low-medium cost  
**Future fix:** Wrap verbose logs in `if OS.is_debug_build()`

---

## 🔥 Frequent Initialization Hotspots (Web Performance Killers)

### 6. Per-Ball AudioStreamPlayer3D Creation ⭐⭐⭐
**Location:** `pool_ball.gd:_setup_sounds()` (lines 128-144)  
**Issue:** Every ball creates 3 `AudioStreamPlayer3D` nodes + generates audio waves
```gdscript
hit_ball_sound = AudioStreamPlayer3D.new()
hit_ball_sound.stream = _generate_ball_hit_sound()  # Procedural generation
hit_wall_sound = AudioStreamPlayer3D.new()
hit_wall_sound.stream = _generate_wall_hit_sound()
fall_sound = AudioStreamPlayer3D.new()
fall_sound.stream = _generate_fall_sound()
```
**Cost:** 16 balls × 3 sounds = **48 audio nodes** + procedural wave generation  
**Impact:** High on web (WebAudio API overhead, memory pressure)  
**Fix:** Pre-generate sounds once, share across balls, or use `AudioStreamPlayer` pool

---

### 7. Per-Effect Material/Node Allocation ⭐⭐⭐
**Location:** `powerup_system.gd` (lines 566-635)  
**Issue:** Every powerup activation creates new nodes + materials:
```gdscript
# Shield activation:
var sphere := MeshInstance3D.new()
var sph_mesh := SphereMesh.new()
var mat := StandardMaterial3D.new()

# Shockwave:
var ring := MeshInstance3D.new()
var torus := TorusMesh.new()
var ring_mat := StandardMaterial3D.new()

# Flash:
var flash := MeshInstance3D.new()
var flash_mesh := SphereMesh.new()
var flash_mat := StandardMaterial3D.new()
```
**Cost:** 3-5 powerups/minute × 3 nodes each = **15-25 allocations/minute**  
**Impact:** Moderate (GC pressure, draw call increases)  
**Fix:** Object pooling for effect nodes, shared materials

---

### 8. Per-Burst Material/Node Allocation ⭐⭐
**Location:** `comic_burst.gd:_ready()` (lines 30-58)  
**Issue:** Every burst creates:
```gdscript
_mat = StandardMaterial3D.new()
_mesh = ImmediateMesh.new()
_mesh_node = MeshInstance3D.new()
_label = Label3D.new()  # If text enabled
```
**Cost:** 10-20 bursts/minute × 3-4 nodes = **30-80 allocations/minute**  
**Impact:** High on web (GC + Label3D font rendering)  
**Fix:** Shared materials, object pooling, disable Label3D on web

---

### 9. Aim Visuals Material Creation ⭐
**Location:** `aim_visuals.gd:create()` (lines 31-56)  
**Issue:** Creates materials/meshes per game session:
```gdscript
bands_mat = StandardMaterial3D.new()
bands_mesh = ImmediateMesh.new()
bands_node = MeshInstance3D.new()
dots_mat = StandardMaterial3D.new()
dots_mesh = ImmediateMesh.new()
dots_node = MeshInstance3D.new()
```
**Cost:** Once per game (low)  
**Impact:** Low (acceptable)  
**Note:** Enemy aim lines (`get_or_create_enemy_line`) create per-enemy meshes — could add up with many players

---

### 10. Tween Creation Spam ⭐⭐
**Location:** Multiple files  
**Issue:** `create_tween()` called frequently:
- `game_hud.gd`: Kill feed slides, countdown pulses, toast fades
- `powerup_system.gd`: Shield sphere fade, shockwave expansion, flash
- `main_menu.gd`: UI transitions

```gdscript
var tween := gm.create_tween()
tween.tween_property(...)
```
**Cost:** 5-10 tweens/second during active gameplay  
**Impact:** Moderate (Tween objects allocate + process every frame)  
**Fix:** Reuse tweens where possible, use shader animations for simple effects

---

### 11. Kill Feed / Scoreboard UI Allocation ⭐
**Location:** `game_hud.gd:_add_feed_entry_styled()` (lines 520-545)  
**Issue:** Every kill creates new UI nodes:
```gdscript
var panel := PanelContainer.new()
var label := Label.new()
panel.add_child(label)
kill_feed.add_child(panel)
```
**Cost:** 10-20 kills/minute × 2 nodes = **20-40 UI allocations/minute**  
**Impact:** Low-moderate (UI nodes are lighter than 3D)  
**Fix:** Pool kill feed entries, reuse labels

---

### 12. Powerup Item Creation ⭐
**Location:** `powerup.gd:_create_item()` (lines 53-88)  
**Issue:** Every powerup spawn creates:
```gdscript
var item := PowerupItem.new()
var mesh_inst := MeshInstance3D.new()
var cyl := CylinderMesh.new()
var mat := StandardMaterial3D.new()
var label := Label3D.new()
```
**Cost:** 5-10 powerups/minute × 4-5 nodes = **20-50 allocations/minute**  
**Impact:** Moderate  
**Fix:** Object pooling for powerup items

---

## 🧪 Testing Checklist

After applying fixes:

- [ ] Test single-player web build (baseline)
- [ ] Test multiplayer with 2 players (host + 1 client)
- [ ] Test multiplayer with 4+ players
- [ ] Monitor FPS on client machines during:
  - Single ball-to-ball collision
  - Rapid collision sequences (multi-ball powerup)
  - Ball-to-wall collisions
- [ ] Monitor network sync rate (should stay near 30Hz)
- [ ] Check browser console for errors/warnings
- [ ] Verify burst effects still appear correctly
- [ ] Test on different browsers (Chrome, Firefox)

---

## 📊 In-Game Performance Metrics

The debug overlay now includes allocation tracking to help identify performance issues:

### Metrics Displayed

```
60 FPS | sync 30/s | draw 45 | mem 128MB (+0.15) | obj +3 | bursts 2 | spikes 0!
```

| Metric | What It Shows | Healthy Value | Warning Value |
|--------|---------------|---------------|---------------|
| **FPS** | Frames per second | 55-60 | <45 |
| **sync** | Network syncs/second | 28-32 | <20 or >40 |
| **draw** | Draw calls this frame | 30-80 | >150 |
| **mem** | Total memory (MB) | 80-200 | >300 |
| **(+/-)** | Memory delta (MB/frame) | ±0.05 | >0.3 or <-0.3 |
| **obj +N** | New nodes this frame | 0-2 | >5 |
| **bursts** | Active burst effects | 0-5 | >10 |
| **spikes** | Allocation spikes (10s) | 0 | >3 |

### How to Use

1. **Watch during collisions:**
   - `obj +N` should be 0-3 per collision (after fixes)
   - `bursts` should peak at 2-4 (not 10+)
   - `spikes` should stay at 0

2. **Compare before/after fixes:**
   - Before: `obj +15 | bursts 8 | spikes 5!`
   - After: `obj +2 | bursts 2 | spikes 0`

3. **Console logs:**
   - Large allocation spikes are logged:
     ```
     [PERF] ALLOC SPIKE: +25 nodes, +0.45 MB memory
     ```

### What to Look For

**Before fixes (duplicate detection):**
- `obj +10-20` during collisions (everyone spawns bursts)
- `bursts 5-15` (duplicate bursts on screen)
- `spikes 3-10` (frequent allocation bursts)
- `mem +0.3-0.8` (rapid memory growth)

**After fixes (server-only detection):**
- `obj +2-5` during collisions (single source)
- `bursts 1-4` (one burst per collision)
- `spikes 0-1` (rare allocation spikes)
- `mem +0.05-0.15` (stable memory)

---

## 📈 Expected Results

| Fix Combination | Remote Client FPS | Sync Rate | Draw Calls |
|----------------|-------------------|-----------|------------|
| No fixes (current) | ~20 FPS | ~40 | Spike 2X |
| Fix 1 only (server collision) | ~40-50 FPS | ~30 | Normal |
| Fix 1 + Fix 4 (no duplicate sounds) | ~50-60 FPS | ~30 | Normal |
| Fix 1 + Fix 4 + Fix 5 (web visuals) | ~55-60 FPS | ~30 | Reduced |

---

## 🔗 Related Files

- `scripts/game_manager.gd` — Collision detection, network sync
- `scripts/comic_burst.gd` — Visual effect implementation
- `scripts/network_manager.gd` — WebSocket multiplayer
- `scripts/powerup_system.gd` — Powerup pickup detection
- `scripts/bot_ai.gd` — Bot targeting logic
- `scripts/pool_ball.gd` — Ball physics, collision sounds

---

## 📝 Implementation Priority

### Phase 1: Critical (Multiplayer Web Performance)
1. **Fix 1:** Server-only collision detection (+20-30 FPS)
2. **Fix 4:** Disable duplicate sound playback (+10-20 FPS)
3. **Fix 5:** Web-specific visual optimizations (+5-10 FPS)

### Phase 2: High Impact (Allocation Reduction)
4. **Fix 6:** Pre-generate sounds once, share across balls
5. **Fix 7:** Object pooling for powerup effects
6. **Fix 8:** Shared materials for bursts

### Phase 3: Medium Impact (Polish)
7. **Fix 2:** Collision cooldowns (backup if issues persist)
8. **Fix 10:** Tween reuse / shader animations
9. **Fix 11:** Kill feed entry pooling

### Phase 4: Future Optimization
10. **Fix 3:** Local-only bursts (if still needed)
11. **Fix 9:** Enemy aim line optimization
12. **Fix 12:** Powerup item pooling
13. Bot AI caching, powerup polling → Area3D, network array reuse

---

## 🆘 Quick Reference Commands

```bash
# Check current FPS in Godot
# Enable: Project Settings → Debug → Settings → FPS Visibility → Visible

# Export web build
./export-web.sh

# View browser console (for errors)
# Chrome: F12 → Console
# Firefox: F12 → Console

# Monitor network sync
# In-game: Check debug overlay (if enabled)
```

---

**Last Updated:** February 19, 2026
**Status:** Phase 1 implemented — Fix 1, Fix 5, Fix 6 done; Fix 4 covered as side-effect of Fix 1

## ✅ Implemented

| Fix | Description | Status |
|-----|-------------|--------|
| Fix 1 | Server-only collision detection → broadcasts via `_rpc_game_collision_effect` RPC | ✅ Done |
| Fix 4 | No duplicate sounds — handled by Fix 1 (server broadcasts once, clients play once) | ✅ Done |
| Fix 5 | Label3D removed from ComicBurst | ✅ Done |
| Fix 6 | Shared audio streams (static cache in PoolBall — 3 WAVs generated once, shared) | ✅ Done |
| —   | Enemy aim line dirty flag — skip ImmediateMesh rebuild when dir/power/pos unchanged | ✅ Done |
| —   | Throttle `server_check_pickups()` to 20Hz (was 60Hz, O(items×balls) per tick) | ✅ Done |
| —   | Kill feed: replace idle 5s tween with `create_timer` (no tween processing during wait) | ✅ Done |
| —   | Label3D removed from PowerupItem (color+glow still distinguish powerup types) | ✅ Done |
| —   | ComicBurst: static material template + `duplicate()` (skip 5 property setters per burst) | ✅ Done |

### Key Changes Made
- `network_manager.gd`: Added `_rpc_game_collision_effect(pos, color, intensity, sound_slot, is_wall, sound_speed)` unreliable RPC
- `game_manager.gd`:
  - `_detect_ball_collisions()` now only runs in single-player (multiplayer uses server RPC)
  - `_on_server_ball_collision()` broadcasts burst+sound event to all peers after powerup checks
  - `_server_check_ball_collisions()` now also detects wall collisions and broadcasts them
  - Added `client_receive_collision_effect()` handler for the new RPC
- `pool_ball.gd`: `static var` cache for `AudioStreamWAV` — generated once on first ball, shared by all
