PLAN: Additions & Roadmap for Critter Evaluation Enhancements

Location
- File to add: nuchessdb/nu_plugin_chessdb/PLAN.md
- Relevant codebase: nuchessdb/nu_plugin_chessdb/src/eval/position.rs (existing HUGM logic, formerly called "critter")

Purpose
- Capture the source rationale for proposed evaluation features, concrete tasks required to implement each one, testing guidance, and the planned (deferred) tuning strategy using an ELO-weighted chess database traversal.
- This is a design and implementation reference for future contributors; it does not change code now.

Assumptions
- Keep changes minimal and surgical: add new heuristics and terms without renaming or removing existing groups/fields.
- All features should remain static, explainable heuristics (no search-based evaluation inside HUGM). Search-based calibration or additional tactical checks may be performed later as a separate pass.
- Performance: bitboard operations must be used; new computations should keep per-position complexity small (O(squares) or bitboard ops) so batch processing remains fast.

High-level goals
1. Improve human-readable diagnostics (for coaching) by adding motif detectors and more explicit terms (tactical motifs, tropism, rook activity, mobility, outposts).
2. Preserve backwards compatibility of PositionRecord schema (add terms to existing groups or add new groups, but do not remove fields).
3. Defer heavy tuning. Initial feature weights will be guessed and annotated. Final tuning will be done by traversing a large ELO-graded game corpus (e.g., lichess DB) and updating weights based on game outcomes and the evaluations that contributed to a chosen move.

Priority feature list (short)
- A: Tactical motif detectors (pins, forks, skewers, discovered attacks)
- B: King tropism / attacker strength term
- C: Rook open-file / 7th / doubled detection
- D: Piece mobility per piece type + optional PSTs
- E: Outpost / blockade detection
- F: Pawn majority / minority and break potential (longer term)
- G: Endgame-specific overrides & king-activity bonuses

For each feature: source and rationale
- Tactical motifs (A)
  - Source: chessprogramming.org tactical motif pages; common human-understood motifs.
  - Rationale: High value for coaching and for identifying tactical "culprits" behind quick eval drops.

- King tropism (B)
  - Source: chessprogramming.org evaluation: tropism and king attack heuristics.
  - Rationale: Complements king_safety by quantifying attacker proximity and trajectories.

- Rook activity (C)
  - Source: evaluation pages: rook on open file, rook on seventh, doubled rooks.
  - Rationale: Common human plans and easy-to-compute signals useful for coaching.

- Mobility & PST (D)
  - Source: mobility metrics and piece-square tables on chessprogramming.org.
  - Rationale: More granular activity signals and a compact PST mechanism for small positional gains.

- Outpost / blockade (E)
  - Source: pawn structure evaluation and outpost notions.
  - Rationale: Explain why certain squares are strategically strong (e.g., knight on outpost).

- Pawn-majority/break potential (F)
  - Source: advanced pawn structure heuristics.
  - Rationale: Detect plan opportunities like minority attack; higher implementation complexity and tuning needs.

- Endgame overrides (G)
  - Source: endgame heuristics: king activity, opposition, rook vs minor, K+P handling.
  - Rationale: Improve evaluation accuracy in low-material scenarios.

Concrete tasks per feature (developer checklist)
- Tactical motifs (A)
  1. Design motif detectors: detect_pins(board), detect_skewers(board), detect_forks(board), detect_discovered(board).
  2. Implement bitboard-based pattern checks in position.rs alongside other helpers.
  3. Add motif counts and a small weighted mg/eg contribution into an existing group (strategic or new tactical subterms in strategic/group "vector_features").
  4. Unit tests: small FENs demonstrating each motif and asserting presence of new terms.

- King tropism (B)
  1. Implement attacker_distance_sum(board, color) or weighted tropism function.
  2. Add term to king_safety or vector_features with mg/eg split via phase_split.
  3. Unit tests with attacking-piece proximity positions.

- Rook activity (C)
  1. Implement open_file_control(board, color) and rook_on_seventh(board, color) checks; detect doubled rooks.
  2. Add terms into piece_activity (rook_7th, open_file_controlled, doubled_rooks).
  3. Unit tests with rooks on 7th and open-file positions.

- Mobility & PST (D)
  1. Add mobility counters per piece type inside piece_activity_score.
  2. Optionally add static PST arrays (mg and eg) and accumulate pst_sum term.
  3. Unit tests verifying mobility and PST terms exist and are numeric.

- Outpost / blockade (E)
  1. Implement detection of outpost squares (defended by pawn, not attackable by opponent pawn) and blockaded passed pawns.
  2. Add terms to pawn_structure and piece_activity.
  3. Unit tests for canonical outpost/blockade positions.

- Pawn majority / break potential (F)
  1. Heuristic detection of flank majority and simple break templates (e.g., queenside minority structures).
  2. Add terms to pawn_structure and strategic.
  3. Integration tests on sample openings.

- Endgame overrides (G)
  1. Identify low-material thresholds and implement targeted adjustments (king activity bonus, simplified K+P rules).
  2. Add tests for relevant endgame FENs.

Testing & validation
- Unit tests: add test cases to the bottom of position.rs like the existing tests. Each new feature must have at least one test FEN and assertions verifying term existence and reasonable sign.
- Integration validation: run batch over a small game sample to ensure performance impact is minor (time per position should remain low). Use existing bench timing reported in README as baseline.

Tuning strategy (deferred, planned exercise)
- Initial weights: will be guessed and annotated directly in code (constants near function definitions). Annotate each constant with a "GUESS" comment.
- Final tuning idea (major project):
  1. Traverse a large ELO-sorted lichess/chessdb corpus.
  2. For each move in a game, record the HUGM evaluation terms for the position before the move and which term(s) changed in the move's delta (the candidate "influencers").
  3. Attribute game outcome (win/loss/draw) to the move(s) and to the influencing terms (this attribution model must be designed; simplest approach: credit the primary term that changed most in magnitude toward the final outcome).
  4. Aggregate statistics per-term by ELO buckets and compute reward multipliers (increase weights for terms that historically correlate with better W/L/D outcomes, decrease otherwise).
  5. Iterate: re-evaluate corpus and refine attribution heuristics (moving averages, smoothing, regularization to avoid overfitting).
- Note: this is a research exercise: careful design of attribution and ELO binning is necessary. Expect to store intermediate results (term -> influence -> outcome) in a separate analytics DB table and iterate offline.

Engineering notes & conventions
- Keep new constants grouped near the top of position.rs (similar to material coeff table) with descriptive names.
- Add only additive terms to GroupValue. Avoid renaming existing fields. New groups are acceptable if they are pure additions (e.g., tactical_motifs: GroupValue).
- Add doc comments for each new helper function and reference chessprogramming pages where appropriate.
- Keep PRs small and focused: one PR per feature cluster (e.g., PR for tactical motifs + tests, PR for tropism + rook activity, etc.).

Milestones / timeline suggestion
- Week 1: Implement A (tactical motif detectors) + B (tropism) with tests.
- Week 2: Implement C (rook activity) + D (mobility counters) with tests.
- Week 3-4: Implement E (outposts) and add initial endgame rules (G).
- Later: Plan and implement the tuning/training pipeline with corpus traversal.

Notes for future implementer
- Scores will be guessed initially and labeled as GUESS in code. We will not attempt to tune weights until we run the corpus exercise described above.
- The tuning exercise is a major effort (data engineering + careful attribution logic). We intentionally separate feature engineering from tuning to keep progress iterative and reviewable.

References
- chessprogramming.org/Evaluation — canonical list of human-understood evaluation concepts used here as source material.
- Existing codebase file: nuchessdb/nu_plugin_chessdb/src/eval/position.rs

Contact
- If you want me to implement a first PR (tactical detectors + tropism + tests) I can draft the code and tests next.
