# nuchessdb — Implementation Plan

## ECO Opening Seed (init phase)

### Goal
During `init`, download the ECO opening database and seed `positions` with
opening names and ECO codes. Because positions are keyed by Zobrist hash, any
user game that passes through a known opening position will automatically
inherit the annotation via the existing `INSERT OR IGNORE` merge logic — no
extra work needed at import time.

### Source
```
https://github.com/hayatbiralem/eco.json/raw/master/eco.json
```
Single JSON file, ~3000 entries. Previously used in this project; was removed
at some point. Each entry has the shape:
```json
{
  "eco": "B23",
  "name": "Sicilian Defense, Grand Prix Attack",
  "moves": "1.e4 c5 2.Nc3 Nc6 3.f4"
}
```
Note: this source gives `moves` (PGN string), not a pre-computed FEN/EPD.
The Lichess ECO repo (https://github.com/lichess-org/chess-openings) provides
`epd` (FEN without move counters) directly, which is easier to use if a switch
is acceptable. Either works — see Implementation Notes below.

### Schema changes needed
Add two nullable columns to `positions` (migration-safe):
```sql
ALTER TABLE positions ADD COLUMN eco     TEXT;
ALTER TABLE positions ADD COLUMN opening TEXT;
```
Add to `init-db` in `nuchessdb.nu` alongside the other `try { ALTER TABLE ... }` migrations.

### New command: `main init` changes
```
--eco: string   # path or URL to eco.json (optional, downloads if omitted)
```
If `--eco` is omitted and no local `eco.json` exists, download from the URL
above with `http get` (pure Nushell, no curl). Cache locally so subsequent
`init` calls are fast.

### Implementation sketch (Nushell)
```nu
def seed-openings [db: string, eco_path: string] {
    let entries = (open $eco_path)          # parses JSON automatically

    # hayatbiralem format gives 'moves'; compute FEN via plugin
    # Lichess format gives 'epd' directly — skip the plugin call
    let rows = ($entries | each { |e|
        let fen = try { $e.epd } catch {
            # hayatbiralem source: replay moves to get FEN
            $e.moves | chessdb pgn-to-fens | last | get fen
        }
        let zobrist = ($fen | chessdb zobrist)
        { zobrist: $zobrist, fen: $fen, eco: $e.eco, opening: $e.name }
    } | where zobrist != null)

    # Insert into positions — INSERT OR IGNORE so user game positions are unaffected
    for row in $rows {
        open $db | query db "
            INSERT OR IGNORE INTO positions (zobrist, fen, eco, opening)
            VALUES (?, ?, ?, ?)
        " --params [$row.zobrist, $row.fen, $row.eco, $row.opening]

        # If position already exists (from a user game), backfill eco/opening
        # only when the columns are currently NULL
        open $db | query db "
            UPDATE positions SET eco = ?, opening = ?
            WHERE zobrist = ? AND eco IS NULL
        " --params [$row.eco, $row.opening, $row.zobrist]
    }

    print $"Seeded ($rows | length) opening positions."
}
```

### Key points
- `chessdb pgn-to-fens` already exists in the plugin and can replay a PGN
  move string to produce a list of FEN records. `| last | get fen` gives the
  final position FEN for the opening line.
- `chessdb zobrist` is already registered (`zobrist::Zobrist` in lib.rs).
- The double-write pattern (INSERT OR IGNORE + UPDATE WHERE eco IS NULL)
  ensures both new positions and positions already in the DB from user games
  get annotated.
- Run `seed-openings` at the end of `init-db`, after schema creation, gated on
  the eco file existing or being downloadable.
- `explore` and `coach-profile` queries can then JOIN or SELECT on
  `positions.eco` / `positions.opening` to surface opening context naturally.

### Downstream benefits once wired up
- `explore <zobrist>` shows the ECO code and opening name alongside move
  frequencies — players can navigate by position hash and see where they are
  in theory.
- `coach-profile` can break down phase stats by opening family.
- A future `openings` subcommand could list all openings a player has reached,
  with win rates, average eval, and anomaly counts per opening.
- `recent` output can show canonical opening names rather than the raw
  chess.com `opening` string (which is often truncated or inconsistent).
