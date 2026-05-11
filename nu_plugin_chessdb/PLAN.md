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