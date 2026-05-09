# nuchessdb

A Nushell-first chess database and enrichment pipeline. Import games, analyze patterns, and generate AI coaching commentary using decomposed evaluations and vector similarity.

## Vision

- **Queryable Fact Base**: A local SQLite database you can script against directly.
- **Decomposed Logic**: Move from raw scores (+1.0) to learnable concepts (King Safety, Activity).
- **Coach's Notebook**: Two-layer annotation (Strategic Static + Tactical Dynamic) powered by RAG and critter deltas.

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
# Download all games with Critter decomposed evaluation
nu nuchessdb.nu sync chesscom <your-username>
```

**Option B: Import from PGN file**
```sh
# Import PGN with Critter decomposed evaluation
nu nuchessdb.nu import ./data/my_games.pgn chesscom
```

**Note:** All imports automatically include Critter evaluation for position analysis.

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

- **`nu_plugin_chessdb`**: Rust plugin for all chess semantics (FEN, hashing, NNUE, critter eval).
- **Modules**: Nushell orchestration for sync, reporting, and RAG integration.
- **Coach's Notebook**:
    - **Strategic (Static)**: Structural vector similarity finds similar historical/opening positions.
    - **Tactical (Dynamic)**: Identifies the "Culprit" behind eval drops (e.g., King Safety vs Material).

## Core Commands

All commands are run via: `nu nuchessdb.nu <command> [args]`

| Command | Description |
|---|---|
| `init` | Initialize database and schema |
| `sync <platform> <username>` | Download and import games from chess.com/lichess |
| `import <path.pgn> <platform>` | Import PGN file into database |
| `status` | Database overview (games, positions, evaluations) |
| `report [limit]` | Performance stats for most-visited positions |
| `critter-eval [limit]` | Run decomposed structural evaluation queue |
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
use modules/critter.nu *

init-db
import-pgn-file ./data/games.pgn chesscom --with-critter
critter-eval-queue 50
```
