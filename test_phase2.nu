use ./modules/utils.nu *
use ./modules/config.nu *
use ./modules/db.nu *

let cfg = load-config
let db_path = $cfg.database.path
let path = "./data/raw/chesscom/hikaru/2026-03.pgn"
let platform = "chesscom"
let text = (open $path)
let batch = ($text | shakmaty pgn-to-batch)

let initial_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
let initial_hash = ($initial_fen | shakmaty zobrist)

# Phase 1: insert positions only
print "phase1: inserting positions..."
let pos_stmts = ($batch.unique_positions | each { |row|
  let fen = $row.fen
  let parts = ($fen | split row " ")
  let hq = (sql-string $row.zobrist)
  let fq = (sql-string $fen)
  let sq = (sql-string ($parts | get 1))
  let cq = (sql-string ($parts | get 2))
  let eq = (sql-string ($parts | get 3))
  let hm = ($parts | get 4)
  let fm = ($parts | get 5)
  (["INSERT INTO positions (canonical_hash, canonical_fen, raw_fen, side_to_move, castling, en_passant, halfmove_clock, fullmove_number, created_at) VALUES (", $hq, ", ", $fq, ", ", $fq, ", ", $sq, ", ", $cq, ", ", $eq, ", ", $hm, ", ", $fm, ", datetime('now')) ON CONFLICT(canonical_hash) DO NOTHING;"] | str join)
})
run-sql $db_path $pos_stmts
print $"done: ($pos_stmts | length) positions inserted"

# Phase 2: time subquery-based color_stats INSERTs for first 5 games' hashes
print "phase2: timing 100 subquery-based color_stats INSERTs..."
let test_hashes = ($batch.positions | where game_index < 5 | get zobrist | uniq | first 100)
print $"testing ($test_hashes | length) hashes"
let db = (open $db_path)
$db | query db "BEGIN IMMEDIATE;" | ignore
for hash in $test_hashes {
  let hq = (sql-string $hash)
  let stmt = (["INSERT INTO position_color_stats (position_id, white_wins, draws, black_wins, occurrences) VALUES ((SELECT id FROM positions WHERE canonical_hash = ", $hq, "), 0, 0, 0, 1) ON CONFLICT(position_id) DO UPDATE SET occurrences = occurrences + 1;"] | str join)
  $db | query db $stmt | ignore
}
$db | query db "COMMIT;" | ignore
print "done"
