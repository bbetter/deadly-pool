# Deadly Pool - Game Design Document

## Overview

Deadly Pool is a multiplayer physics-based party game. Players each control a pool ball on a billiard table. The goal: knock your opponents into pockets. Last ball standing wins.

## Core Loop

1. Aim by clicking and dragging your ball (slingshot style)
2. Release to launch — direction is opposite the drag
3. Collide with opponents to push them toward pockets
4. Pick up powerups for an edge
5. Survive — last player alive wins

## Controls

- **Click + Drag on your ball**: Aim and set power (farther drag = more power)
- **Release**: Launch ball in the opposite direction of the drag
- **Spacebar**: Activate held powerup (Bomb or Shield)

Power scales linearly with drag distance (up to 5 units = 100%). A pulsing glow on your ball indicates it's ready to launch (stopped and alive).

## Arena

20x20 unit billiard table with 6 pockets:
- 4 corner pockets (radius 1.3)
- 2 mid-side pockets (radius 1.0)

Walls are green cushion rails with gaps at pocket locations. Balls bounce off walls with 0.8 elasticity. Any ball that falls below Y=-2.0 (off the table edge or through a pocket) is eliminated.

Spawn positions: four corners at (+-3, +-3), one per player.

## Ball Physics

| Property | Value |
|---|---|
| Mass | 0.6 kg |
| Radius | 0.35 |
| Friction | 0.1 |
| Bounce | 0.8 |
| Linear Damping | 0.5 |
| Max Launch Power | 18.0 |
| Min Launch Power | 0.5 |

Balls use progressive damping: below 1.2 m/s, extra drag ramps up (4x factor) so balls coast to a natural stop rather than crawling forever. Hard stop at 0.03 m/s.

## Powerups

Powerups spawn on the table every 8-14 seconds (max 3 on table). Roll over one to pick it up. You can only hold one powerup at a time — you must use it before picking up another. All powerups require arming with Space before they take effect. When armed, the powerup's icon floats above your ball. Armed powerups expire after 6 seconds if not triggered — bomb auto-explodes, shield and speed boost are wasted.

### Speed Boost -- cyan
Press Space to arm. On your next launch, 1.5x power multiplier is applied and the powerup is consumed. Expires after 6 seconds if you don't launch.

### Bomb -- orange-red
Press Space to arm. On your next collision with another ball, it explodes — shockwave pushes all nearby balls outward (force 12.0, radius 5.5). Auto-explodes after 6 seconds.

### Shield -- blue
Press Space to arm. For 3 seconds (or until hit), your ball is anchored (mass 100 kg). When struck, the attacker is knocked back with force 8.0 and your shield is consumed. Expires after 6 seconds if not hit.

Powerup items appear as glowing, rotating cylinders with emoji symbols floating above them.

## Visuals

### Slingshot Aiming
When dragging, two rubber-band lines stretch from the ball to the cursor in a V-shape. Width and opacity scale with power. Six trajectory dots extend forward from the ball showing the launch direction, spaced further apart at higher power.

### Enemy Aim Lines
While other players aim, a dashed line shows their aim direction and approximate power (visible to all players, 20Hz updates).

### Collision Effects
Comic-style starbursts appear at collision points with random impact words ("POW", "BAM", "WHAM"). Size and intensity scale with collision velocity. Wall hits get a subtler tan-colored burst.

### Pocket Animation
Pocketed balls spiral toward the pocket center, shrink from 1.0 to 0.3 scale, and sink below the table over 0.5 seconds.

### Ball Glow
Your own ball pulses with a soft emission glow when it's ready to launch, using your player color.

### HUD
- **Power bar**: Bottom-center, green-to-orange fill showing launch power
- **Kill feed**: Top-right, shows eliminations and disconnects
- **Scoreboard**: Top-left, player list with win counts, elimination status, and held powerups
- **Powerup indicator**: Shows your current powerup with activation hint

## Sound

All sounds are procedurally generated (no audio files):
- **Ball-ball hit**: Sharp high-frequency crack (3200+4800 Hz) with noise burst attack
- **Wall hit**: Lower thud (800+1200 Hz) with slower decay
- **Pocket fall**: Descending pitch sweep (600 to 120 Hz) over 0.5 seconds

Volume scales with impact velocity. Pitch is randomized per hit for variety.

## Game Modes

### Single Player
Play against 1-3 AI bots locally. No server needed. Bots aim at random enemies with configurable accuracy (+-20 degrees scatter) and shoot every 1-2.5 seconds.

### Multiplayer
Server-authoritative architecture. The server runs full Jolt physics; clients are visual puppets receiving 60Hz state updates. Players connect via IP, create/join rooms with 5-character codes, and play with up to 4 players (humans + bots). Room creator can add/remove bots in the lobby.

Disconnected players get a 3-second grace period, then their ball is eliminated as a "ghost ball."

## Player Colors

| Slot | Color | Name |
|---|---|---|
| 0 | Red | Red |
| 1 | Blue | Blue |
| 2 | Yellow | Yellow |
| 3 | Green | Green |

## Win Condition

When only one player remains alive, they win. If the last two players are eliminated simultaneously, it's a draw. Wins are tracked per room for multi-round play.

## Menu Flow

```
Main Menu
  -> PLAY SOLO (select bot count, start)
  -> PLAY ONLINE
       -> Server IP
       -> CREATE ROOM -> Lobby (host controls)
       -> JOIN ROOM -> Enter code -> Lobby
            Lobby: player list, add/remove bots, START GAME
```

## Admin Dashboard

Server exposes an HTTP dashboard (port 8081) with:
- **/** — Server status, uptime, active rooms, player list
- **/logs** — Per-room physics and event logs (active + archived)
- **/tuning** — Live physics parameter editor (all GameConfig values)
