# nuchessdb

`nuchessdb` is a Nushell-first chess database and enrichment pipeline for importing games from chess.com and lichess, replaying them into canonical positions, and layering deterministic chess facts, engine evaluations, and LLM commentary on top.

## Core idea

- Use Nushell as the orchestration layer.
- Use SQLite as the durable game and position store.
- Use Nushell's built-in SQLite commands, not an external `sqlite3` dependency.
- Use `nu_plugin_shakmaty` for deterministic chess semantics.
- Use NuON for config, prompts, and small derived artifacts.
- Use `nuagent` for JSON enrichment and LLM-facing metadata.

## What it stores

- Raw games, including the original PGN.
- Canonical positions with a hash that ignores move counters.
- Replay rows linking games to positions and moves.
- Outcome stats by color and by platform-scoped player identity.
- Deterministic annotations like legal moves, checks, mobility, and engine evals.
- LLM commentary attached to positions or moves.

## Data flow

1. Download PGNs from chess.com or lichess.
2. Import the raw games into SQLite.
3. Replay each game into normalized positions.
4. Deduplicate positions by canonical key.
5. Compute deterministic chess metadata.
6. Add engine evaluations when available.
7. Add LLM commentary through `nuagent`.

## Import formats

- chess.com exports may arrive as JSON with embedded PGN strings.
- lichess exports may arrive as plain PGN.
- The importer accepts either shape and stores the raw game text first.
- `sync chesscom all <username>` downloads and imports every archive month.

## Principles

- Canonical position identity ignores move counters.
- Raw FEN is still stored for exact replay.
- Every position can have commentary.
- Deterministic facts and subjective commentary stay separate.
- Position stats should support both color-based and player-based outcomes.
- `me` is configured per platform, not assumed globally.

## Suggested workflow

- `http get` remote PGN exports.
- Parse and normalize with Nushell pipelines.
- Store in SQLite using tables for games, positions, replay rows, and annotations.
- Use NuON for import settings and prompt configuration.
- Query and report directly from Nushell.

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

## Related projects

- `nu_plugin_shakmaty`: deterministic FEN, move, and hash operations.
- `nuagent`: JSON enrichment and commentary generation.
