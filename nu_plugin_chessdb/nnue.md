NNUE Plan — MVP-focused

Purpose
- Minimal, actionable plan for producing bullet-training data from nuchessdb with a conservative, scalable memory policy.
- Keep the implementation simple: MVP happy path must work first (no sharding, no on-disk dedupe). If memory limits are exhausted, stop cleanly and write a checkpoint.

Decisions (minimalist)
- Training tool: bullet is the canonical trainer.
- Runtime inference/format: NPZ shards of numeric features for bullet. We will export weights later to the chess-vector JSON format for any Rust inference consumers.
- Keep HUGM analytics (chess.db) separate — do not store raw training corpora or engine labels in the canonical DB.

MVP dataset builder behaviour (single-pass, in-memory dedupe)
- Stream input (JSONL or NDJSON derived from PGNs) and for each position:
  - Parse FEN transiently, compute zobrist (u64) and NNUE features (first 768 floats) using position_encoder.
  - Maintain an in-memory HashSet<u64> of seen zobrist keys to deduplicate.
  - Emit per-sample NPZ outputs: features [768], label_scalar (+1/0/-1 from side-to-move), label_wdl [3], sample_weight.
- Memory policy: stop entirely when the unique-zobrist set reaches the configured memory budget. Default: 100_000_000 bytes budget with bytes_per_entry=48 → ~2M uniques. On reaching limit, flush the current shard, write a sentinel unique_limit_reached.json and a checkpoint (last processed offset/state), then exit.
- Rationale: simplest, deterministic, easy to reason about; avoids adding sharding complexity before the happy path works.

NPZ shard schema (MVP)
- features: float32 [N, 768]
- label_scalar: float32 [N]  (+1 win for side-to-move, 0 draw, -1 loss)
- label_wdl: float32 [N,3]   (one-hot win/draw/loss)
- sample_weight: float32 [N]
- Per-shard metadata file (JSON): arrays of zobrist, source_game_id, ply, white_elo, black_elo, result
- Master manifest (written on completion or when stopping): lists shards, totals, provenance, label encoding, code commit

Label semantics
- Use side-to-move perspective for labels: conventional for value networks.
- Provide both scalar and W/D/L distribution in shards so trainers can choose regression or classification losses.

Operational policy
- Engine labels (Stockfish) are generated in separate labeling runs and saved into separate labeled shards with provenance. Do not persist engine scores in the canonical positions table.
- Default behavior on unique-limit: stop and checkpoint (configurable but MVP uses stop).

CLI (MVP)
- nnue_dataset_builder <input_jsonl> <out_dir> [--shard-size N] [--min-elo N] [--max-unique-bytes B] [--bytes-per-entry E] [--on-limit stop|skip]
  - Defaults: shard-size=50000, max-unique-bytes=100_000_000, bytes-per-entry=48, on-limit=stop

Next minimal tasks (implementation order)
1) Finalize the dataset-builder MVP: manifest writing, checkpoint writing, and clean stop behavior.
2) Smoke test the builder on a small sample of positions and verify NPZ shards + manifest are correct.
3) Add a minimal training example (not production) showing how to feed shards to bullet; produce a small exported .weights file for integration testing.
4) Add a lightweight validation harness for holdout metrics.

Later (deferred)
- If we need > few million unique positions per run or want resumable long-running ingest, implement sharded partitioning or RocksDB-backed dedupe. Do not add this before MVP works.

Minimalism principle
- Follow the agents.md rule: implement the smallest change that works and proves the happy path. Avoid adding sharding, complex features, or optimizations until the basic pipeline is validated with real data.

---

Status (current snapshot)
- Documentation: nnue.md (this file) contains the MVP plan, defaults, and policies.
- Nushell entrypoint: nuchessdb/nuchessdb.nu added with import-pgn-file for streaming decompression of .zst PGN and direct plugin parsing (returns Nu tables).
- Dataset builder prototype (Rust): src/bin/nnue_dataset_builder.rs exists and compiles; accepts JSONL input and writes NPZ shards with features and W/D/L labels.
- Stop-on-limit behavior implemented: in-memory zobrist dedupe and clean exit with sentinel when the unique-zobrist budget is exhausted (default 100 MB).
- Removed inline persistent engine-scoring from the main ingestion pipeline; engine labeling is separated by policy.
- Started a native nu-plugin command (dataset_builder_cmd) to accept Nu tables directly — initial work exists but requires finishing.

Next steps (prioritized, small and surgical)
1) Finish native Nu plugin command (dataset_builder_cmd) so the pipeline can go Nu -> Rust -> NPZ with no JSONL intermediate. (High priority; minimal and focused.)
2) Add manifest.json aggregation and checkpoint writing to the builder and ensure sentinel/stop behavior is robust.
3) Run an end-to-end smoke test using nuchessdb.nu import-pgn-file on a small sample of the Lichess 2013-01 dump and produce a sample NPZ shard for inspection.
4) Provide a minimal training example or wrapper showing how to invoke bullet on the NPZ shard and export chess-vector JSON weights.
5) Add the lightweight validation harness that computes holdout metrics and per-ELO slices.

How I will proceed (if you confirm)
- I will implement item (1) next (finish dataset_builder_cmd), run the smoke test (item 3), and report the produced files and metrics. I will keep changes small and focused per the minimalism rule.

If you want any small adjustments to defaults (max_unique_bytes, bytes_per_entry) or to the shard schema before I proceed, tell me now; otherwise I will continue with the native-plugin completion and the smoke test.
