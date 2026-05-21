# nuchessdb

A Nushell-first chess database and coaching pipeline. Import games from chess.com, run HUGM decomposed evaluation, derive per-player coaching baselines, and generate AI coaching via nu-agent.

## Quick Start

```sh
cd nu_plugin_chessdb && cargo build --release
nu -c 'plugin add nu_plugin_chessdb/target/release/nu_plugin_chessdb'
nu nuchessdb.nu init
nu nuchessdb.nu sync <your-chesscom-username>        # full sync
nu nuchessdb.nu derive-coach <your-username>          # compute baselines
nu nuchessdb.nu coach-profile <your-username>         # view your profile
nu nuchessdb.nu coach-review <game-id> <white|black>   # AI coaching
```

## Pipeline

```
INGEST (fast)       DERIVE (async)                  COACH (on-demand)
───────────         ────────────────                ─────────────────
sync/import    →    derive-coach.nu            →    coach-review
positions           dictionary-update.nu            coach-profile
moves              validate-gate.nu
```

### INGEST
- `sync <user>` — download games from chess.com, process through HUGM evaluator, store in SQLite
- State encoding (13-bit state_id per ply: phase, fork, pin, hanging, king_exposed, etc.)
- Rayon-parallel batch evaluation during import

### DERIVE
- `derive-coach.nu` — batch pass: Rust `derive-coach-signals` computes per-player Welford baselines, z-score anomalies, and Markov state transitions
- `dictionary-update.nu` — incremental Tier-1000 Welford update from `gated_issues`, tracks collapse accuracy vs SEE optimal chains
- `validate-gate.nu` — anomaly intercept gate: reads `move_anomalies`, emits 3-line JSON shutdown block for nu-agent

### COACH
- `coach-review` — anomaly-first evaluation → ELO-gated concept ranking → nu-agent Enrich contract → LLM Socratic coaching
- `coach-profile` — per-player breakdown: eval swings by phase, positional components (pawns/activity/king by color), concept frequency × severity, recent anomalies, JSON mode for LLM enrichment

## Core Commands

All commands: `nu nuchessdb.nu <command> [args]`

| Command | Description |
|---|---|
| `init` | Initialize database schema |
| `sync <username> [--limit N]` | Download chess.com games, import with HUGM eval |
| `derive-coach <username>` | DERIVE phase: batch baselines, anomalies, transitions |
| `dictionary-update <username> [--limit N]` | Incremental Tier-1000 concept Welford update |
| `validate-gate <username> <game-id>` | Anomaly intercept — 3-line JSON shutdown block |
| `coach-review <game-id> <white\|black>` | LLM-powered Socratic coaching per anomaly |
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
  - Socratic enrichment: ELO-gated concepts fed through nu-agent Enrich contract

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
