use ./modules/utils.nu *
use ./modules/config.nu *
use ./modules/db.nu *

let cfg = load-config
let db_path = $cfg.database.path
let db = (open $db_path)

# Position table already has 25k rows from previous test
let count = ($db | query db "SELECT count(*) as n FROM positions" | get n | get 0)
print $"positions in DB: ($count)"

# Time 1000 subquery-based INSERTs
let path = "./data/raw/chesscom/hikaru/2026-03.pgn"
let text = (open $path)
let batch = ($text | shakmaty pgn-to-batch)
let test_hashes = ($batch.positions | get zobrist | uniq | first 1000)
print $"timing ($test_hashes | length) subquery INSERTs..."

$db | query db "BEGIN IMMEDIATE;" | ignore
for hash in $test_hashes {
  let hq = (sql-string $hash)
  let stmt = (["INSERT INTO position_color_stats (position_id, white_wins, draws, black_wins, occurrences) VALUES ((SELECT id FROM positions WHERE canonical_hash = ", $hq, "), 0, 0, 0, 1) ON CONFLICT(position_id) DO UPDATE SET occurrences = occurrences + 1;"] | str join)
  $db | query db $stmt | ignore
}
$db | query db "COMMIT;" | ignore
print "done"
