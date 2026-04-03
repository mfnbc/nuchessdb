# Rules

## Nushell first

- Use Nushell idioms instead of shell habits.
- Prefer `http get` over `curl`.
- Prefer Nushell tables, records, lists, and pipelines over text scraping.
- Prefer NuON for config and small structured artifacts.

## Data boundaries

- Keep deterministic chess facts separate from engine evaluations.
- Keep deterministic chess facts separate from LLM commentary.
- Store raw source data when available.
- Preserve original PGN even after parsing.
- Store both raw FEN and canonical FEN.

## Position identity

- Canonical position identity must ignore move counters.
- Use the canonical key for grouping, stats, and deduplication.
- Keep exact replay data available separately.

## Stats

- Track outcomes by color.
- Track outcomes by platform-scoped player identity.
- Allow `me` to be configured per platform.
- Support comparing my results against my opponent's results from the same position.

## Commentary

- Every position may have commentary.
- Do not require positions to be pre-classified as important.
- Rank importance later using frequency, evaluation swing, or training value.
- Store model name, prompt version, and timestamp with any generated commentary.

## Storage

- Use SQLite as the primary durable database.
- Use Nushell's built-in SQLite support instead of requiring a separate `sqlite3` install.
- Use NuON for config, prompts, and lightweight derived artifacts.
- Do not use NuON as the main game store.

## Tooling

- Use `nu_plugin_shakmaty` for deterministic chess semantics.
- Use `nuagent` for JSON enrichment and LLM-facing augmentation.
- Keep analysis reproducible where possible.
