# Jax Chess Scripts

Roblox/Luau helper scripts for chess, Wordle and word-rarity experiences:

- `RoChess.lua` — helper for **RoChess!** (place `130878180532794`)
- `chessduels.lua` — helper for **Chess Duels** (place `89083628291452`)
- `WordleHelper.lua` — automatic Wordie board solver (APIVerve Wordle Helper)
- `RarestHelper.lua` — prompt solver for **Guess the rarest word** (place `95246966728635`)

## Features

The chess scripts provide engine analysis through `stockfish.online`, a depth selector,
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

`WordleHelper.lua` reads the Wordie board directly (`WordieTileState` on each
tile), solves through the APIVerve Wordle Helper, and types the suggested word
with the game's own keyboard handler. It handles fresh boards with no clues too.
The APIVerve key is read from `WordleHelper/settings.json` in Real's workspace;
never commit real keys. `examples/wordlehelper-settings.json` is a placeholder.

## Rarest Helper

`RarestHelper.lua` watches the current prompt in **Guess the rarest word** and,
with Auto Suggest on, asks the free Kilo AI Gateway for five real answers ordered
from least known to most known. The panel marks the least-known answer; clicking
a row fills the game's answer box. No API key is needed — anonymous free models
are limited to 200 requests/hour per IP. Settings live in
`RarestHelper/settings.json` (see `examples/raresthelper-settings.json`).

## RoChess key gate

`RoChess.lua` starts behind a key gate. Deploy `google-apps-script/Code.gs` as a
Google Apps Script web app (Extensions → Apps Script → Deploy → New deployment →
Web app, execute as you, access "Anyone"), then paste the `/exec` URL into the
gate. The service generates `Criex_` keys with six random letters, numbers or
signs and keeps one active key in Script Properties. Run `installTrigger()` once
from the Apps Script editor to rotate that key every 12 hours; `?action=generate`
returns the current key until rotation. The gate also accepts the literal key
`ForTesters` and remembers an accepted key in `RoChess/settings.json`.

Endpoints: `?action=generate`, `?action=validate&key=...`, `?action=current`,
`?action=rotate`.

## Vendored UI

`vendor/WindUI.lua` is a pinned copy of WindUI v1.6.65 (MIT — see
`vendor/WindUI-LICENSE.txt`). All four helpers load it from this repository's
raw URL instead of the upstream release, so it stays available and updates are
controlled here.

## Settings

`examples/chessduels-settings.json` shows the persisted settings format. The
live file is written to Real's workspace at `chessduels/settings.json`.
