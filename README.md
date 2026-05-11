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
  - **Batch Processing**: Plugin accepts lists of FENs for efficient parallel processing
  - **Zobrist hashing**: Process thousands of positions in a single call
  - **HUGM evaluation**: Uses Rayon for multi-core parallel analysis
- **Modules**: Nushell orchestration for sync, reporting, and RAG integration.
  - **List-first design**: All operations work with full lists, not individual items
  - **Smart caching**: Skip evaluation of positions that already exist
- **Coach's Notebook**:
    - **Strategic (Static)**: Structural vector similarity finds similar historical/opening positions.
    - **Tactical (Dynamic)**: Identifies the "Culprit" behind eval drops (e.g., King Safety vs Material).

## Performance

The pipeline is optimized for batch processing:
- **Zobrist hashing**: Single plugin call for all positions (vs thousands of individual calls)
- **HUGM evaluation**: Batch analysis with internal parallelization (Rayon)
- **Smart skipping**: Re-imports skip already-evaluated positions
- **Result**: ~1m50s to import and evaluate 3,425 positions (38 games) with full HUGM analysis

## Core Commands

All commands are run via: `nu nuchessdb.nu <command> [args]`

| Command | Description |
|---|---|
| `init` | Initialize database and schema |
| `sync <platform> <username>` | Download and import games from chess.com/lichess |
| `import <path.pgn> <platform>` | Import PGN file into database |
| `status` | Database overview (games, positions, evaluations) |
| `report [limit]` | Performance stats for most-visited positions |
| `hugm-eval [limit]` | Run decomposed structural evaluation queue |
| `eco-classify [limit]` | Top positions with ECO opening names |
| `coach-review <game_id>` | Generate AI-driven game annotations |
| `recent [limit]` | Show recently imported games |
| `top [limit]` | Most-visited positions |

Run `nu nuchessdb.nu help` for complete usage information.

## Advanced Querying

The database is just SQLite - you can query it directly in Nushell:

```nu
let db = (open ./data/nuchessdb.sqlite)

# Win rate by color
$db | query db "
  SELECT 
    CASE WHEN g.white_account_id = m.id THEN 'white' ELSE 'black' END AS color,
    COUNT(*) AS games,
    ROUND(100.0 * SUM(CASE 
      WHEN (g.white_account_id = m.id AND g.result = '1-0') 
        OR (g.black_account_id = m.id AND g.result = '0-1') 
      THEN 1 ELSE 0 
    END) / COUNT(*), 1) AS win_pct
  FROM games g 
  JOIN accounts m ON m.is_me = 1 
    AND (g.white_account_id = m.id OR g.black_account_id = m.id)
  GROUP BY color
"
```

Refer to `docs/query-primer.md` for more examples.

## Advanced Module Usage

For scripting or custom workflows, import modules directly:

```nu
use modules/db.nu *
use modules/import.nu *
use modules/hugm.nu *

init-db
import-pgn-file ./data/games.pgn chesscom
hugm-eval-queue 50
```

**Note:** The `--with-hugm` flag has been removed. HUGM evaluation is now always enabled by default.

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
