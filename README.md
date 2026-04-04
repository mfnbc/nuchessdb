# nuchessdb

`nuchessdb` is a Nushell-first chess database and enrichment pipeline for importing games from chess.com and lichess, replaying them into canonical positions, and layering deterministic chess facts, critter decomposed evaluations, engine-specific dynamic move analysis, engine evaluations, and LLM commentary on top.

## Core idea

- Use Nushell as the orchestration layer.
- Use SQLite as the durable game and position store.
- Use Nushell's built-in SQLite commands, not an external `sqlite3` dependency.
- Use `nu_plugin_shakmaty` for deterministic chess semantics.
- Use `critter-eval` as the official decomposed evaluation backend.
- Use engine name plus ELO tuning for dynamic move-play analysis.
- Use NuON for config, prompts, and small derived artifacts.
- Use LLM tooling for commentary and enrichment (planned).

## What it stores

- Raw games, including the original PGN.
- Canonical positions with a hash that ignores move counters.
- Replay rows linking games to positions and moves.
- Outcome stats by color and by platform-scoped player identity.
- Deterministic annotations like legal moves, checks, mobility, and engine evals.
- Critter evaluation vectors stored per position.
- Dynamic move ladders stored per position and engine profile.
- LLM commentary attached to positions or moves.

## Data flow

1. Download PGNs from chess.com or lichess.
2. Import the raw games into SQLite.
3. Replay each game into normalized positions.
4. Deduplicate positions by canonical key.
5. Compute deterministic chess metadata.
6. Add critter decomposed evaluations and dynamic move ladders when available.
7. Add LLM commentary through `nuagent`.

## Import formats

- chess.com exports may arrive as JSON with embedded PGN strings.
- lichess exports may arrive as plain PGN.
- The importer accepts either shape and stores the raw game text first.
- `nu_plugin_shakmaty` now exposes `shakmaty pgn-to-batch` for one structured batch record per PGN file.
- `sync chesscom all <username>` downloads and imports every archive month.
- `sync chesscom all <username>` uses a small NuON checkpoint in `./tmp/` to skip completed archives.
- New positions are queued for critter enrichment in popularity order so the most common positions are evaluated first.

## Principles

- Canonical position identity ignores move counters.
- Raw FEN is still stored for exact replay.
- Every position can have commentary.
- Deterministic facts and subjective commentary stay separate.
- Position stats should support both color-based and player-based outcomes.
- `me` is configured per platform, not assumed globally.
- Critter evals are stored separately from engine evals.
- Dynamic runs are stored separately from static critter evals.

## Suggested workflow

- `http get` remote PGN exports.
- Parse and normalize with Nushell pipelines.
- Store in SQLite using tables for games, positions, replay rows, and annotations.
- Use the structured batch record from `shakmaty pgn-to-batch` as the import boundary.
- Store critter decomposition results in a dedicated queue and eval table.
- Store engine-specific dynamic profiles and ranked move outputs in separate tables keyed by zobrist.
- Use NuON for import settings and prompt configuration.
- Query and report directly from Nushell.

## Prerequisites

Install these separately:

- Nushell
- `nu_plugin_shakmaty`
- `critter-eval`
- Your configured engine binary for dynamic analysis

## User Pipeline

1. Install Nushell, `nu_plugin_shakmaty`, `critter-eval`, and your configured engine binary.
2. Edit `config/nuchessdb.nuon` with your database path, your chess.com username, `enrichment.critter.binary` if needed, and `enrichment.dynamic.engine_name` plus `enrichment.dynamic.elo_tune` if you want dynamic move analysis.
3. Initialize the database:

```bash
./main.nu init
```

4. Ingest your chess.com data:

```bash
./main.nu sync chesscom all <your-username>
```

5. Queue critter decompositions for the most frequent positions:

```bash
./main.nu critter-enqueue
```

6. Run critter enrichment:

```bash
./main.nu critter-eval 50
```

7. Check critter queue progress:

```bash
./main.nu critter-qstats
./main.nu critter-queue 20
```

8. Optional: queue and run dynamic engine analysis:

```bash
./main.nu dynamic-enqueue
./main.nu dynamic-eval 20
```

## Direct DB Queries

Use Nushell directly against the SQLite file for ad hoc inspection:

```nu
open ./data/nuchessdb.sqlite | query db "SELECT COUNT(*) AS games FROM games"
open ./data/nuchessdb.sqlite | query db "SELECT platform, source_game_id, result FROM games ORDER BY id DESC LIMIT 10"
open ./data/nuchessdb.sqlite | query db "SELECT canonical_hash, canonical_fen FROM positions ORDER BY id DESC LIMIT 5"
```

## Fun Queries

```nu
open ./data/nuchessdb.sqlite | query db "SELECT opponent, COUNT(*) AS games FROM (SELECT CASE WHEN g.white_account_id = m.id THEN b.username ELSE w.username END AS opponent FROM games g JOIN accounts m ON m.is_me = 1 AND (g.white_account_id = m.id OR g.black_account_id = m.id) LEFT JOIN accounts w ON w.id = g.white_account_id LEFT JOIN accounts b ON b.id = g.black_account_id) GROUP BY opponent ORDER BY games DESC LIMIT 10"
open ./data/nuchessdb.sqlite | query db "SELECT opponent, AVG(opponent_elo) AS avg_elo FROM (SELECT CASE WHEN g.white_account_id = m.id THEN b.username ELSE w.username END AS opponent, CASE WHEN g.white_account_id = m.id THEN g.black_elo ELSE g.white_elo END AS opponent_elo FROM games g JOIN accounts m ON m.is_me = 1 AND (g.white_account_id = m.id OR g.black_account_id = m.id) LEFT JOIN accounts w ON w.id = g.white_account_id LEFT JOIN accounts b ON b.id = g.black_account_id) WHERE opponent_elo IS NOT NULL GROUP BY opponent ORDER BY avg_elo DESC LIMIT 50"
```

## Benchmark

```bash
./main.nu bench chesscom all <your-username>
```

## Enrichment Queue

Queue the most-played positions first:

```bash
./main.nu enqueue 100
./main.nu queue 20
```

## Engine Eval

Configure your engine in `config/nuchessdb.nuon`, then run:

```bash
./main.nu eval 20
./main.nu engine 20
./main.nu qstats
```

The engine config supports a binary path plus model/depth knobs, so you can point it at Stockfish or lc0-style setups later.

## Critter Eval

Build `critter-eval` next to this repo, or set `enrichment.critter.binary` in `config/nuchessdb.nuon`.

```bash
./main.nu critter-enqueue
./main.nu critter-eval 20
./main.nu critter-queue 20
./main.nu critter-qstats
```

## Related projects

- `nu_plugin_shakmaty`: deterministic FEN, move, and hash operations.
- `critter-eval`: decomposed evaluation backend for position enrichment.
- `nuagent`: JSON enrichment and commentary generation (planned).

## Dynamic Analysis

Dynamic move analysis is stored separately from static quantification.
Each run is keyed by the position zobrist plus an engine profile with only `engine_name` and `elo_tune`, and the top 5 moves are stored as ranked rows for later comparison.
