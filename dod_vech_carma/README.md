# Carma (dod_vech_carma)

A vehicle-kill game mode for Day of Defeat: Source. Requires the Driveable Vehicles plugin.

## For Players

Carma starts automatically a few seconds after each round begins. The goal is simple: be the first to reach the kill target by running over bots with a vehicle.

A scoreboard menu appears on your screen and refreshes every few seconds, showing the current standings, the kill goal, and how long the round has been running. If you die, you lose one kill from your score, so staying alive matters as much as racking up kills.

When someone reaches the kill goal, they're announced as the winner, fireworks go off, and the round restarts shortly after so a new game can begin.

## For Server Operators

Carma runs as a separate plugin alongside the Driveable Vehicles plugin and does not require any changes to existing vehicle configs or maps.

### Requirements

- SourceMod 1.13+
- Driveable Vehicles plugin (vehicles.smx) loaded and working

### Installation

Drop `dod_vech_carma.smx` into `addons/sourcemod/plugins/` and either load it with `sm plugins load dod_vech_carma` or restart the map. A config file will be generated automatically at `cfg/sourcemod/dod_vech_carma.cfg` on first load.

### Configuration

All settings are server-side ConVars, editable in the generated config file or via `rcon`/server console.

| ConVar | Default | Description |
|---|---|---|
| `sm_dvc_kill_goal` | 10 | Kills required to win |
| `sm_dvc_fireworks_timeout` | 10 | How long fireworks run after a win (seconds) |
| `sm_dvc_fireworks_sound` | 1 | Play sounds with fireworks (0/1) |
| `sm_dvc_debug` | 0 | Enables verbose debug logging to chat (0/1) |
| `sm_dvc_version` | (read-only) | Current plugin version, public-facing |

**Important:** if you update the plugin and new ConVars are added, delete the existing `dod_vech_carma.cfg` and let it regenerate. Otherwise the old config will override new defaults.

### How a round works

1. Round starts, a short countdown begins.
2. Carma announces the game is live and the kill goal.
3. Vehicle kills on bots count toward the killer's score; a human player dying loses one kill.
4. First to the kill goal wins. The win is announced, logged for HLStatsX, and fireworks play.
5. The DoDS round restarts automatically once fireworks finish, and a new Carma round begins.

### Notes

- This plugin is built specifically for Day of Defeat: Source and assumes DoDS-specific events and behavior; it is not intended for HL2DM, even though the underlying vehicle plugin supports both.
- Map records (fastest win time) are tracked per map and reset when the map changes.
