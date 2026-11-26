# Jax Chess Scripts

Roblox/Luau helper scripts for two chess experiences:

- `RoChess.lua` — helper for **RoChess!** (place `130878180532794`)
- `chessduels.lua` — helper for **Chess Duels** (place `89083628291452`)
- `WordleHelper.lua` — Wordle solver UI using APIVerve Wordle Helper and oanor Wordle API

## Features

Both scripts provide engine analysis through `stockfish.online`, a depth selector,
mate display, board arrows/markings, manual and automatic suggestions, and
settings persistence through Real's filesystem.

`chessduels.lua` additionally has bot/online join controls, human-timing auto
play, and a puzzle Auto Next toggle.

## Teleport persistence

Each script registers a reload chunk with `queueonteleport(source)`. The queued
chunk fetches the newest script directly from this repository's raw GitHub URL,
so it does not depend on a local file surviving the teleport. Aliases
`queue_on_teleport` and `queueteleport` are used when available, and there is a
`fluxus.queue_on_teleport(source)` fallback.

Push changes to `main` before relying on a teleport, since the queued chunk
always reads from GitHub raw.

## AutoExec (optional)

`AutoExec/chessduels.luau` is a guarded loader that starts `chessduels.lua`
when Real injects into a new Roblox session. It only acts in Chess Duels and
skips if the script is already running.

## Wordle Helper

`WordleHelper.lua` takes green (`A1,E5`), yellow (`R`) and gray (`STLN`) clues,
or oanor `guess:pattern` pairs, and returns ranked next guesses. Source can be
`apiverve`, `oanor`, or `auto` (oanor first, APIVerve fallback). Keys are read
from `WordleHelper/settings.json` in Real's workspace; never commit real keys.
An example with placeholders is in `examples/wordlehelper-settings.json`.

## Settings

`examples/chessduels-settings.json` shows the persisted settings format. The
live file is written to Real's workspace at `chessduels/settings.json`.
