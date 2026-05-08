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

### 2. Setup Database
```nu
./main.nu init
./main.nu sync chesscom all <your-username>
```

### 3. Enrich & Analyze
```nu
./main.nu critter-enqueue-games
./main.nu critter-eval 100
./main.nu eco-classify
```

### 4. Run Coach Review
```nu
use modules/coach.nu *
coach-review 1  # Reviews game ID 1 with AI commentary
```

## How it Works

- **`nu_plugin_chessdb`**: Rust plugin for all chess semantics (FEN, hashing, NNUE, critter eval).
- **Modules**: Nushell orchestration for sync, reporting, and RAG integration.
- **Coach's Notebook**:
    - **Strategic (Static)**: Structural vector similarity finds similar historical/opening positions.
    - **Tactical (Dynamic)**: Identifies the "Culprit" behind eval drops (e.g., King Safety vs Material).

## Core Commands

| Command | Description |
|---|---|
| `sync` | Import games from chess.com/lichess |
| `status` | Database overview (games, positions, queues) |
| `report` | Performance stats for most-visited positions |
| `critter-eval` | Run decomposed structural evaluation |
| `eco-classify` | Map positions to ECO opening names |
| `coach-review` | Generate AI-driven game annotations |

## Advanced Querying

Set `$db = (open ./data/nuchessdb.sqlite)` and query directly:

```nu
# Win rate by color
$db | query db "SELECT CASE WHEN g.white_account_id = m.id THEN 'white' ELSE 'black' END AS color, COUNT(*) AS games, ROUND(100.0 * SUM(CASE WHEN (g.white_account_id = m.id AND g.result = '1-0') OR (g.black_account_id = m.id AND g.result = '0-1') THEN 1 ELSE 0 END) / COUNT(*), 1) AS win_pct FROM games g JOIN accounts m ON m.is_me = 1 AND (g.white_account_id = m.id OR g.black_account_id = m.id) GROUP BY color"
```

Refer to `docs/query-primer.md` for more examples.
