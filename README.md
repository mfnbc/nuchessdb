# chessdb.nu

A Nushell chess database and AI coaching platform. Import games from chess.com, run HUGM decomposed evaluation, derive per-player coaching baselines, and query your games in plain English with an AI analyst powered by [ai.nu](https://github.com/fj0r/ai.nu).

## Quick Start

```sh
# Build and register the plugin
cd nu_plugin_chessdb && cargo build --release && cd ..
nu -c 'plugin add nu_plugin_chessdb/target/release/nu_plugin_chessdb'

# Initialise, sync, and derive coaching data
nu -c 'use chessdb *; chess-init'
nu -c 'use chessdb *; chess-sync <your-chess.com-username>'
nu -c 'use chessdb *; chess-derive <your-username>'

# View your profile
nu -c 'use chessdb *; chess-profile <your-username>'
```

Or use as a module in an interactive session:

```nu
use chessdb *
chess-init
chess-sync <your-username>
chess-derive <your-username>
chess-profile <your-username>
```

## AI Chess Analyst

The chess analyst and coach are powered by [ai.nu](https://github.com/fj0r/ai.nu). These steps assume both repos are cloned as siblings (`../ai.nu` resolves to the ai.nu repo).

### One-time provider setup

```nu
use ../ai.nu/ai/mod.nu *

# Register your provider (OpenAI or any OpenAI-compatible endpoint)
{
    name:          openai
    baseurl:       'https://api.openai.com/v1'
    model_default: 'gpt-4o'
    api_key:       'sk-YOUR-KEY'
    temp_max:       1.0
} | ai-config-upsert-provider

ai-switch-provider openai
```

### Running the analyst

Load both modules at the start of your session:

```nu
use ../ai.nu/ai/mod.nu *   # initialises AI_STATE, AI_SESSION, AI_TOOLS, AI_PROMPTS
use ./ai/mod.nu *           # registers chess tools and prompts
```

Then query your games in plain English:

```nu
"What are my main tactical weaknesses?" | chess analyst

"How does my endgame performance compare to my opening?" | chess analyst

"Show me my worst unreviewed moves" | chess analyst
```

The analyst has access to profiling tools and can write arbitrary SQL queries against `chess.db` via `query_chess_db`.

### Socratic coach (per position)

```nu
# Enrich a position record with a coaching question
$position_json | chess coach
```

`chess coach` expects a JSON record with `fen`, `player_elo`, `concepts`, and `scores` fields (the shape output by `chessdb hugm-eval`). It adds `pgn_comment`, `socratic_question`, and `lesson_point` fields.

---

## Pipeline

```
INGEST              DERIVE                          COACH (on-demand)
──────────          ──────────────────              ─────────────────
chess-sync     →    chess-derive              →     chess analyst  (ai.nu)
positions           Welford baselines               chess coach    (ai.nu)
moves               z-score anomalies               chess-profile
                    Markov transitions
```

### INGEST
- `chess-sync <user>` — download games from chess.com, process through HUGM evaluator, store in SQLite
- State encoding: 13-bit `state_id` per ply (phase, fork, pin, hanging, king_exposed, etc.)
- Parallel batch evaluation during import

### DERIVE
- `chess-derive <user>` — Rust `derive-coach-signals` computes per-player Welford baselines, z-score anomalies, and Markov state transitions

### COACH
- `chess analyst` (ai.nu) — conversational analyst; uses profiling tools and SQL to answer natural-language questions
- `chess coach` (ai.nu) — Socratic coaching for a single position record
- `chess-profile` — per-player breakdown: eval swings by phase, positional components, concept frequency × severity, recent anomalies

## Commands

All commands accept `--db <path>` to override the default `./chess.db`.

| Command | Description |
|---|---|
| `chess-init` | Initialise database schema and seed ECO data |
| `chess-sync <username> [--limit N]` | Download chess.com games with HUGM evaluation |
| `chess-derive <username>` | Compute baselines, anomalies, and transitions |
| `chess-status` | Database record counts and per-player game totals |
| `chess-recent [n]` | Last N games (default 5) |
| `chess-review <game-id>` | Move-by-move HUGM evaluation breakdown |
| `chess-explore <zobrist>` | Move frequencies from a position |
| `chess-seed-openings` | Re-download and re-apply ECO opening data |
| `chess-validate <username> <game-id>` | List and consume unreviewed anomalies for a game |
| `chess-profile <username>` | Comprehensive coaching profile |
| `chess-profile-tactical <username>` | Tactical drill-down (fork/pin/hanging by phase) |
| `chess-profile-precision <username>` | Precision drill-down (eval swings, blunder distribution) |
| `chess-profile-position <username>` | Positional drill-down (eval components, win rates) |
| `chess-profile-opening <username>` | Opening drill-down (ECO repertoire, weak/strong openings) |

## How It Works

- **`nu_plugin_chessdb`** — Rust plugin for all chess semantics
  - HUGM evaluation: 33-row phase table, 11 coefficient arrays (ported from Critter 1.6a)
  - ThreatGraph: shakmaty-powered attack graph → SEE chains → forks/pins/hanging with material consequence
  - StateVector encoding: 13-bit `state_id` per position (phase, material, fork, pin, hanging, king)
  - ELO-gated concept ranking: `gated_issues` output with severity × elo_relevance × confidence

- **Cognitive Coach**
  - Per-player Welford baselines: mean/std for eval swings and per-concept tracking
  - Anomaly detection: z-score flags moves unusual *for this player*
  - Transition risk: Markov state transitions with blunder rates
  - Positional profiling: eval component breakdown (pawns, activity, king safety) by color and phase
  - Socratic enrichment: ELO-gated concepts fed to `chess coach` for position-level annotation

## Plugin Commands

| Command | Description |
|---|---|
| `chessdb hugm-eval` | HUGM decomposed evaluation (FEN → scored concepts, gated_issues) |
| `chessdb process-corpus` | Parse game JSON arrays → structured records with HUGM eval |
| `chessdb derive-coach-signals` | Batch Welford baselines + z-score anomaly detection + state transitions |
| `chessdb pgn-to-batch` | Multi-game PGN → batch records |
| `chessdb zobrist` | Compute Zobrist hash from FEN |

## Database

SQLite with tables: `games`, `positions`, `moves`, `move_states`, `player_baselines`, `move_anomalies`, `transition_events`.

Query directly in Nushell:

```nu
open chess.db | query db "SELECT ..."
```
