NNUE Audit & Plan — nuchessdb

## 2026-05-13 Update: Re-scoped

**Decision**: Full NNUE training is deferred. The project will import an existing NNUE (Stockfish 18's built-in net, or potentially black-marlin) rather than training one. Bullet-based training pipeline (dataset builder, NPZ shards) is paused.

**New approach**: Stockfish UCI eval via the `chessdb nnue-eval` plugin command (src/nnue_eval_cmd.rs). This spawns Stockfish, sends FENs, parses NNUE evaluation scores, and returns centipawns. Uses `$STOCKFISH_BIN` env var (default: `/usr/sbin/stockfish`).

**Next focus**: HUGM calibration — linear regression of HUGM component scores against NNUE centipawn scores to tune HUGM weights. The `hugm_harness` binary (src/bin/hugm_harness.rs) already has the regression scaffolding and can be extended.

**Questions answered** (from original plan):
- Q1-Q3 (label scaling, dataset format, clipping): N/A — training deferred.

## Current inference command: `chessdb nnue-eval`

### Usage
```
"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1" | chessdb nnue-eval
```
Returns: `{fen, nnue_score}` record with centipawn evaluation.

Supports lists of FENs for batch processing.

### Remaining open items
- BUG-6: Stockfish path inconsistency (sf_batch_eval hardcodes `/usr/sbin/stockfish`; nnue-eval reads STOCKFISH_BIN). The standalone binary is dead code.
- Long-term: if direct .nnue file loading is needed (faster than UCI), implement a Rust NNUE parser. Not required now.

---

## Original Audit (archived below)

Purpose
- Quick research & scoping (Phase 0) for adding NNUE training/inference support to nuchessdb.
- Map what already exists in the repository that we can reuse, identify gaps, and propose next concrete tasks.

Background (short)
- NNUE (Efficiently Updatable Neural Network) is a lightweight, high-performance neural evaluator widely used in chess engines.
- Key idea: a sparse, piece-list-friendly input encoding and a small dense network (feature transformer + hidden layers) that can be cheaply updated as pieces move.

Current reusable pieces (surviving after cleanup):
- Position encoder (src/position_encoder.rs): 1024-element f32 vector, 768 piece-square one-hot. Ready for training or inference.
- HUGM eval (src/eval/position.rs): ~2800 lines of handcrafted heuristics with tunable weights.
- NNUE eval (src/nnue_eval_cmd.rs): UCI-based Stockfish wrapper (new in 2026-05-13).

Removed (2026-05-13 cleanup):
- Old nnue_eval_cmd.rs (chess-vector-engine JSON loader)
- Standalone nnue_dataset_builder binary (duplicated plugin dataset_builder_cmd)
- --with-stockfish flag from process_corpus

Policy: Stockfish evaluation handling (unchanged)
- Do NOT persist Stockfish numeric evaluations as canonical fields in the positions table.
- Stockfish is an external oracle for review and labeling.
- HUGM remains the primary human-interpretable heuristic layer.
