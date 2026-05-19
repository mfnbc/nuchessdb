# nuchessdb

A Nushell-first chess database and enrichment pipeline. Import games, analyze patterns, and generate AI coaching commentary using decomposed evaluations and vector similarity.

## Vision

- **Queryable Fact Base**: A local SQLite database you can script against directly.
- **Decomposed Logic**: Move from raw scores (+1.0) to learnable concepts (King Safety, Activity).
- **Coach's Notebook**: Two-layer annotation (Strategic Static + Tactical Dynamic) powered by RAG and HUGM deltas.

## Quick Start

### 1. Build and Install Plugin
```sh
cd nu_plugin_chessdb && cargo build --release
# In Nushell:
plugin add nu_plugin_chessdb/target/release/nu_plugin_chessdb
```

### 2. Initialize Database
```sh
nu nuchessdb.nu init
```

### 3. Import Games

**Option A: Sync from chess.com/lichess**
```sh
# Download ALL games with HUGM decomposed evaluation
nu nuchessdb.nu sync chesscom <your-username>

# Or test with just the latest archive first
nu nuchessdb.nu sync chesscom <your-username> --smoketest
```

**Option B: Import from PGN file**
```sh
# Import PGN with HUGM decomposed evaluation
nu nuchessdb.nu import ./data/my_games.pgn chesscom
```

**Note:** All imports automatically include HUGM evaluation for position analysis. By default, sync downloads ALL game archives (this may take time for accounts with many games).

### 4. Analyze Your Games
```sh
# View database status
nu nuchessdb.nu status

# View positions where you lose most often ("Collapses")
nu nuchessdb.nu report 10

# Get AI coaching for a specific game
nu nuchessdb.nu coach-review 1
```

## How it Works

- **`nu_plugin_chessdb`**: Rust plugin for all chess semantics (FEN, hashing, NNUE, HUGM eval).
  - **Elo Sensor Taxonomy**: Sensors classified into four tiers (Survival/Threat/Positional/Strategic) by ELO threshold.
  - **Convergence Gate**: Chaos coefficient gates higher-tier sensors — positional analysis is attenuated in tactically unstable positions.
  - **Batch Processing**: Plugin accepts lists of FENs for efficient parallel processing.
  - **HUGM evaluation**: Uses Rayon for multi-core parallel analysis.
- **Modules**: Nushell orchestration for sync, reporting, and LLM integration.
  - **List-first design**: All operations work with full lists, not individual items.
  - **Idempotent sync**: Re-imports skip already-evaluated positions and games.
- **Cognitive Coach**:
    - **Per-player baselines**: Welford's algorithm computes mean/std for eval swings across a player's history.
    - **Anomaly detection**: z-score flags moves that are statistically unusual *for this player*.
    - **Socratic enrichment**: Typed concepts fed through nu-agent's Enrich contract to an LLM (Gemma/Qwen).

## Performance

The pipeline is optimized for batch processing:
- **Zobrist hashing**: Single plugin call for all positions (vs thousands of individual calls)
- **HUGM evaluation**: Batch analysis with internal parallelization (Rayon)
- **Smart skipping**: Re-imports skip already-evaluated positions
- **Result**: ~1m50s to import and evaluate 3,425 positions (38 games) with full HUGM analysis

## Core Commands

All commands are run via: `nu nuchessdb.nu <command> [args]`

| Command | Description | Status |
|---|---|---|
| `init` | Initialize database and schema | ✅ |
| `--limit N` | Process only last N archives (main-level flag, before subcommand) | ✅ |
| `sync <username>` | Download and import games from chess.com | ✅ |
| `recent [n]` | List the n most recent games (default 5) | ✅ |
| `explore <zobrist>` | Show move frequencies and ELO performance for a position | ✅ |
| `review <game_id>` | Show move-by-move HUGM evaluations for a game | ✅ |
| `status` | Database counts (games, positions, moves) | ✅ |
| `coach-review <game_id> [perspective]` | LLM-powered Socratic coaching with anomaly detection | ✅ |
| `coach-profile <username>` | Show what concepts you consistently miss (frequency × severity) | ✅ |
| `derive-coach <username>` | DERIVE phase: batch baselines, anomalies, transitions via Rust plugin | ✅ |
| `dictionary-update <username> [--limit N]` | Incremental Tier-1000 Welford update from gated_issues | ✅ |
| `validate-gate <username> <game_id>` | Anomaly intercept gate — 3-line JSON shutdown block | ✅ |
| `import <path.pgn>` | Import PGN file into database | 🚧 planned |

Run `nu nuchessdb.nu help` for complete usage information.

## Plugin Commands

The `nu_plugin_chessdb` Rust plugin exposes these commands directly in Nushell:

| Command | Description | Status |
|---------|-------------|--------|
| `chessdb hugm-eval` | HUGM decomposed evaluation (FEN → scored concepts) | ✅ |
| `chessdb nnue-eval` | Stockfish NNUE evaluation (FEN → centipawn score) | ✅ |
| `chessdb process-corpus` | Parse game JSON arrays into structured records | ✅ |
| `chessdb pgn-to-fens` | Parse single-game PGN to move + FEN records | ✅ |
| `chessdb pgn-to-batch` | Parse multi-game PGN to batch records | ✅ |
| `chessdb bullet-build` | Build bullet-format training shards | 🚧 |
| `chessdb pgn-scan` | Scan PGN text for game count, validation | ✅ |
| `chessdb zobrist` | Compute zobrist hash from FEN | ✅ |
| `chessdb derive-coach-signals` | Batch Welford baselines + z-score anomaly detection + state transitions | ✅ |

### Plugin output contract (stable)

`chessdb hugm-eval` returns per FEN:
```
{ fen, final_score, phase, side_to_move, groups: {...}, sensor_report: {...} }
```

The `sensor_report` contains typed concepts (forks, pins, outposts, etc.) ready for the LLM coach contract at `prj/nu-agent/contracts/chess_coach.toml`. Concept extraction is a separate read-only pass after evaluation — ingestion remains deterministic and fast.

## Advanced Querying

The database is SQLite — query it directly in Nushell:

```nu
let db = (open chess.db)

# Win rate by color from game results
$db | query db "
  SELECT 
    CASE WHEN g.white = (SELECT white FROM games LIMIT 1) THEN 'white' ELSE 'black' END,
    COUNT(*) as games,
    COUNT(CASE WHEN result = '1-0' THEN 1 END) as wins
  FROM games g GROUP BY 1
"
```

## Architecture

The system follows a batch-processing architecture:

```
Nushell Script
    ↓ (collect all FENs into list)
    ↓ (single serialization)
Rust Plugin
    ↓ (deserialize once)
    ↓ (Rayon parallel processing across CPU cores)
    ↓ (serialize results once)
Nushell Script
    ↓ (process results as list)
SQLite Database
```

This eliminates plugin call overhead and maximizes CPU utilization for analysis.
