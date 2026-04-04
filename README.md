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
      elo_tune:    1200             # --WeightsFile ELO target passed to the engine
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
    llm_model:      ""
    prompt_version: ""
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

# 3. Queue and run critter decomposed evals (most frequent positions first)
./main.nu critter-enqueue
./main.nu critter-eval 50

# 4. Optional: queue and run static engine evals
./main.nu enqueue 100
./main.nu eval 20

# 5. Check progress
./main.nu status
./main.nu critter-qstats
```

---

## All commands

| Command | Description |
|---|---|
| `init` | Create the SQLite schema |
| `import <path> [platform]` | Import a local PGN or chess.com JSON export |
| `sync chesscom [all] <user>` | Download and import chess.com archives |
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
| `critter-enqueue [limit]` | Queue positions for critter eval (default all) |
| `critter-queue [limit]` | Show pending critter eval queue (default 20) |
| `critter-qstats` | Critter eval queue statistics |
| `critter-eval [limit]` | Run critter eval on queued positions (default 20) |
| `dynamic-enqueue [limit]` | Queue positions for dynamic eval (default all) |
| `dynamic-queue [limit]` | Show pending dynamic eval queue (default 20) |
| `dynamic-qstats` | Dynamic eval queue statistics |
| `dynamic-eval [limit]` | Run dynamic eval on queued positions (default 20) |

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
./main.nu critter-enqueue        # populate queue from all known positions
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

## Related projects

- [`nu_plugin_shakmaty`](../nu_plugin_shakmaty) — Nushell plugin for deterministic chess semantics
- [`critter-eval`](../critter-eval) — decomposed Open Critter evaluation backend
- [`open-critter`](../open-critter) — Open Critter engine source (Pascal, UCI)
