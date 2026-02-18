# Enhanced Game Logging

This document describes the logging improvements added to provide better visibility into game events for debugging and analysis.

## Summary

Added comprehensive logging throughout the game lifecycle without affecting gameplay mechanics or performance. All logs are sent to `NetworkManager.room_log()` and visible in the admin dashboard at `http://<server>:8081/logs`.

## New Log Events

### Launch & Input Validation

**Successful launches:**
```
[12345.678] [ABCDE] LAUNCH ball=0 dir=(0.71,0.71) power=15.2 mass=0.60 pos=(-3.00,-3.00) spd_after=15.3
```

**Rejected launches:**
```
[12345.678] [ABCDE] LAUNCH_REJECTED slot=0 peer=2 reason=NOT_OWNER
[12345.678] [ABCDE] LAUNCH_REJECTED slot=0 peer=2 reason=BALL_MOVING spd=5.23
[12345.678] [ABCDE] LAUNCH_REJECTED slot=0 peer=2 reason=COOLDOWN_ACTIVE remaining=0.25s
[12345.678] [ABCDE] LAUNCH_REJECTED slot=0 peer=2 reason=INVALID_VALUES
[12345.678] [ABCDE] LAUNCH_REJECTED slot=0 peer=2 reason=INVALID_DIRECTION
```

### Bot AI Decisions

**Bot decision trail:**
```
[12346.234] [ABCDE] BOT_DECIDE slot=2 shot=3 targets=[0,1] chosen=1 scatter=0.12 power=11.5 delay=1.8
[12346.234] [ABCDE] BOT_SHOOT slot=2 NO_TARGETS
[12346.234] [ABCDE] BOT_SHOOT slot=2 target=0 TOO_CLOSE
```

Fields:
- `shot` - Sequential shot number for this bot
- `targets` - Available enemy balls
- `chosen` - Selected target slot
- `scatter` - Random aim deviation (radians)
- `power` - Launch power percentage
- `delay` - Decision delay before shooting

### Powerup Lifecycle

**Spawn:**
```
[12350.001] [ABCDE] POWERUP_SPAWN id=5 type=SPEED_BOOST pos=(3.2,-1.5) attempts=3 table_count=1/2
[12350.001] [ABCDE] POWERUP_SPAWN_FAILED type=HEAVY_BALL attempts=20 table_count=2/2
```

**Pickup:**
```
[12351.500] [ABCDE] POWERUP_PICKUP ball=0 type=SPEED_BOOST ball_spd=8.5 pos=(2.1,1.3) dist=0.95
```

**Consumption:**
```
[12352.100] [ABCDE] POWERUP_CONSUME ball=0 type=HEAVY_BALL mass_before=0.60 mass_after=1.20
[12352.100] [ABCDE] POWERUP_CONSUME ball=0 type=SPEED_BOOST power_before=15.0 power_after=24.0
[12352.100] [ABCDE] POWERUP_CONSUME ball=0 type=MAGNET nearest=1 dist=3.2 blend=0.25 dir_change=(0.50,0.50)->(0.58,0.42)
[12352.100] [ABCDE] POWERUP_CONSUME ball=0 type=MAGNET NO_TARGET
[12352.100] [ABCDE] POWERUP_CONSUME ball=0 type=SHOCKWAVE armed
[12352.100] [ABCDE] POWERUP_CONSUME ball=0 type=ANCHOR armed
```

### Collision & Physics

**Ball-to-ball collision:**
```
[12355.500] [ABCDE] BALL_COLLISION a=0 b=1 rel_vel=12.5 dist=0.70
```

**Shockwave effect:**
```
[12355.600] [ABCDE] SHOCKWAVE ball=0 pos=(1.5,2.3) affected=2
```

**Anchor effect:**
```
[12356.100] [ABCDE] ANCHOR ball=0 mass_before=0.60 mass_after=100.00 duration=0.6s
```

### Performance Metrics

**Server performance (every 5 seconds):**
```
[12360.000] [ABCDE] PERF ticks=300 avg=0.65ms max=2.10ms rate=60.0Hz
```

Fields:
- `ticks` - Number of physics ticks in the sampling period
- `avg` - Average tick duration (target: <16ms for 60Hz)
- `max` - Worst-case tick duration
- `rate` - Effective tick rate

### Game State Transitions

**Game start:**
```
[12300.000] [ABCDE] GAME_START players=3 slots=[0, 1, 2] bots=1
[12300.000] [SOLO] GAME_START single_player slots=[0, 1, 2, 3] bots=3
```

**Game over:**
```
[12600.500] [ABCDE] GAME_OVER winner=Red (Player 1) duration=300.5s
[12600.500] [ABCDE] GAME_OVER draw duration=285.2s
```

**Room cleanup:**
```
[12605.500] [SERVER] Room ABCDE cleaned up and archived (duration=305.2s, players=3)
```

### Existing Logs (Enhanced)

**STATE logs** now include bot count in GAME_START.

**POCKET logs** now include velocity information:
```
[12400.200] [ABCDE] POCKET ball=1 pos=(9.8,0.5,-9.8) pocket=(10.0,-10.0) vel=(8.5,0.2,12.3)
```

**ELIMINATED logs** now include position:
```
[12400.700] [ABCDE] ELIMINATED ball=1 pos=(9.8,-1.5,-9.8) alive_left=2
```

## Log Format

```
[TIMESTAMP] [ROOM_CODE] EVENT_TYPE key=value key=value ...
```

- **TIMESTAMP**: Unix timestamp in seconds with milliseconds
- **ROOM_CODE**: 5-character room identifier (or SOLO for single-player)
- **EVENT_TYPE**: Categorized event name
- **key=value**: Structured data fields

## Viewing Logs

### Admin Dashboard
Visit `http://<server>:8081/logs` to view real-time logs with:
- Room filtering (active and archived)
- Auto-refresh (2s interval)
- Log level filtering (hide STATE lines)
- Auto-scroll toggle

### API Access
```bash
# All rooms
curl http://localhost:8081/api/logs

# Specific room
curl http://localhost:8081/api/logs?room=ABCDE
```

### Server Console
Logs are also printed to stdout with room prefix:
```
[ABCDE] LAUNCH ball=0 dir=(0.71,0.71) power=15.2 ...
```

## Performance Impact

Minimal performance impact:
- String formatting only happens when log is actually written
- No logging in hot paths (ball physics interpolation, rendering)
- Performance metrics use simple arrays with fixed max size (60 samples)
- Log buffer limited to 200 lines per room

## Safety Features

All logging code includes defensive checks:
- Null checks before accessing ball/room objects
- `has_method()` checks before calling game_manager._log()
- Try-catch equivalent via GDScript's error handling
- No logging that could affect game state or timing

## Future Enhancements

Potential additions for future debugging:
- Client drift severity classification (MINOR/MODERATE/SEVERE)
- Sync interval monitoring for network issues
- Scene load time tracking
- Bot AI target selection heatmaps
- Powerup win rate correlation
