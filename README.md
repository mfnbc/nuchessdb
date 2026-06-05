# nuchessdb

A Nushell-first chess database and coaching pipeline. Import games from chess.com, run HUGM decomposed evaluation, derive per-player coaching baselines, and query your games with an AI chess analyst powered by [ai.nu](https://github.com/fj0r/ai.nu).

## Quick Start

```sh
cd nu_plugin_chessdb && cargo build --release
nu -c 'plugin add nu_plugin_chessdb/target/release/nu_plugin_chessdb'
nu nuchessdb.nu init
nu nuchessdb.nu sync <your-chesscom-username>        # full sync
nu nuchessdb.nu derive-coach <your-username>          # compute baselines
nu nuchessdb.nu coach-profile <your-username>         # view your profile
```

## AI Chess Analyst

The chess analyst and coach are powered by [ai.nu](https://github.com/fj0r/ai.nu). These steps assume ai.nu and nuchessdb are cloned as siblings (i.e. `../ai.nu` resolves to the ai.nu repo).

### One-time provider setup

Run this once per machine. It writes your provider credentials into ai.nu's SQLite state file (`$nu.data-dir/openai.db`).

```nu
# Initialise ai.nu (creates openai.db if it doesn't exist)
use ../ai.nu/ai/mod.nu *

# Register OpenAI (or any OpenAI-compatible endpoint)
{
    name:          openai
    baseurl:       'https://api.openai.com/v1'
    model_default: 'gpt-4o'
    api_key:       'sk-YOURKEY'
    temp_max:       1.0
} | ai-config-upsert-provider

# Make OpenAI the active provider
ai-switch-provider openai
```

To use a different model later: `ai-switch-model gpt-4o-mini`

To check the active session at any time: `ai-session`

### Running the analyst

Load both modules at the top of your session (or add to `env.nu`):

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

The analyst has access to profiling tools (`get_coach_profile`, `get_tactical_profile`, `get_precision_profile`, `get_positional_profile`, `get_opening_profile`) and can write and run arbitrary SQL queries against `chess.db` via `query_chess_db`. It figures out who is in the database automatically on the first question.

### Socratic coach (per position)

```nu
# Enrich a position record with a coaching question
$position_json | chess coach
```

`chess coach` expects a JSON record with `fen`, `player_elo`, `concepts`, and `scores` fields (the shape output by `chessdb hugm-eval`). It adds `pgn_comment`, `socratic_question`, and `lesson_point` fields.

---

## Pipeline

```
INGEST (fast)       DERIVE (async)                  COACH (on-demand)
───────────         ────────────────                ─────────────────
sync/import    →    derive-coach.nu            →    chess analyst  (ai.nu)
positions           dictionary-update.nu            chess coach    (ai.nu)
moves               validate-gate.nu                coach-profile
```

### INGEST
- `sync <user>` — download games from chess.com, process through HUGM evaluator, store in SQLite
- State encoding (13-bit state_id per ply: phase, fork, pin, hanging, king_exposed, etc.)
- Rayon-parallel batch evaluation during import

### DERIVE
- `derive-coach.nu` — batch pass: Rust `derive-coach-signals` computes per-player Welford baselines, z-score anomalies, and Markov state transitions
- `dictionary-update.nu` — incremental Tier-1000 Welford update from `gated_issues`, tracks collapse accuracy vs SEE optimal chains
- `validate-gate.nu` — anomaly intercept gate: reads `move_anomalies`, emits 3-line JSON shutdown block

### COACH
- `chess analyst` (ai.nu) — conversational analyst; uses profiling and SQL tools to answer natural-language questions about your games
- `chess coach` (ai.nu) — Socratic coaching for a single position record (adds `pgn_comment`, `socratic_question`, `lesson_point`)
- `coach-profile` — per-player breakdown: eval swings by phase, positional components (pawns/activity/king by color), concept frequency × severity, recent anomalies

## Core Commands

All commands: `nu nuchessdb.nu <command> [args]`

| Command | Description |
|---|---|
| `init` | Initialize database schema |
| `sync <username> [--limit N]` | Download chess.com games, import with HUGM eval |
| `derive-coach <username>` | DERIVE phase: batch baselines, anomalies, transitions |
| `dictionary-update <username> [--limit N]` | Incremental Tier-1000 concept Welford update |
| `validate-gate <username> <game-id>` | Anomaly intercept — 3-line JSON shutdown block |
| `coach-profile <username> [--json]` | Player profile: eval swings, concepts, positional components |
| `review <game-id>` | Move-by-move HUGM evaluations |
| `status` | Database counts (games, positions, moves) |
| `recent [n]` | Last n games |

## How It Works

- **`nu_plugin_chessdb`** — Rust plugin for all chess semantics
  - HUGM evaluation: 33-row phase table, 11 coefficient arrays (ported from Critter 1.6a)
  - ThreatGraph: shakmaty-powered attack graph → SEE chains → forks/pins/hanging with material consequence
  - Weighted king attacks, mobility mask, pawn shelter, rook-on-7th conditional (Critter concept parity)
  - StateVector encoding: 13-bit state_id per position (phase, material, fork, pin, hanging, king)
  - ELO-gated concept ranking: `gated_issues` output with severity × elo_relevance × confidence

- **Cognitive Coach**
  - Per-player Welford baselines: mean/std for eval swings, per-concept (fork, pin, hanging) tracking
  - Anomaly detection: z-score flags moves unusual *for this player*
  - Collapse accuracy: compares player moves against SEE-optimal recapture chains
  - Transition risk: Markov state transitions with blunder rates (e.g., "57% blunder rate when resolving hanging pieces")
  - Positional profiling: component breakdown (pawns, activity, king safety) by color and phase
  - Socratic enrichment: ELO-gated concepts fed to `chess coach` (ai.nu) for position-level annotation

## Plugin Commands

| Command | Description |
|---|---|
| `chessdb hugm-eval` | HUGM decomposed evaluation (FEN → scored concepts, gated_issues) |
| `chessdb process-corpus` | Parse game JSON arrays → structured records with HUGM eval |
| `chessdb derive-coach-signals` | Batch Welford baselines + z-score anomaly detection + state transitions |
| `chessdb pgn-to-batch` | Multi-game PGN → batch records |
| `chessdb zobrist` | Compute zobrist hash from FEN |

### Plugin output

`chessdb hugm-eval --player-elo N` returns per FEN:
```
{ fen, final_score, phase, side_to_move, groups: {...},
  sensor_report: { tactical: {...}, evaluated_forks: [...], 
                   gated_issues: [...], aggregated: {...} } }
```

The `sensor_report.gated_issues` contains ELO-filtered, ranked concepts (name, severity, elo_min, score, phrase) — single source of truth for coaching. No Nushell-side concept extraction needed.

## Database

SQLite with tables: `games`, `positions`, `moves`, `move_states`, `player_baselines`, `move_anomalies`, `transition_events`, `dict_update_marker`.

Query directly in Nushell:
```nu
open chess.db | query db "SELECT ..."
```
