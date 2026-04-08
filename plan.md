# Plan

## Completed Steps

### Step 1 ✅ — Fix circular dependency in `critter-eval`
`critter-eval` no longer depends on `nu_plugin_shakmaty` at all — both are inlined into `nu_plugin_chessdb`.

### Step 2 ✅ — Add `chessdb critter-eval` plugin command
Implemented in `nu_plugin_chessdb/src/critter_eval_cmd.rs`. Takes FEN from pipeline, optional `--engine-score(-e): int`, returns a full critter-eval record.

### Step 3 ✅ — Update `nuchessdb/modules/critter.nu`
Replaced subprocess + NDJSON parse loop with direct `chessdb critter-eval` plugin call.

### Step 4 ✅ — Remove JSON handoff at the boundary
In-process Nu objects replace all NDJSON line protocol.

### Step 5 — Keep the first release query-only
- Initial release promise: create a SQLite database that users can query
- Do not treat `nuchessdb` itself as an insight engine

### Step 6 ✅ — Consolidate plugins for Nu-native data flow

- Combined `nu_plugin_shakmaty`, `critter-eval`, and key components of `chess-vector-engine` into `nu_plugin_chessdb`
- `nu_plugin_chessdb` lives inside this repository (`./nu_plugin_chessdb/`)
- Commands renamed from `shakmaty *` to `chessdb *` throughout all `.nu` modules
- Added `chessdb critter-eval` (full position evaluation) and `chessdb encode-fen` (1024-element position vector)
- `vector_features` eval group added to critter-eval scoring: `center_control_score`, `piece_coordination_score`, `tactical_pressure_score`
- Both `test_quickstart_pipeline.nu` and `test_readme_commands.nu` pass

### Step 6b ✅ — Add `strategic` eval group to `chessdb critter-eval`

- `strategic_score()` function added to `eval/position.rs`: initiative, attacking_bonus, safety_penalty, coordination terms
- `EvalGroups` struct and `sum_groups()` / `compute_groups()` updated to include `strategic`
- `critter.nu` type annotation and fixture record updated to include `strategic` group
- `strategic` contributes to `final_score` alongside `vector_features`

### Step 6c ✅ — Add `chessdb nnue-eval` command

- Implemented in `nu_plugin_chessdb/src/nnue_eval_cmd.rs`
- Takes FEN from pipeline + `--weights(-w) <path>` flag pointing to a chess-vector-engine JSON weight file
- Hand-rolled forward pass: input(768) → feature_transformer → ClippedReLU → N hidden layers → output × 600 = centipawns
- Optionally loads `.config` sidecar file for `NnueConfig` (hidden_size, num_hidden_layers)
- Returns `{score_cp, score_pawns, weights_path, config}` record
- Tested with `default_hybrid.weights` (starting position → ~93 cp)

### Step 7 ✅ — Bootstrap ECO data locally

- `eco.json` ships with the repository (499 ECO entries, `data/eco.json`)
- `init-db` now calls `ensure-eco-data` which validates the file is present before proceeding
- If missing, errors with recovery instructions: `git checkout -- data/eco.json`

### Step 8 — Player introspection reports

Generate `.md` reports in `reports/`, with transient `.nuon` intermediates in `reports/.cache/`.
Each phase builds on the previous phase's cached results.

**Phase 1: Game-level facts** ✅ DONE
1. `color-performance.md` — Win/draw/loss split as White vs Black
   - SQL → `reports/.cache/color.nuon` → markdown
2. `rating-bands.md` — Results vs lower/equal/higher-rated opponents
   - SQL → `reports/.cache/rating-bands.nuon` → markdown (reads `color.nuon` for context)
3. `time-control.md` — Performance by blitz/rapid/classical
   - SQL → `reports/.cache/time-control.nuon` → markdown

**Phase 2: Positional patterns** ✅ DONE
4. `opening-repertoire.md` — Your most common first 10-15 moves and outcomes
   - SQL + `eco.json` → `reports/.cache/openings.nuon` → markdown
5. `frequent-losses.md` — Positions you lose from most often
   - SQL → `reports/.cache/loss-positions.nuon` → markdown
6. `frequent-wins.md` — Positions you convert well
   - SQL → `reports/.cache/win-positions.nuon` → markdown

**Phase 3: Enriched insights (after critter eval)** ✅ DONE
7. `position-profiles.md` — Classify positions using critter decomposed terms:
   - Open vs closed (piece activity vs pawn structure blended score)
   - Tactical vs strategic (activity + |safety| vs |pawn| + |passed pawns|)
   - Dynamic vs positional (|development| + |safety| vs |pawn| + |passed pawns|)
   - Reads critter evals via `json_extract` → `reports/.cache/profiles.nuon` → markdown

**Phase 4: Synthesis** ✅ DONE
8. `playstyle-summary.md` — Your tendencies across all dimensions
   - Reads all `.nuon` caches → markdown
   - At a Glance table, per-section breakdowns, auto-generated Strengths/Weaknesses
   - Gracefully handles missing caches (per-section "run phase N first" notes)

Each phase's `.nuon` files are transient intermediates — cheap to regenerate, useful for downstream reports, and don't pollute the DB.

### Step 9 ✅ — AI query primer

- `docs/query-primer.md` — compact schema + query-pattern guide for an AI writing gameplay SQL
- Covers: DB connection, all table schemas, key conventions (is_me filter, color determination,
  result notation, position identity, FEN matching, JSON eval columns, time-control parsing)
- Common query patterns: win rate, position stats, critter eval joins, opponent record,
  position history, move frequency
- Gotchas section: NULL ELOs, NULL time_control, position_id vs canonical_hash,
  multi-platform is_me, occurrences semantics, final_score sign, ply 0

---

## Future: UCI engine daemon

A standalone Rust binary (new sibling project) that speaks the full UCI protocol
on stdin/stdout, pluggable into chess GUIs like Arena or the Lichess Board editor.

**Behavior:**
- On `position` command: parse the position, look up the Zobrist hash in nuchessdb
- On `go`: query `game_positions` for moves `accounts.is_me = 1` has played from that position;
  pick one proportionally by raw frequency; respond `bestmove <uci>`
- If no history: respond `bestmove 0000` and send
  `info string novel position — engine only reflects recorded playing style`
- Annotations: future work; `annotations` table in the schema is the intended home but nothing
  writes to it yet

**Key SQL:**
```sql
SELECT gp.move_uci, COUNT(*) AS frequency
FROM game_positions gp
JOIN accounts a ON a.id = gp.mover_account_id
JOIN positions p ON p.id = gp.position_before_id
WHERE p.canonical_hash = ?
  AND a.is_me = 1
GROUP BY gp.move_uci
ORDER BY frequency DESC
```
Then pick proportionally (weighted random by `frequency`).
