# Deadly Pool — Performance HUD Reference

The debug overlay appears in **debug builds only** (top-center of screen).
It updates every **1 second** and color-codes itself: 🟢 green = healthy, 🟡 yellow = warning, 🔴 red = problem.

```
{FPS} FPS | sync {N}/s [| gaps {N}!] [| ping {N}ms] | draw {N} | mem {N}MB [(+/-delta)] [| obj +/-N] [| bursts N] | frame N.Nms[!!]
proc {N}ms | phys {N}ms | gm {N}ms | balls {N}µs | tris {N}k | vmem {N}MB [| rings N]
```

---

## Line 1 — Per-second overview

| Metric | What it measures | Healthy | Warning | Red |
|---|---|---|---|---|
| **FPS** | Rendered frames per second | ≥ 60 | 30–49 | < 30 |
| **sync N/s** | State-sync packets received from server per second. Should match the server's broadcast rate (30 Hz while balls move, ~1 Hz idle). | 25–35/s moving, ~1/s idle | < 20/s while balls move | 0/s (disconnected) |
| **gaps N!** | Count of >100 ms gaps between consecutive sync packets in the last second. Each gap = at least one dropped or delayed packet. Hidden when 0. | 0 | 1–2 | > 2 |
| **ping Nms** | Round-trip time to server (measured via ping RPC every 3 s). Multiplayer only. | < 80 ms | 80–150 ms | > 150 ms |
| **draw N** | Total draw calls submitted to the GPU this frame. Each `ImmediateMesh`, ball, powerup item, and UI panel is at least one call. | < 80 | 80–150 | > 150 |
| **mem NMB** | Godot static heap memory (RAM). Includes scene nodes, GDScript objects, audio buffers. | < 100 MB | 100–200 MB | > 200 MB |
| **(+/- N.NN)** | Memory delta since last sample in MB. Positive = allocating; negative = GC freeing. Shown only when change > 0.1 MB. | ≈ 0, brief spikes on pickup/powerup fine | Sustained +0.5+/s | Sustained +2+/s |
| **obj +/-N** | Change in scene node count since last sample. Positive = nodes were created; negative = freed (GC). Shown only when nonzero. | ≈ 0 between events | Steady +2–5/s | +10+/s (hidden memory leak) |
| **bursts N** | Active `ComicBurst` effect nodes currently in the scene tree. Each burst auto-frees when its animation ends. | 0–3 | 4–8 | > 8 |
| **frame N.Nms** | How long `GameManager._process()` took this frame (wall-clock µs, not engine time). `!` = >16 ms (below 60 fps budget), `!!` = >50 ms (severe stutter). | < 8 ms | 8–16 ms | > 16 ms |
| **spikes N!** | Cumulative count of frames where `obj_delta > 5` (heavy node creation) in the last 10 seconds. Resets every 10 s. | 0 | 1–3 | > 3 |

---

## Line 2 — Frame budget breakdown

| Metric | What it measures | Healthy | Warning | Red |
|---|---|---|---|---|
| **proc Nms** | Time Godot spent in all `_process()` callbacks engine-wide (from `Performance.TIME_PROCESS`). | < 4 ms | 4–10 ms | > 10 ms |
| **phys Nms** | Time Godot + Jolt spent in all `_physics_process()` callbacks (from `Performance.TIME_PHYSICS_PROCESS`). | < 4 ms | 4–10 ms | > 10 ms |
| **gm Nms** | Time `GameManager._process()` specifically took (same as `frame` in line 1; repeated here for context alongside the other budget items). | < 4 ms | 4–10 ms | > 10 ms |
| **balls Nµs** | Sum of `PoolBall._process()` time across all active balls. Covers ring pulse animation, client position lerp, pocketing animation. | < 500 µs | 500–2000 µs | > 2000 µs |
| **tris Nk** | Primitives (triangles) submitted to GPU this frame, in thousands. Driven mainly by `ImmediateMesh` aim lines + ball meshes. | < 20k | 20–60k | > 60k |
| **vmem NMB** | GPU video memory in use (textures, mesh buffers). | < 100 MB | 100–300 MB | > 300 MB |
| **rings N** | Active `fx_ring` nodes in the scene (powerup arm-flash torus/sphere effects). Each auto-frees when its tween completes. | 0–2 | 3–6 | > 6 |

---

## Color coding

| Color | Trigger condition |
|---|---|
| 🟢 Green | FPS ≥ 50, ping ≤ 80 ms, gaps = 0, alloc spikes = 0 |
| 🟡 Yellow | FPS 30–49 **or** ping 80–150 ms **or** gaps > 0 **or** spikes > 0 |
| 🔴 Red | FPS < 30 **or** ping > 150 ms **or** gaps > 2 **or** spikes > 3 |

---

## Troubleshooting by symptom

### FPS drops / frame budget high

| `frame` value | Most likely cause | Where to look |
|---|---|---|
| `gm` high but `phys` normal | `GameManager._process()` is the bottleneck | `game_manager.gd` `_process()` — check `_detect_ball_collisions()`, `aim_visuals.update_enemy_lines()`, HUD update frequency |
| `phys` high | Jolt physics step is expensive | Too many active rigid bodies; check `pool_ball.gd` `_physics_process()` — progressive damping loop or extra `apply_central_impulse` calls |
| `balls` µs high | Ball visual updates are slow | `pool_ball.gd` `_process()` — ring pulse animation, client lerp. Check if `powerup_ring` update is running on headless server |
| `draw` count high | Too many draw calls | Each `ImmediateMesh.surface_begin/end` = 1+ draw call. `aim_visuals.gd` rebuilds lines every frame; `rings` / `bursts` count is another source |
| `tris` high | Heavy mesh geometry being rebuilt | `AimVisuals` lines and dots use `ImmediateMesh` — check enemy line count and dot count config |

---

### Sync rate low or dropping

| Symptom | Cause | Check |
|---|---|---|
| `sync` drops to ~0 while balls are moving | Server stopped broadcasting | Server-side `_physics_process` may be stalling; check `_sync_timer` and `SYNC_INTERVAL` in `game_manager.gd:7` |
| `sync` is ~1/s the whole time | Motion gate thinks balls have stopped | `_any_ball_moving` flag may be stuck false; check `ball.is_moving()` threshold (`GameConfig.ball_moving_threshold`) |
| `sync ~30/s` but `gaps > 0` | Packets arriving but some are dropped | Network congestion or unreliable UDP loss. Expected occasionally on bad connections; frequent = investigate host routing |
| `sync 0` + `gaps` climbing | Server or client socket died | Client will auto-return to menu after `SERVER_TIMEOUT = 5s` (`game_manager.gd:76`) |

---

### Memory growing over time

| Symptom | Cause | Check |
|---|---|---|
| `mem` slowly climbs every round | Nodes not freed between rounds | `powerup_system.reset()` frees items; check `active_traps`, `debuffed_balls` clear. Check `aim_visuals` `enemy_lines` dict is not leaking `MeshInstance3D` nodes |
| `obj +N` every second (outside events) | Steady node leak | Run with `$`[`SceneTree`] debug; common culprits: `ComicBurst` / `fx_ring` not calling `queue_free`, `ImmediateMesh` nodes created inside `_process()` without caching |
| `obj` spikes on ball collision | Expected | `ComicBurst.create()` allocates a node; it frees itself after its tween. Spike of 1–3 per collision is normal |
| `obj` spikes every spawn cycle | Powerup spawn leaking items | `powerup_system.gd server_spawn_powerup()` — verify items are freed on pickup via `item.queue_free()` in `on_picked_up()` |

---

### Ping high or unstable

| Symptom | Cause | Check |
|---|---|---|
| Ping consistently > 150 ms | Physical network distance or congestion | Nothing in code; routing issue or server geolocation |
| Ping occasionally spikes then recovers | Server GC stall or physics spike | Cross-reference with `phys` value; if phys spikes at same time as ping spike, server `_physics_process` is blocking the ENet poll |
| Ping shows `-1` or not shown | Single-player mode, or ping RPC not yet returned | Normal; appears after first 3-second cycle |

---

### Draw calls or VRAM high

| Symptom | Cause | Check |
|---|---|---|
| `draw` high even with 0 effects | Base scene draw calls are expensive | Count active balls (4 × meshes) + arena mesh + aim lines. Each `ImmediateMesh` with multiple `surface_begin` calls = multiple draw calls |
| `tris` high | Large meshes or excessive aim line resolution | `aim_visuals.gd` dot count (6 dots), enemy line steps (8 steps). Reduce in `AimVisuals` constants if needed |
| `vmem` growing | Textures or render buffers not released | Primarily a concern on web/mobile with Compatibility renderer; use Godot remote debugger's resource tab to inspect |
| `rings` > 0 for a long time | `fx_ring` tween not freeing node | Check `_spawn_arm_visual()` in `powerup_system.gd` — `.chain().tween_callback(node.queue_free)` must fire |

---

## Quick reference thresholds (green zone)

```
FPS       ≥ 60
sync      25–35/s  (while balls moving)
gaps      0
ping      < 80 ms
draw      < 80
mem       < 100 MB
mem delta ≈ 0 between events
obj delta 0 between events
frame     < 8 ms
proc      < 4 ms
phys      < 4 ms
tris      < 20k
vmem      < 100 MB
rings     0 at rest
bursts    0 at rest
```
