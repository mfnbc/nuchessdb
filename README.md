# nuchessdb

A Nushell-first chess database and enrichment pipeline. Import games from chess.com or lichess, replay them into canonical positions, and layer deterministic evaluation, decomposed critter scores, and dynamic move analysis on top — all queryable directly from Nushell.

## How it works

- Nushell orchestrates everything.
- SQLite stores games, positions, stats, and evaluation results.
- `nu_plugin_shakmaty` handles deterministic chess semantics (FEN, moves, hashing).
- `critter-eval` provides decomposed Open Critter evaluation per position.
- A UCI engine (e.g. Stockfish, lc0) can add static or dynamic move analysis.

---

## Prerequisites

### 1. Build and install `nu_plugin_shakmaty`

```sh
cd ../nu_plugin_shakmaty
cargo build --release
```

Inside Nushell:

```nu
plugin add /full/path/to/nu_plugin_shakmaty/target/release/nu_plugin_shakmaty
```

Then restart Nushell (or start a new session) for the plugin to be active.

### 2. Build `critter-eval`

```sh
cd ../critter-eval
cargo build --release
# binary: target/release/critter-eval
```

### 3. Configure `config/nuchessdb.nuon`

```nuon
{
  database: {
    path: "./data/nuchessdb.sqlite"   # where the SQLite file lives
    schema: "./sql/schema.sql"        # DDL applied on init
  }
  identity: {
    me: {
      chesscom: "your-chesscom-username"   # used to classify games as wins/losses/draws
      lichess:  "your-lichess-username"
    }
  }
  enrichment: {
    critter: {
      binary: "../critter-eval/target/release/critter-eval"   # leave "" for auto-discovery
      name:   "critter-eval"
      model:  ""
    }
    dynamic: {
      binary:      "/path/to/lc0"   # UCI engine binary
      engine_name: "lc0"
      elo_tune:    1200             # engine skill/ELO target for dynamic analysis
      depth:       12
    }
    engine: {
      binary:      "/path/to/stockfish"   # for static evals
      name:        "stockfish"
      model:       ""
      threads:     1
      hash_mb:     128
      depth:       12
      nodes:       0       # 0 = not used
      movetime_ms: 0       # 0 = not used
    }
    llm_model:      ""   # planned: model name for LLM commentary
    prompt_version: ""   # planned: prompt version tag
  }
}
```

---

## Quick start

```nu
# 1. Create the database
./main.nu init

# 2. Download and import every chess.com archive for your account
./main.nu sync chesscom all <your-username>

# 3. If you want a fresh retry, reset the database and sync cache
./main.nu clean

# 4. Recreate the schema and retry sync from scratch
./main.nu init
./main.nu sync chesscom all <your-username>

# 5. Queue and run critter decomposed evals (most frequent positions first)
./main.nu critter-enqueue
./main.nu critter-eval 50

# 6. Optional: queue and run static engine evals
./main.nu enqueue 100
./main.nu eval 20

# 7. Check progress
./main.nu status
./main.nu critter-qstats

# 8. Explore opening patterns — classify your most-visited positions
./main.nu eco-classify 100
```

---

## All commands

| Command | Description |
|---|---|
| `init` | Create the SQLite schema |
| `import <path> [platform]` | Import a local PGN or chess.com JSON export |
| `sync chesscom [all] <user>` | Download and import chess.com archives |
| `sync chesscom update <user>` | Retry previously missing chess.com archives |
| `clean` | Remove the database and chess.com sync cache |
| `bench <sync-args...>` | Time a sync run |
| `status` | Overview: game count, position count, queue depths |
| `recent [limit]` | Most recently imported games (default 10) |
| `top [limit]` | Most-visited positions (default 20) |
| `report [limit]` | Positions with outcome stats (default 20) |
| `opponents [limit]` | Most-played opponents (default 20) |
| `rated [limit]` | Opponents sorted by rating (default 50) |
| `enqueue [limit]` | Queue hot positions for engine eval (default 50) |
| `queue [limit]` | Show pending engine eval queue (default 50) |
| `qstats` | Engine eval queue statistics |
| `eval [limit]` | Run engine eval on queued positions (default 20) |
| `engine [limit]` | Show stored engine eval results (default 20) |
| `critter-enqueue [limit]` | Queue popular positions for critter eval (occurrences ≥ 3, default all) |
| `critter-enqueue-games [limit]` | Queue positions from your games for critter eval, newest games first (default 100000) |
| `critter-queue [limit]` | Show pending critter eval queue (default 20) |
| `critter-qstats` | Critter eval queue statistics |
| `critter-eval [limit]` | Run critter eval on queued positions (default 20) |
| `dynamic-enqueue [limit]` | Queue positions for dynamic eval (default all) |
| `dynamic-queue [limit]` | Show pending dynamic eval queue (default 20) |
| `dynamic-qstats` | Dynamic eval queue statistics |
| `dynamic-eval [limit]` | Run dynamic eval on queued positions (default 20) |
| `eco-classify [limit]` | Top positions from `report` enriched with ECO opening names (default 20) |

---

## Player profiling queries

Use Nushell directly against the SQLite file. Set `$db` once and reuse:

```nu
let db = (open ./data/nuchessdb.sqlite)
```

### Win rate by color

```nu
$db | query db "
  SELECT
    CASE WHEN g.white_account_id = m.id THEN 'white' ELSE 'black' END AS color,
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
  JOIN accounts m ON m.is_me = 1
    AND (g.white_account_id = m.id OR g.black_account_id = m.id)
  GROUP BY color
"
```

### Positions I lose from most — training targets

```nu
$db | query db "
  SELECT
    p.canonical_fen,
    ps.losses,
    ps.wins,
    ps.occurrences,
    ROUND(100.0 * ps.losses / ps.occurrences, 1) AS loss_pct
  FROM position_player_stats ps
  JOIN accounts m ON m.is_me = 1 AND ps.account_id = m.id
  JOIN positions p ON p.id = ps.position_id
  WHERE ps.occurrences >= 3
  ORDER BY loss_pct DESC, ps.losses DESC
  LIMIT 20
"
```

### My win rate at the openings I reach most

```nu
$db | query db "
  SELECT
    p.canonical_fen,
    ps.occurrences,
    ps.wins,
    ps.draws,
    ps.losses,
    ROUND(100.0 * ps.wins / ps.occurrences, 1) AS win_pct
  FROM position_player_stats ps
  JOIN accounts m ON m.is_me = 1 AND ps.account_id = m.id
  JOIN positions p ON p.id = ps.position_id
  ORDER BY ps.occurrences DESC
  LIMIT 20
"
```

### Opponents I struggle against

```nu
$db | query db "
  SELECT
    opp.username AS opponent,
    COUNT(*) AS games,
    SUM(CASE
      WHEN g.white_account_id = m.id AND g.result = '1-0' THEN 1
      WHEN g.black_account_id = m.id AND g.result = '0-1' THEN 1
      ELSE 0
    END) AS wins,
    SUM(CASE
      WHEN g.white_account_id = m.id AND g.result = '0-1' THEN 1
      WHEN g.black_account_id = m.id AND g.result = '1-0' THEN 1
      ELSE 0
    END) AS losses,
    ROUND(100.0 * SUM(CASE
      WHEN g.white_account_id = m.id AND g.result = '1-0' THEN 1
      WHEN g.black_account_id = m.id AND g.result = '0-1' THEN 1
      ELSE 0
    END) / COUNT(*), 1) AS win_pct
  FROM games g
  JOIN accounts m ON m.is_me = 1
    AND (g.white_account_id = m.id OR g.black_account_id = m.id)
  JOIN accounts opp ON opp.id = (
    CASE WHEN g.white_account_id = m.id THEN g.black_account_id ELSE g.white_account_id END
  )
  GROUP BY opp.username
  HAVING games >= 3
  ORDER BY win_pct ASC
  LIMIT 20
"
```

### Where am I already losing? — engine eval at positions I visit

```nu
$db | query db "
  SELECT
    p.canonical_fen,
    ps.occurrences,
    ps.losses,
    e.centipawn,
    e.best_move_san
  FROM position_player_stats ps
  JOIN accounts m ON m.is_me = 1 AND ps.account_id = m.id
  JOIN positions p ON p.id = ps.position_id
  JOIN position_engine_evals e ON e.position_id = p.id
  WHERE ps.occurrences >= 2
  ORDER BY e.centipawn ASC
  LIMIT 20
"
```

### My record vs higher-rated opponents

```nu
$db | query db "
  SELECT
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
  JOIN accounts m ON m.is_me = 1
    AND (g.white_account_id = m.id OR g.black_account_id = m.id)
  WHERE (
    (g.white_account_id = m.id AND g.black_elo  > g.white_elo) OR
    (g.black_account_id = m.id AND g.white_elo  > g.black_elo)
  )
"
```

### Positions needing critter enrichment, with outcome context

```nu
$db | query db "
  SELECT
    p.canonical_fen,
    q.status,
    COALESCE(cs.white_wins, 0) AS white_wins,
    COALESCE(cs.draws, 0)      AS draws,
    COALESCE(cs.black_wins, 0) AS black_wins,
    COALESCE(cs.occurrences, 0) AS total
  FROM position_critter_eval_queue q
  JOIN positions p ON p.id = q.position_id
  LEFT JOIN position_color_stats cs ON cs.position_id = p.id
  WHERE q.status = 'pending'
  ORDER BY total DESC
  LIMIT 20
"
```

---

## Enrichment workflow

Each evaluator follows the same queue-then-drain pattern:

```nu
# Critter (decomposed Open Critter eval)
./main.nu critter-enqueue        # queue popular positions (occurrences >= 3)
./main.nu critter-enqueue-games  # or: queue by game recency (newest first)
./main.nu critter-eval 50        # drain 50 entries
./main.nu critter-qstats         # check progress

# Static engine eval (Stockfish / lc0)
./main.nu enqueue 100
./main.nu eval 20
./main.nu qstats

# Dynamic move ladder
./main.nu dynamic-enqueue
./main.nu dynamic-eval 20
./main.nu dynamic-qstats
```

Re-running `*-enqueue` is safe — it inserts only positions not already in the queue.

---

## Openings

ECO opening classification is stored as a flat JSON file (`data/eco.json`) and joined at query time in Nushell — no schema changes, no extra SQL table. Only ECO root positions are covered (499 entries, A01–E99). Most middlegame and endgame positions will not match — that is expected.

### Data files

| File | Contents |
|---|---|
| `data/eco.json` | 499 ECO root entries; fields: `fen`, `eco_code`, `name`, `moves` |
| `data/eco_commentary.json` | LLM-extracted commentary, keyed by `eco_code` |

Each entry in `eco.json`:

```json
{
  "fen":      "rnbqkbnr/pppppppp/8/8/8/1P6/P1PPPPPP/RNBQKBNR b KQkq -",
  "eco_code": "A01",
  "name":     "Nimzo-Larsen Attack",
  "moves":    "1. b3"
}
```

FEN keys are 4-field (board + side to move + castling rights + en-passant square). The halfmove clock and fullmove number are stripped before matching, so 6-field `canonical_fen` values from the database work without any pre-processing.

### Quick command

```nu
# Top positions from position-report, enriched with ECO names (default 20)
./main.nu eco-classify

# Increase the look-ahead — examine more positions to find ECO matches
./main.nu eco-classify 200
```

Internally this runs `position-report $limit | eco-classify`. Rows with no ECO match appear with empty `eco_code` and `opening_name` columns.

### Module functions

Import the module directly in interactive Nushell for full flexibility:

```nu
use modules/eco.nu *
```

#### `eco-lookup <fen: string>`

Look up one FEN. Strips to 4 fields automatically. Returns the matching record or `null`.

```nu
# Works with a 6-field canonical_fen from the database
eco-lookup "rnbqkbnr/pppppppp/8/8/8/1P6/P1PPPPPP/RNBQKBNR b KQkq - 0 1"
# => { fen: "rnbqkbnr/pppppppp/8/8/8/1P6/P1PPPPPP/RNBQKBNR b KQkq -", eco_code: "A01", name: "Nimzo-Larsen Attack", moves: "1. b3" }

# Returns null when no match
eco-lookup "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq -"
# => null
```

#### `eco-classify` (pipeline command)

Enriches any table that has a `canonical_fen` column. Adds `eco_code` and `opening_name` columns. Rows with no match get empty strings.

```nu
use modules/eco.nu *

# Classify the top positions by occurrence
open ./data/nuchessdb.sqlite
| query db "
    SELECT p.canonical_fen, s.occurrences
    FROM positions p
    JOIN position_color_stats s ON s.position_id = p.id
    ORDER BY s.occurrences DESC
    LIMIT 100
  "
| eco-classify

# Any command that returns a canonical_fen column works
./main.nu report 500 | eco-classify
```

### Finding insights

The general pattern: run a query → pipe to `eco-classify` → filter, sort, or group in Nushell.

#### Your most-visited openings

The fastest starting point. Shows which ECO positions you actually reach and your record at each:

```nu
use modules/eco.nu *

./main.nu report 500
| eco-classify
| where eco_code != ""
| select eco_code opening_name me_occurrences me_wins me_losses me_win_rate me_loss_rate
| sort-by me_occurrences --reverse
```

#### Win rate aggregated by opening

Multiple positions can map to the same ECO root if different move orders land on the same canonical position. Group to aggregate:

```nu
use modules/eco.nu *

./main.nu report 1000
| eco-classify
| where eco_code != "" and me_occurrences > 0
| group-by eco_code
| items { |code rows|
    let games  = ($rows | get me_occurrences | math sum)
    let wins   = ($rows | get me_wins   | math sum)
    let losses = ($rows | get me_losses | math sum)
    {
      eco_code:     $code
      opening_name: ($rows | get opening_name | first)
      games:        $games
      wins:         $wins
      losses:       $losses
      win_pct:      (if $games > 0 { ($wins   / $games * 100 | math round) } else { 0 })
      loss_pct:     (if $games > 0 { ($losses / $games * 100 | math round) } else { 0 })
    }
  }
| sort-by games --reverse
```

#### Your problem openings

Sort by loss rate, filter out low-sample openings:

```nu
use modules/eco.nu *

./main.nu report 1000
| eco-classify
| where eco_code != "" and me_occurrences >= 5
| select eco_code opening_name me_occurrences me_win_rate me_loss_rate
| sort-by me_loss_rate --reverse
| first 20
```

#### Bare query approach

When you need a SQL join that `position-report` does not cover, fetch the raw data in SQL and then join with `eco.json` in Nushell. The 4-field FEN strip is the only extra step:

```nu
let db  = (open ./data/nuchessdb.sqlite)
let eco = (open ./data/eco.json)

$db | query db "
  SELECT
    p.canonical_fen,
    SUM(ps.wins)        AS me_wins,
    SUM(ps.draws)       AS me_draws,
    SUM(ps.losses)      AS me_losses,
    SUM(ps.occurrences) AS me_games
  FROM position_player_stats ps
  JOIN accounts  a ON a.id = ps.account_id AND a.is_me = 1
  JOIN positions p ON p.id = ps.position_id
  GROUP BY ps.position_id
  HAVING me_games >= 3
  ORDER BY me_losses DESC
"
| each { |row|
    let fen4  = ($row.canonical_fen | split row " " | first 4 | str join " ")
    let match = ($eco | where fen == $fen4)
    if ($match | is-empty) {
      $row | insert eco_code "" | insert opening_name ""
    } else {
      $row | insert eco_code $match.0.eco_code | insert opening_name $match.0.name
    }
  }
| where eco_code != ""
| insert win_pct { |r| ($r.me_wins / $r.me_games * 100 | math round) }
| select eco_code opening_name me_games me_wins me_losses win_pct
| sort-by win_pct
```

The pattern: SQL for aggregation, a `each` block to strip the FEN and look it up in the JSON array, then filter and sort in Nushell.

#### Combining with critter scores

After critter-eval has run, you can identify openings where the position is objectively balanced but your results are poor — a knowledge gap rather than a bad opening:

```nu
let db  = (open ./data/nuchessdb.sqlite)
let eco = (open ./data/eco.json)

$db | query db "
  SELECT
    p.canonical_fen,
    SUM(ps.losses)      AS me_losses,
    SUM(ps.occurrences) AS me_games,
    ce.final_score
  FROM position_player_stats ps
  JOIN accounts               a  ON a.id  = ps.account_id AND a.is_me = 1
  JOIN positions               p  ON p.id  = ps.position_id
  JOIN position_critter_evals ce ON ce.position_id = p.id
  GROUP BY ps.position_id
  HAVING me_games >= 3
  ORDER BY me_losses DESC
"
| each { |row|
    let fen4  = ($row.canonical_fen | split row " " | first 4 | str join " ")
    let match = ($eco | where fen == $fen4)
    if ($match | is-empty) {
      $row | insert eco_code "" | insert opening_name ""
    } else {
      $row | insert eco_code $match.0.eco_code | insert opening_name $match.0.name
    }
  }
| where eco_code != ""
| select eco_code opening_name final_score me_games me_losses
| sort-by me_losses --reverse
```

A `final_score` near 0 (centipawns, balanced) alongside a high `me_losses` count is the signal. Those are your opening study priorities.

### Adding commentary

`data/eco_commentary.json` is a flat object keyed by ECO code. Each value is a record with `name` and `commentary`:

```json
{
  "A01": {
    "name": "Nimzo-Larsen Attack",
    "commentary": "White fianchettoes the queen's bishop early, aiming for a flexible queenside setup..."
  },
  "B20": {
    "name": "Sicilian Defence",
    "commentary": "Black's most combative response to 1.e4, leading to asymmetric positions..."
  }
}
```

To use commentary in a Nushell session:

```nu
use modules/eco.nu *

let commentary = (open ./data/eco_commentary.json)
let opening    = (eco-lookup $some_fen)

if $opening != null {
  $commentary | get -o $opening.eco_code
}
```

---

## Performance

The import and enrichment pipeline is designed around a key constraint: **Nushell's `open file.sqlite | query db` opens a new SQLite connection on every call**, so each call is its own transaction and fsync (~10–16 ms). The pipeline minimises the total number of `query db` calls by batching SQL into as few large statements as possible.

### Import (`import` / `sync`)

Positions, accounts, and games are inserted in **Phase 1** using multi-row `INSERT ... VALUES (...), (...), ...` statements, chunked at 400 rows. Phase 2 uses CTE-based bulk INSERTs for `game_positions`, `position_color_stats`, and `position_player_stats` — all JOIN resolution happens inside SQLite, with no ID lookups in Nushell.

Deduplication of positions across a PGN file is done in Rust (`nu_plugin_shakmaty` returns `batch.unique_positions`, a BTreeMap-deduplicated list) so no O(N²) Nushell `reduce` is needed.

Measured throughput: **295 games imported in ~18 seconds** (~1086 `query db` calls total).

### Critter eval (`critter-eval`)

The eval loop pipes all FENs to a single `critter-eval` binary invocation, parses results into a Nushell list (no DB calls in the loop), then writes everything in one `run-sql` call:

- 1 bulk `INSERT INTO position_critter_evals ... VALUES (...), (...)` per 400 evals
- 1 bulk `UPDATE position_critter_eval_queue ... WHERE position_id IN (...)` for all done jobs
- 1 `UPDATE` per failed job (rare)

Measured throughput: **100 evals in ~0.47 seconds** (vs ~430 ms just for writes at 20 evals with the per-row approach).

---

## Related projects

- [`nu_plugin_shakmaty`](../nu_plugin_shakmaty) — Nushell plugin for deterministic chess semantics
- [`critter-eval`](../critter-eval) — decomposed Open Critter evaluation backend
- [`open-critter`](../open-critter) — Open Critter engine source (Pascal, UCI)
