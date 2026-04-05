# Pre-refactor exploration script — kept as a historical artifact.
# Uses batch.positions (now batch.unique_positions) and chunks (now chunks-of); not called from main.nu.
use ./modules/utils.nu *
use ./modules/config.nu *
use ./modules/db.nu *

let cfg = load-config
let db_path = $cfg.database.path
let db = (open $db_path)

let path = "./data/raw/chesscom/hikaru/2026-03.pgn"
let text = (open $path)
let batch = ($text | shakmaty pgn-to-batch)

let all_hashes = ($batch.positions | get zobrist | uniq)
print $"total unique hashes: ($all_hashes | length)"

# Chunk into batches of 500 and do one INSERT per chunk
let chunk_size = 500
let chunks = ($all_hashes | chunks $chunk_size)
print $"chunks: ($chunks | length)"

$db | query db "BEGIN IMMEDIATE;" | ignore
for chunk in $chunks {
  let values_list = ($chunk | each { |hash|
    let hq = (sql-string $hash)
    ["(", $hq, ", 1, 0, 0, 1)"] | str join
  } | str join ", ")
  let sql = (["INSERT INTO position_color_stats (position_id, white_wins, draws, black_wins, occurrences) SELECT p.id, v.ww, v.dw, v.bw, v.occ FROM (VALUES ", $values_list, ") AS v(hash, ww, dw, bw, occ) JOIN positions p ON p.canonical_hash = v.hash ON CONFLICT(position_id) DO UPDATE SET white_wins = white_wins + excluded.white_wins, draws = draws + excluded.draws, black_wins = black_wins + excluded.black_wins, occurrences = occurrences + 1;"] | str join)
  $db | query db $sql | ignore
}
$db | query db "COMMIT;" | ignore
let n = ($db | query db "SELECT count(*) as n FROM position_color_stats" | get n | get 0)
print $"color_stats rows: ($n)"
