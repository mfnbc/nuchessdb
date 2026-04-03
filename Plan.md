# Plan

Purpose: build a reproducible chess database pipeline in Nushell with SQLite-backed storage, deterministic chess semantics, and separate LLM enrichment.

## P0

- Create the SQLite schema for games, positions, replay rows, stats, and annotations.
- Import PGNs from chess.com and lichess into raw game storage.
- Replay games into canonical positions using `nu_plugin_shakmaty`.
- Normalize positions with a hash that ignores move counters.
- Store raw FEN and canonical FEN together.
- Track per-position outcome counts by color.
- Track per-position outcome counts by platform-scoped player identity.
- Make `me` configurable per platform.
- Preserve raw PGN alongside parsed records.

## P1

- Add deterministic chess metadata for each position.
- Add engine evaluation storage.
- Add LLM commentary storage for positions and moves.
- Add replay validation queries.
- Add deduplication checks for repeated positions across games.
- Add Nushell queries for browsing games and positions.

## P2

- Add style analysis queries for strengths and weaknesses.
- Rank positions by frequency and result impact.
- Add prompts and prompt-version tracking for commentary.
- Add exports to NuON for compact reports and snapshots.
- Add training-oriented summaries for recurring mistakes.

## P3

- Add optional vector or semantic enrichment.
- Add richer dashboards and review reports.
- Add deeper cross-platform comparison views.
- Add optional support for future chess engines or analysis sources.

## Out of scope

- Treating LLM output as canonical chess truth.
- Using move counters as part of position identity.
- Replacing SQLite with flat files as the primary store.
