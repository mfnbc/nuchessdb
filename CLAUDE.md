# nuchessdb — coding guidance for Claude

## Nushell idioms (nuchessdb.nu)

- **`repeat` over `each { "?" }`** — when you need N copies of a fixed string,
  use `"?" | repeat $n | str join ", "` rather than iterating a list and
  ignoring the element.

- **Optional cell paths over `if is-not-empty`** — use `.0?` on a filtered
  table and `$m.field? | default fallback` instead of an is-not-empty branch.
  The `?` suffix safely returns null on empty/missing; `default` handles it.

- **`enumerate` over `reduce` for row-differential work** — when you need the
  previous row's value, use `enumerate` + `$raw | get ($item.index - 1)` rather
  than a `{state, rows}` accumulator. Avoids O(n) `append` clones.

- **`into record` over `reduce -f {} { merge }`** — to fold a list of
  `[$key $value]` pairs into a record, use `| into record` directly.

- **`upsert` over `update` for external/plugin data** — plugin-returned records
  and LEFT-JOIN nullable columns use `upsert`; SQL-guaranteed columns use `update`.

- **`compact` over null-check conditionals** — use `try { fetch } catch { null }
  | compact` to strip failed fetches rather than `if $result != null { ... }`.

- **`all { is-empty }` guard before destructive writes** — before deleting a
  player's coaching data, check that the plugin returned at least one non-empty
  signal list to avoid wiping and not replacing.

## SQL vs Nushell aggregation

Keep aggregation in SQL. The `CASE WHEN m.ply <= 12 THEN 'opening'` phase
classification and `AVG(json_extract(...))` patterns return ~8 rows from 334K.
Moving them to Nushell (`upsert phase { ... } | group-by`) fetches all 334K rows
first — a ~40,000× data transfer increase for no benefit.

**Rule:** if a query groups + aggregates, the CASE WHEN lives in SQL. Only bring
rows into Nushell when you need per-row transformation that SQL cannot express.

## SQL string construction in db-merge

`db-merge` builds INSERT statements by concatenating `$table` and `$columns`
(both internal literal strings — not user input). This is **not** an injection
risk. All VALUES are parameterised via `--params`. Do not add escaping or
restructure this to avoid a non-existent vulnerability.
