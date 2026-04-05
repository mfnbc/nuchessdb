use ./modules/utils.nu *
use ./modules/config.nu *
use ./modules/db.nu *

let cfg = load-config
let db_path = $cfg.database.path
let db = (open $db_path)

let path = "./data/raw/chesscom/hikaru/2026-03.pgn"
let text = (open $path)
let batch = ($text | shakmaty pgn-to-batch)

# All unique hashes across all games
let all_hashes = ($batch.positions | get zobrist | uniq)
let values_list = ($all_hashes | each { |hash|
  let hq = (sql-string $hash)
  ["(", $hq, ", 1, 0, 0, 1)"] | str join
} | str join ", ")

let sql = (["INSERT INTO position_color_stats (position_id, white_wins, draws, black_wins, occurrences) SELECT p.id, v.ww, v.dw, v.bw, v.occ FROM (VALUES ", $values_list, ") AS v(hash, ww, dw, bw, occ) JOIN positions p ON p.canonical_hash = v.hash ON CONFLICT(position_id) DO UPDATE SET white_wins = white_wins + excluded.white_wins, draws = draws + excluded.draws, black_wins = black_wins + excluded.black_wins, occurrences = occurrences + 1;"] | str join)

print $"SQL length: ($sql | str length) bytes, hashes: ($all_hashes | length)"
$db | query db "BEGIN IMMEDIATE;" | ignore
$db | query db $sql | ignore
$db | query db "COMMIT;" | ignore
let n = ($db | query db "SELECT count(*) as n FROM position_color_stats" | get n | get 0)
print $"color_stats rows: ($n)"
