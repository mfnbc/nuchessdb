# Coach Architecture — Per-Player Anomaly Detection

## Design principle

The coach says "this move was unusual *for you*" not "this position is bad."

Three layers on top of the evaluation pipeline:
1. **Normalization** — what's normal for this player?
2. **State encoding** — what kind of position is this?
3. **Transition risk** — has this player struggled here before?

## Layer 1: Per-player z-score

raw_delta = -40cp means different things: normal for 1000-rated, alarming for 2000-rated.

```
z_delta = (current_delta - player_mean) / player_std
```

Per concept (material, king_safety, etc.), from player's game history.

## Layer 2: Markov state encoding

Compact `state_id: u16` bitfield per ply:

```
StateVector {
    phase: u8,              // 0-3 (2 bits)
    material_sign: i8,      // -2..+2 (3 bits + sign)
    king_exposed: bool,     // 1 bit
    in_check: bool,         // 1 bit
    has_fork: bool,         // 1 bit
    has_pin: bool,          // 1 bit
    has_hanging: bool,      // 1 bit
    has_outpost: bool,      // 1 bit
    open_file: bool,        // 1 bit
    has_passed_pawn: bool,  // 1 bit
}
// 13 bits → fits in u16
```

Deterministic: same position → same state_id. All concepts already detected by `build_sensor_report`.

Transition tracking per player:
```
P(blunder | state_A → state_B) = blunder_count / transition_count
```
Blunder = material loss > 200cp within 5 plies.

## Layer 3: Pressure/blunder correlation

For each anomaly, what state was the position in?

- What % of blunders occur under tactical pressure (fork, hanging, king exposed)?
- What's the baseline pressure rate? (How often does this player face pressure?)
- Is the player 4.5× more likely to blunder under pressure?

This is stored in `move_states` (per-ply concept flags) joined with `move_anomalies`.

## Derived tables (separate from core analytics)

```
player_baselines (username, concept_name, phase_bucket, mean, m2, count, last_updated)
move_states (game_id, ply, state_id, phase_bucket, has_fork, has_pin, has_hanging, king_exposed)
move_anomalies (username, game_id, ply, anomaly_type, concept_name, z_score, severity, consumed)
transition_events (username, state_from, state_to, total_count, blunder_count)
dict_update_marker (username, game_id, ply)
```

## Pipeline

```
INGEST (fast)          DERIVE (async — three scripts)            COACH (on-demand)
───────────            ─────────────────────────────            ─────────────────
sync/import       →    derive-coach.nu                     →    coach-review
                       (batch: baselines + anomalies             coach-profile
                        + transitions via Rust plugin)
                       
                       dictionary-update.nu
                       (incremental: Tier-1000 Welford
                        from gated_issues, collapse accuracy)
                       
                       validate-gate.nu
                       (anomaly intercept: 3-line JSON
                        shutdown block for nu-agent)
```

## Positional components

`coach-profile` displays average pawn structure, piece activity, and king safety
scores by color (white/black) and phase (endgame/late_mid/midgame/opening).
Queries `hugm_eval_arr` from positions table, parses JSON arrays, groups by color and phase.

This reveals positional signatures — e.g., shoddyfischer's Black midgame pawn collapse
(-16cp vs pool) while MorphyUltra shows no detectable positional weakness (all deltas ±0.5cp).

## Collapse accuracy

`dictionary-update.nu` compares player moves against SEE-optimal recapture chains from
ThreatGraph. Tracks:

- `collapse_accuracy` — % of SEE-optimal gain achieved (0% = missed the win, 100% = optimal)
- `collapse_miss_cp` — centipawns left on table when missed
- Unfavorable exchanges: optimal is to AVOID. Walking into a losing exchange scores 0% accuracy.

## ELO-gated concept ranking

The `gated_issues` field in `sensor_report` contains concepts ranked by:
`score = magnitude × severity × elo_relevance × confidence`

ELO thresholds (from `concepts.rs`):
| Tier | ELO | Concepts |
|---|---|---|
| Survival | 600 | material_imbalance, king_in_check, hanging_piece |
| Threat | 1000 | fork, pin, skewer, discovered_attack |
| Positional | 1400 | outpost, rook_open_file, rook_seventh, passed_pawn, king_exposed, development |
| Strategic | 1600 | bishop_pair, pawn_majority, pawn_break, minority_attack |

Concepts above the player's ELO are visible but damped: `elo_relevance = 0.5^((elo_min - player_elo) / 200)`.

## Implementation status

1. ✅ `StateVector` + `encode_state()` in concepts.rs
2. ✅ `state_id` in plugin output (process_corpus, hugm-eval)
3. ✅ `move_states` table in schema
4. ✅ Per-player Welford baseline aggregation (derive-coach via Rust plugin)
5. ✅ Transition matrix population (transition_events)
6. ✅ Anomaly detection wired into coach-review
7. ✅ Per-concept baselines (fork, pin, hanging_piece tracked separately)
8. ✅ ELO-gated concept ranking (gated_issues in sensor_report)
9. ✅ Dictionary update with collapse accuracy (dictionary-update.nu)
10. ✅ Anomaly intercept gate (validate-gate.nu)
11. ✅ Positional component profiling (coach-profile with hugm_eval_arr parsing)
12. ✅ Pressure/blunder correlation (move_states × move_anomalies join)
13. ✅ Rayon-parallel batch evaluation (process_corpus par_iter)
14. ✅ Critter concept parity (weighted king attacks, mobility mask, pawn shelter, rook-on-7th)
