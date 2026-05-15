PLAN: HUGM (Human GM) evaluation — roadmap, status, and schema

Purpose
- Document goals and engineering plan for HUGM (formerly "critter") static evaluation.
- Provide a compact status update, a structured explanation JSON schema for consumers (nu-agent/LLMs), and a short actionable plan.

High-level goals
- Static, explainable bitboard heuristics (no search inside HUGM).
- Human-readable annotations (phrases + structured JSON) useful for coaching and LLM consumption.
- Default analytics-friendly numeric output; verbose mode (--verbose / -v) emits explanations + structured annotations.
- Centralize guessed weights and provide a runtime override (--weights) for experimentation without recompilation.

Status summary (by feature)
- A: Tactical motifs (pins, forks, skewers, discovered)
  - Status: DONE. Implemented detect_pins, detect_forks, detect_skewers, detect_discovered. Examples stored in tactical.terms (fork_example_us, skewer_example_us, etc.). Unit tests present.

- B: King tropism
  - Status: DONE. king_tropism_score implemented and integrated into king_safety_group.terms.

- C: Rook activity (open files, 7th, doubled)
  - Status: DONE. Open-file control, rook-on-7th, doubled-rooks detected and included in piece_activity terms.

- D: Mobility & PST (per-piece mobility counters + PST hook)
  - Status: PARTIAL. Many per-piece heuristics exist in piece_activity_score but explicit mobility counters and PST arrays/hooks are not yet added.

- E: Outpost / blockade
  - Status: DONE (basic). detect_outposts implemented and example context returned; blockades not fully fleshed beyond passed pawn scoring.

- F: Pawn-majority / break potential
  - Status: NOT IMPLEMENTED. Candidate for next phase.

- G: Endgame overrides & king-activity bonuses
  - Status: PARTIAL. win_chance_scale() and draw heuristics exist; explicit small-material overrides or K+P rules not added as a dedicated feature.

Infrastructure & tooling
- Weights centralization: DONE. GUESS weights collected; Weights struct + WEIGHTS global added. Runtime override via set_weights_from_file(path) and --weights CLI flag.
- CLI: chessdb hugm-eval: default analytics-only outputs numeric groups (hugm_score, hugm_eval_arr). --verbose / -v adds "explanations" and "explanations_structured" arrays. --weights / -w loads a JSON weights file.
- Clippy: applied low-risk fixes; clippy-clean and unit tests (15) pass.

Structured explanation JSON (schema & example)
- Purpose: give a compact, predictable shape that nu-agent and LLM prompts can rely on.

Schema (concise)
- explanations_structured: array of Explanation objects.
- Explanation object:
  - kind: string (e.g., "fork", "pin", "skewer", "outpost", "rook_open_files", "none")
  - side: string ("white" or "black") — whose features are being reported
  - severity: integer (signed centipawn-like magnitude or simple count)
  - phrase: short human-readable string summarizing the observation
  - details: object with motif-specific keys (see examples)

Example (JSON-like)
- Single fork explanation example:
  {
    "kind": "fork",
    "side": "white",
    "severity": 80,
    "phrase": "White has 1 fork(s) detected (e.g. Nd5 forks Qf6 and Rb6).",
    "details": {
      "example": {
        "attacker": "Nd5",
        "targets": ["Qf6", "Rb6"]
      }
    }
  }

- Skewer example:
  {
    "kind": "skewer",
    "side": "white",
    "severity": 40,
    "phrase": "White has a skewer (e.g. Rg7: Rf7 -> Qf8).",
    "details": { "example": { "attacker": "Rg7", "front": "Rf7", "back": "Qf8" } }
  }

- Outpost example:
  {
    "kind": "outpost",
    "side": "black",
    "severity": 40,
    "phrase": "Black has 1 outpost(s) (e.g. Nb4 supported by c5).",
    "details": { "example": { "square": "b4", "role": "N", "support": "c5" } }
  }

Notes on schema
- details is intentionally flexible; motif detectors should place a small structured object under details.example for immediate consumption.
- severity may be a small signed integer (centipawn-ish) or a motif count depending on context. Consumers should treat it as a signed integer representing importance; phrase supplies natural-language text.

Compact actionable plan (short-term next steps)
1. Add schema snippet to PLAN.md (done here).
2. Implement --examples N (default 1): return up to N motif examples per motif when verbose. Tests: ensure arrays length ≤ N. (Next-highest priority.)
3. Add per-piece mobility counters and PST hook in piece_activity_score (D). Expose PST enable via weights or a toggle flag. Add tests.
4. Expand detectors to return multiple examples (fork_examples_us -> Vec<...>) and update render_structured_explanations accordingly.
5. Implement pawn-majority/break potential heuristics (F) and add tests/PR.
6. Add optional persistable weights profiles and an example weights JSON file in repo (eval/weights_example.json). Update README with a short usage snippet.
7. When features are stable, design and run the corpus-based ELO tuning pipeline (research project).

Longer-term ideas (deferred)
- Attribution model for corpus-driven tuning (term → move influence → game outcome).
- LLM-driven summary templates and coach-grade suggestions built on structured explanations.
- PST/NNUE co-training: expose hooks to swap/tune PSTs alongside NNUE models.

How I can help next
- Implement --examples N and wire detectors to return up to N examples (code + unit tests).
- Add mobility counters + PST hook and tests.
- Add example weights file and small README snippet documenting the available keys.

If you want to proceed, pick one from:
- "--examples N" implementation (recommended next step),
- mobility & PST (next-high impact),
- add example weights file + docs (small), or
- start the corpus/tuning design notes (larger research task).


Contact
- File location: nuchessdb/nu_plugin_chessdb/src/eval/position.rs (core); hugm eval entry: nuchessdb/nu_plugin_chessdb/src/hugm_eval_cmd.rs
- Repo branch: hugm


Validation & Tuning Plan (detailed — follow-through)

Goal
- Ensure HUGM detections are precise (avoid hallucination), explainable, and improve iteratively using canonical examples and real-world corpora before large-scale weight tuning.

Phase A — Canonical examples & unit tests (immediate)
- Curate canonical FENs from chessprogramming.org (and other authoritative motif pages) for each motif (pins, forks, skewers, discovered, outposts, pawn-majority/minority, pawn-breaks).
- Add these as deterministic unit tests (tests/motif_examples.rs or expand existing tests) asserting:
  - detector count > 0 for positive examples, = 0 for negatives;
  - structured example objects reference the expected attacker/pawn/square when verbose.
- Acceptance: canonical suite should pass with high precision (close to 100%).

Phase B — Small labeled corpus + evaluation harness (short term)
- Create a compact labeled dataset (JSONL) of positions with ground-truth labels per motif.
- Implement a harness (Rust or script) that runs hugm-eval --verbose over the dataset, extracts structured_explanations, and computes per-motif TP/FP/FN, precision, recall, F1.
- Workflow: run harness → inspect top FP examples → adjust detectors/thresholds → repeat.

Phase C — Real-world sampling and human review (medium term)
- Sample positions stratified by ELO from a large corpus (e.g., Lichess monthly dumps).
- Run HUGM verbose on sample; surface detected examples per motif to a human review step (CSV or small UI) for labeling.
- Use reviewed labels to estimate real-world precision and guide detector refinement.

Phase D — Algorithmic weight tuning (deferred research)
- After detectors are validated, implement an attribution model to map move deltas to influencing terms and then aggregate outcomes by ELO bucket.
- Use aggregated statistics to propose weight updates (regularized optimization, grid/hillclimb, or regression) with holdout validation to prevent overfitting.
- Iterate until improvements generalize across ELO buckets.

Policy: Stockfish evaluation handling
- Do NOT persist Stockfish numeric evaluations as canonical fields in the positions table by default. Stockfish is a computational oracle used for two purposes: (1) on‑demand review and (2) ephemeral labeling for training. Persisting engine scores in the primary analytics DB biases the canonical dataset toward machine judgments and reduces the pedagogical, human‑interpretable clarity of HUGM outputs.
- Operational rules:
  - On‑demand review: provide a `review` path that runs Stockfish live and returns an ephemeral evaluation to the user; do not store those numbers automatically.
  - Labeling for training: when Stockfish labels are required, generate them in a separate labeling pipeline and store them only in training shards/manifest (NPZ/JSON) with full provenance (engine version, parameters, date).
  - Auditability: record the labeling run metadata in the dataset manifest; do not bake engine outputs into the main positions table unless explicitly requested.

Operational notes
- Default pipeline: continue to emit only scalars (hugm_score/hugm_eval_arr) for corpus ingestion.
- Verbose-only: structured examples are emitted only when --verbose is passed; these are not stored by default to avoid DB bloat.
- Weights: keep WEIGHTS runtime override for fast experimentation; persist profiles separately if/when needed.

Immediate next tasks I will follow (and can implement):
1. Curate canonical examples from chessprogramming and add them as unit tests. (I can start this immediately.)
2. Implement the evaluation harness that runs HUGM verbose over a labeled JSONL and produces a metrics report (TP/FP/FN, precision/recall) and exports the top false positives for review.
3. Iterate detectors based on harness findings; re-run tests and harness until canonical precision is high.
4. When satisfied, expand the labeled corpus and perform ELO-stratified sampling and review before any automated tuning.

If you approve, I will begin with task 1 (canonical examples + tests) and then implement the harness (task 2).

Current curation & status snapshot
- Canonical tests added: nu_plugin_chessdb/tests/motif_canonical.rs
  - Sources used: chessprogramming.org, Wikipedia (pawn examples), representative Lichess-style positions.
  - Covered motifs (canonical-positive tests): pins, forks, skewers, discovered, outposts, rook open-file/7th/doubled, passed pawns, isolated pawns, pawn-majority/minority (basic), pawn-break candidate, tactical pressure (rook aligned), hanging pieces, center control.
- Coverage gap (remaining prioritized list):
  1. Mobility counters & PST examples (not yet implemented)
  2. Rich minority-attack plan templates and move-sequence examples (we added a strength heuristic but more templates are desirable)
  3. Negative/near-miss canonical cases for each motif (to guard against hallucination)

Resuming work later (checkpointing)
- All changes are isolated under the hugm branch. Key files to review when returning:
  - Core: src/eval/position.rs (detectors, WEIGHTS, added pawn-structure heuristics)
  - CLI: src/hugm_eval_cmd.rs (--verbose, --weights hooks)
  - Tests: tests/motif_canonical.rs (canonical examples)
  - PLAN: this file (validation & tuning plan)
- To pause and resume safely:
  1. Ensure tests pass: cargo test.
  2. If you want to snapshot the current weights, create a JSON weights profile via the Weights struct keys and store alongside the repo (e.g., eval/weights_profile.json).
  3. Continue later from the hugm branch; the canonical tests act as regression guards.

Sidequest note
- You mentioned a sidequest — note it here as an explicit, resumable ticket: "SIDEQUEST: <brief description>". When you provide the sidequest details I'll add it to PLAN.md as a tracked task and can switch focus, run it, and then return to the main validation/tuning pipeline. This keeps context intact when stepping away.

Resumption checkpoint (2026-05-15)
- Core files to review when returning:
  - `src/eval/position.rs` — chaos_coefficient, tiered compute_aggregates, full sensor extractors
  - `src/eval/concepts.rs` — SensorTier enum, tier_for_concept, attenuation matrix
  - `src/eval/sensor.rs` — AggregatedScores.chaos field
  - `src/process_corpus.rs` — state_id in positions output
  - `nuchessdb.nu` — coach-review, derive-coach, import-records with move_states
  - `nu-agent/engine.nu` — CLI main entry point, rag embed fix
  - `nu-agent/config.toml` — model: qwen/qwen3.6-35b-a3b (structured output)

Completed features:
- ✅ SensorReport fully populated (all positional extractors: doubled, isolated, pawn_islands, etc.)
- ✅ MaterialConceptReport with balance from groups
- ✅ state_id in positions table + migrate_states population during ingest
- ✅ coach-review command (anomaly-first, eval-drop fallback, LLM enrichment)
- ✅ derive-coach command (Welford baselines, z-score anomalies, state transitions)
- ✅ Elo Sensor Taxonomy: SensorTier enum, tier_for_concept, attenuation matrix
- ✅ Convergence Gate: chaos_coefficient from tactical sensors, tiered attenuation in compute_aggregates
- ✅ Idempotent sync merge (INSERT OR IGNORE via sqlite3)
- ✅ Nushell 0.111 compat fixes (string interpolation, path self)

Architecture notes:
- The convergence gate solves the digital-switch vs analog-dial problem: survival/threat sensors
  always active, positional sensors dampened at 50% of chaos, strategic sensors fully suppressed.
  chaos_coefficient reads forks+pins+skewers+hanging+in_check+king_exposed from sensor terms.
- The coach pipeline now says "this was unusual *for you*" via per-player z-score baselines.
- Qwen model produces richer Socratic coaching than Gemma; slower but more specific.

Next session:
- Per-concept baselines (extend derive-coach-signals beyond single hugm_delta)
- Attentional profile in coach input (accuracy tracking per concept)
- Anomaly type classification: attention_slip vs skill_deficit vs developmental
- Socratic refinement: less leading questions, more holistic position awareness

---
Known Bugs (last reviewed 2026-05-13)

RESOLVED:
- BUG-1: FIXED — added `board_pieces TEXT` to positions DDL + included in import-records SELECT
- BUG-2: ALREADY FIXED — query uses `m.game_id = g.game_id` correctly
- BUG-3: ALREADY FIXED — played_at extraction from end_time/lastMoveAt/createdAt exists
- BUG-5: RESOLVED — `--with-stockfish` flag removed entirely; Stockfish labeling is a separate pipeline
- BUG-7: FIXED — critter_eval_cmd.rs deleted; use `chessdb hugm-eval` instead
- BUG-8: ALREADY FIXED — help text uses "nuchessdb.nu"

OPEN (non-blocking):
- BUG-4: process_corpus HUGM eval is sequential, not parallel (performance, not correctness)
- BUG-6: Stockfish binary path inconsistency in sf_batch_eval (separate bin, not in core pipeline)

CLEANUP (2026-05-13):
- Removed nnue_eval_cmd.rs (dead file, was just a comment)
- Removed critter_eval_cmd.rs (undifferentiated alias for hugm-eval, BUG-7)
- Removed src/bin/nnue_dataset_builder.rs (duplicate of dataset_builder_cmd plugin)
- Removed --with-stockfish flag from process_corpus (dead, BUG-5)
- Cleaned unused imports in process_corpus.rs and dataset_builder_cmd.rs