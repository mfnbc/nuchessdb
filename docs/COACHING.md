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

Per concept (material, king_safety, etc.), from player's game history, recency-weighted.

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
// ~13 bits → fits in u16
```

Deterministic: same position → same state_id. All concepts already detected by `build_sensor_report`.

Transition tracking per player:
```
P(blunder | state_A → state_B) = blunder_count / transition_count
```
Blunder = material loss > 200cp within 5 plies.

## Layer 3: Recency decay

When computing baselines: `weight = exp(-age_days / 30)`. Half-life of 30 days.

## Derived tables (separate from core analytics)

```
player_baselines (username, concept_name, mean, std, count, updated)
move_states (game_id, ply, state_id, phase, has_fork, has_hanging, king_exposed)
transition_events (username, state_from, state_to, count, blunder_count, updated)
```

## Pipeline

```
INGEST (fast) → positions, moves (scalar store)
DERIVE (async) → encode states, update baselines, track transitions
COACH (on-demand) → detect anomalies, rank, feed LLM
```

## Implementation order

1. Add `StateVector` + `encode_state()` to `concepts.rs`
2. Expose `state_id` in plugin output
3. Add `move_states` table to schema
4. Per-player baseline aggregation
5. Transition matrix population
6. Wire anomaly detection into `coach-review`
