# nuchessdb — SQL Query Primer

A compact reference for writing queries against `nuchessdb.sqlite`. Covers the schema, relationships, and the non-obvious conventions that every query needs to know.

---

## Database connection (Nushell)

```nu
let db = (open ./data/nuchessdb.sqlite)
$db | query db "SELECT ..."
```

Pass the SQLite value, not a path string. Each `query db` call is its own connection/transaction (~10–16 ms), so batch multiple statements into one call where possible.

---

## Schema at a glance

```
accounts          — players (platform + username); is_me = 1 for the profiled player
games             — one row per game; white/black account IDs, result, ELO, PGN
positions         — canonical chess positions (one row per unique board state)
game_positions    — every ply of every game; links game → position before/after → mover
position_color_stats   — win/draw/loss counts across ALL players for a position
position_player_stats  — win/draw/loss counts for one specific account at a position
position_critter_evals — decomposed critter-style evaluation per position
position_engine_evals  — static engine eval per position (Stockfish / lc0)
position_dynamic_runs  — dynamic move-ladder eval per position
annotations            — LLM or manual notes; not written by any current pipeline stage
```

---

## Key conventions

### 1. The profiled player — `accounts.is_me = 1`

There is one row in `accounts` with `is_me = 1` per platform. Every player-specific query must filter through this:

```sql
JOIN accounts m ON m.is_me = 1
```

Multiple platforms can have `is_me = 1` rows (one per platform). If your query covers a single platform, add `AND m.platform = 'chesscom'`.

### 2. Determining color in a game

`games` stores `white_account_id` and `black_account_id`. To find which color the profiled player had:

```sql
CASE WHEN g.white_account_id = m.id THEN 'white' ELSE 'black' END AS my_color
```

### 3. Win/draw/loss from `games.result`

`result` is a string literal — always one of:
- `'1-0'` — White wins
- `'0-1'` — Black wins
- `'1/2-1/2'` — Draw

To count a win for the profiled player:

```sql
CASE
  WHEN g.white_account_id = m.id AND g.result = '1-0' THEN 1
  WHEN g.black_account_id = m.id AND g.result = '0-1' THEN 1
  ELSE 0
END
```

### 4. Position identity — `canonical_hash` vs `position_id`

- `positions.id` — integer primary key, used for FK relationships everywhere in the DB
- `positions.canonical_hash` — Zobrist hash string; used as the FK in queue/run tables (`position_dynamic_queue`, `position_dynamic_runs`)
- `positions.canonical_fen` — full 6-field FEN string

Use `positions.id` when joining `position_player_stats`, `position_critter_evals`, `position_engine_evals`.
Use `positions.canonical_hash` when joining queue/run tables.

### 5. FEN matching with `data/eco.json`

`canonical_fen` is a 6-field FEN (board + side + castling + en-passant + halfmove + fullmove). The ECO JSON uses 4-field FENs (strips halfmove and fullmove). The strip is done in Nushell after the query:

```nu
let fen4 = ($row.canonical_fen | split row " " | first 4 | str join " ")
```

There is no ECO column in the DB — ECO classification always happens in Nushell via `eco-classify` or a manual `each` block.

### 6. `position_player_stats` vs `position_color_stats`

| Table | What it counts |
|---|---|
| `position_player_stats` | Outcomes for one specific account at a position |
| `position_color_stats` | White wins / draws / black wins across ALL players at a position |

For "how do I do at this position" queries, always use `position_player_stats` joined through `accounts.is_me = 1`.

### 7. Critter eval JSON columns

`position_critter_evals` has six columns that hold JSON objects for decomposed eval groups:

| Column | Eval group |
|---|---|
| `material_json` | material balance |
| `pawn_structure_json` | pawn structure |
| `piece_activity_json` | piece activity |
| `king_safety_json` | king safety |
| `passed_pawns_json` | passed pawns |
| `development_json` | development |

Each JSON object has the shape `{"mg": N, "eg": N, "blended": N, "terms": {...}}` (mg/eg/blended are integers in centipawns; `terms` is an object of named sub-scores that make up the group total — keys vary per group).

`vector_features` and `strategic` groups are only available inside `analysis_json` — they are not broken out into dedicated columns.

Extract a blended score directly in SQL:

```sql
CAST(json_extract(piece_activity_json, '$.blended') AS INTEGER) AS activity_blended
```

`final_score` is the pre-computed sum of all groups plus modifiers. Positive = White advantage, negative = Black advantage.

### 8. Time control classification

`games.time_control` is a raw string from the platform (e.g. `"600"`, `"180+2"`, `"1/259200"`). The reports module classifies it into bullet / blitz / rapid / classical / unknown at query time using `CASE` on total seconds. If you need this in SQL:

```sql
CASE
  WHEN CAST(SUBSTR(time_control, 1, INSTR(time_control||'+', '+')-1) AS INTEGER) < 180  THEN 'bullet'
  WHEN CAST(SUBSTR(time_control, 1, INSTR(time_control||'+', '+')-1) AS INTEGER) < 600  THEN 'blitz'
  WHEN CAST(SUBSTR(time_control, 1, INSTR(time_control||'+', '+')-1) AS INTEGER) < 3600 THEN 'rapid'
  WHEN CAST(SUBSTR(time_control, 1, INSTR(time_control||'+', '+')-1) AS INTEGER) >= 1800 THEN 'classical'
  ELSE 'unknown'
END
```

`time_control` can be NULL — wrap in `COALESCE(time_control, '')` before parsing if needed.

---

## Core query patterns

### My overall win rate

```sql
SELECT
  COUNT(*) AS games,
  SUM(CASE
    WHEN g.white_account_id = m.id AND g.result = '1-0' THEN 1
    WHEN g.black_account_id = m.id AND g.result = '0-1' THEN 1
    ELSE 0
  END) AS wins,
  SUM(CASE WHEN g.result = '1/2-1/2' THEN 1 ELSE 0 END) AS draws,
  ROUND(100.0 * SUM(CASE
    WHEN g.white_account_id = m.id AND g.result = '1-0' THEN 1
    WHEN g.black_account_id = m.id AND g.result = '0-1' THEN 1
    ELSE 0
  END) / COUNT(*), 1) AS win_pct
FROM games g
JOIN accounts m ON m.is_me = 1
  AND (g.white_account_id = m.id OR g.black_account_id = m.id)
```

### My record at a position (from position_player_stats)

```sql
SELECT
  p.canonical_fen,
  ps.wins, ps.draws, ps.losses, ps.occurrences,
  ROUND(100.0 * ps.wins / ps.occurrences, 1) AS win_pct
FROM position_player_stats ps
JOIN accounts  m ON m.is_me = 1 AND ps.account_id = m.id
JOIN positions p ON p.id = ps.position_id
WHERE ps.occurrences >= 3
ORDER BY ps.occurrences DESC
LIMIT 20
```

### Positions with critter eval

```sql
SELECT
  p.canonical_fen,
  ps.wins, ps.losses, ps.occurrences,
  ce.final_score,
  CAST(json_extract(ce.piece_activity_json, '$.blended') AS INTEGER) AS activity,
  CAST(json_extract(ce.pawn_structure_json, '$.blended') AS INTEGER) AS pawn_structure
FROM position_player_stats ps
JOIN accounts               m  ON m.is_me = 1 AND ps.account_id = m.id
JOIN positions               p  ON p.id = ps.position_id
JOIN position_critter_evals ce ON ce.position_id = p.id
WHERE ps.occurrences >= 3
ORDER BY ps.losses DESC
LIMIT 20
```

### Games by opponent

```sql
SELECT
  opp.username,
  COUNT(*) AS games,
  SUM(CASE
    WHEN g.white_account_id = m.id AND g.result = '1-0' THEN 1
    WHEN g.black_account_id = m.id AND g.result = '0-1' THEN 1
    ELSE 0
  END) AS wins,
  ROUND(100.0 * SUM(CASE
    WHEN g.white_account_id = m.id AND g.result = '1-0' THEN 1
    WHEN g.black_account_id = m.id AND g.result = '0-1' THEN 1
    ELSE 0
  END) / COUNT(*), 1) AS win_pct
FROM games g
JOIN accounts m   ON m.is_me = 1
  AND (g.white_account_id = m.id OR g.black_account_id = m.id)
JOIN accounts opp ON opp.id = CASE
  WHEN g.white_account_id = m.id THEN g.black_account_id
  ELSE g.white_account_id
END
GROUP BY opp.username
HAVING games >= 3
ORDER BY win_pct ASC
LIMIT 20
```

### Position history — every game a position appeared in

```sql
SELECT
  g.platform,
  g.source_game_id,
  g.result,
  g.played_at,
  gp.ply,
  gp.move_san,
  CASE WHEN g.white_account_id = m.id THEN 'white' ELSE 'black' END AS my_color
FROM game_positions gp
JOIN games    g  ON g.id = gp.game_id
JOIN accounts m  ON m.is_me = 1
  AND (g.white_account_id = m.id OR g.black_account_id = m.id)
WHERE gp.position_before_id = (
  SELECT id FROM positions WHERE canonical_fen = ?
)
ORDER BY g.played_at DESC
```

### Moves I play from a position

```sql
SELECT
  gp.move_uci,
  gp.move_san,
  COUNT(*) AS frequency,
  SUM(CASE
    WHEN g.white_account_id = m.id AND g.result = '1-0' THEN 1
    WHEN g.black_account_id = m.id AND g.result = '0-1' THEN 1
    ELSE 0
  END) AS wins
FROM game_positions gp
JOIN games    g ON g.id = gp.game_id
JOIN accounts m ON m.is_me = 1 AND gp.mover_account_id = m.id
WHERE gp.position_before_id = (
  SELECT id FROM positions WHERE canonical_fen = ?
)
GROUP BY gp.move_uci, gp.move_san
ORDER BY frequency DESC
```

---

## Table reference

### `accounts`

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK | |
| `platform` | TEXT | `'chesscom'`, `'lichess'` |
| `username` | TEXT | |
| `is_me` | INTEGER | 1 = the profiled player, 0 = opponent |

### `games`

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK | |
| `platform` | TEXT | |
| `source_game_id` | TEXT | Platform-specific ID (e.g. `path#ply` for PGN imports) |
| `white_account_id` | INTEGER FK → accounts | |
| `black_account_id` | INTEGER FK → accounts | |
| `result` | TEXT | `'1-0'`, `'0-1'`, `'1/2-1/2'` |
| `time_control` | TEXT | Raw platform string, may be NULL |
| `played_at` | TEXT | ISO-8601 string, may be NULL |
| `white_elo` | INTEGER | May be NULL |
| `black_elo` | INTEGER | May be NULL |
| `raw_pgn` | TEXT | Full PGN text |

### `positions`

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK | Used for all FK joins except queue/run tables |
| `canonical_hash` | TEXT UNIQUE | Zobrist hash; used as FK in queue/run tables |
| `canonical_fen` | TEXT | Full 6-field FEN |
| `raw_fen` | TEXT | FEN as it appeared in source |
| `side_to_move` | TEXT | `'w'` or `'b'` |
| `castling` | TEXT | e.g. `'KQkq'` |
| `en_passant` | TEXT | e.g. `'e3'` or `'-'` |
| `halfmove_clock` | INTEGER | |
| `fullmove_number` | INTEGER | |

### `game_positions`

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK | |
| `game_id` | INTEGER FK → games | |
| `ply` | INTEGER | 0-indexed half-moves from start |
| `move_san` | TEXT | SAN notation, NULL at ply 0 (starting position) |
| `move_uci` | TEXT | UCI notation, NULL at ply 0 |
| `position_before_id` | INTEGER FK → positions | Position before the move |
| `position_after_id` | INTEGER FK → positions | Position after the move |
| `mover_account_id` | INTEGER FK → accounts | Account that played this move |

### `position_player_stats`

| Column | Type | Notes |
|---|---|---|
| `position_id` | INTEGER FK → positions | Composite PK with account_id |
| `account_id` | INTEGER FK → accounts | Composite PK with position_id |
| `wins` | INTEGER | Games where this account won from this position |
| `draws` | INTEGER | |
| `losses` | INTEGER | |
| `occurrences` | INTEGER | Total times this account reached this position |

### `position_color_stats`

| Column | Type | Notes |
|---|---|---|
| `position_id` | INTEGER PK FK → positions | |
| `white_wins` | INTEGER | Total times White won from this position (all players) |
| `draws` | INTEGER | |
| `black_wins` | INTEGER | |
| `occurrences` | INTEGER | Total appearances across all games |

### `position_critter_evals`

| Column | Type | Notes |
|---|---|---|
| `position_id` | INTEGER FK → positions | |
| `critter_name` | TEXT | Evaluator name (e.g. `'critter-eval'`) |
| `critter_model` | TEXT | Model tag, may be NULL |
| `final_score` | INTEGER | Sum of all groups + modifiers, centipawns; + = White better |
| `phase` | INTEGER | Game phase (0–256, midgame→endgame) |
| `material_json` | TEXT | JSON `{mg, eg, blended}` |
| `pawn_structure_json` | TEXT | JSON `{mg, eg, blended}` |
| `piece_activity_json` | TEXT | JSON `{mg, eg, blended}` |
| `king_safety_json` | TEXT | JSON `{mg, eg, blended}` |
| `passed_pawns_json` | TEXT | JSON `{mg, eg, blended}` |
| `development_json` | TEXT | JSON `{mg, eg, blended}` |
| `analysis_json` | TEXT | Full eval record including `vector_features` and `strategic` groups |

### `position_engine_evals`

| Column | Type | Notes |
|---|---|---|
| `position_id` | INTEGER FK → positions | |
| `engine_name` | TEXT | e.g. `'stockfish'` |
| `centipawn` | INTEGER | Static eval, centipawns; + = White better |
| `mate` | INTEGER | Mate-in-N (NULL if none) |
| `best_move_uci` | TEXT | |
| `best_move_san` | TEXT | |
| `depth` | INTEGER | Search depth |
| `analysis_json` | TEXT | Full engine output |

---

## Common gotchas

- **NULL ELOs**: `white_elo` / `black_elo` are NULL for many imported games. Use `IS NOT NULL` guards or `COALESCE`.
- **NULL time_control**: Also common. The reports classify it as `'unknown'` — mirror that in SQL if needed.
- **`position_id` not `canonical_hash`**: All `position_*_stats` and `position_*_evals` tables use the integer `position_id`. Only `position_dynamic_queue` and `position_dynamic_runs` use `canonical_hash` as FK.
- **Two profiled accounts**: If the same user has both a chess.com and lichess account, `WHERE is_me = 1` returns two rows. Use `AND m.platform = ?` to constrain to one platform, or group by platform.
- **`occurrences` includes both colors**: `position_player_stats.occurrences` counts every time the account reached the position, regardless of whether they were White or Black.
- **`final_score` sign**: Positive = White advantage, negative = Black advantage — same convention as Stockfish centipawns.
- **`game_positions` ply 0**: The starting position is inserted as ply 0 with `move_san = NULL` and `move_uci = NULL`. Filter `ply > 0` if you only want positions after a move was made.
