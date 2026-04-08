use ./modules/config.nu *
use ./modules/db.nu *
use ./modules/sync.nu *
use ./modules/query.nu *

let fixture_config = './test-fixtures/config.nuchessdb.nuon'
let fixture_archives = './test-fixtures/chesscom/archives.json'
let fixture_pgn = './test-fixtures/chesscom/hikaru-game.pgn'
let db_path = './data/nuchessdb.sqlite'

$env.NUCHESSDB_CONFIG = $fixture_config
$env.NUCHESSDB_TEST_ARCHIVES_JSON = $fixture_archives
$env.NUCHESSDB_TEST_PGN_MODE = 'fixture'
$env.NUCHESSDB_TEST_PGN_FIXTURE = $fixture_pgn

clean-db | ignore
clean-sync-cache | ignore
init-db | ignore

let _ = (sync-games ['chesscom' 'all' 'hikaru'])

open $db_path | query db "INSERT OR IGNORE INTO position_color_stats (position_id, white_wins, draws, black_wins, occurrences) SELECT id, 1, 0, 0, 1 FROM positions LIMIT 1;" | ignore

let opponents_query = (
  "WITH me_accounts AS (SELECT id, platform, username FROM accounts WHERE is_me = 1), opp AS (SELECT g.platform AS platform, CASE WHEN g.white_account_id = m.id THEN b.username ELSE w.username END AS opponent, CASE WHEN g.white_account_id = m.id THEN g.black_elo ELSE g.white_elo END AS opponent_elo, CASE WHEN g.white_account_id = m.id THEN 'white' ELSE 'black' END AS me_color, g.result AS result FROM games g JOIN me_accounts m ON m.platform = g.platform AND (g.white_account_id = m.id OR g.black_account_id = m.id) LEFT JOIN accounts w ON w.id = g.white_account_id LEFT JOIN accounts b ON b.id = g.black_account_id) SELECT platform, opponent, COUNT(*) AS games, ROUND(AVG(opponent_elo), 1) AS avg_opponent_elo, MAX(opponent_elo) AS max_opponent_elo, SUM(CASE WHEN (me_color = 'white' AND result = '1-0') OR (me_color = 'black' AND result = '0-1') THEN 1 ELSE 0 END) AS wins, SUM(CASE WHEN result = '1/2-1/2' THEN 1 ELSE 0 END) AS draws, SUM(CASE WHEN (me_color = 'white' AND result = '0-1') OR (me_color = 'black' AND result = '1-0') THEN 1 ELSE 0 END) AS losses FROM opp WHERE opponent_elo IS NOT NULL GROUP BY platform, opponent ORDER BY avg_opponent_elo DESC, games DESC, opponent ASC LIMIT 50"
)

let rated_query = (
  "WITH me_accounts AS (SELECT id, platform, username FROM accounts WHERE is_me = 1), opp AS (SELECT g.platform AS platform, CASE WHEN g.white_account_id = m.id THEN b.username ELSE w.username END AS opponent, CASE WHEN g.white_account_id = m.id THEN g.black_elo ELSE g.white_elo END AS opponent_elo, CASE WHEN g.white_account_id = m.id THEN 'white' ELSE 'black' END AS me_color, g.result AS result FROM games g JOIN me_accounts m ON m.platform = g.platform AND (g.white_account_id = m.id OR g.black_account_id = m.id) LEFT JOIN accounts w ON w.id = g.white_account_id LEFT JOIN accounts b ON b.id = g.black_account_id) SELECT COUNT(*) AS games, ROUND(100.0 * SUM(CASE WHEN (me_color = 'white' AND result = '1-0') OR (me_color = 'black' AND result = '0-1') THEN 1 ELSE 0 END) / COUNT(*), 1) AS win_pct, ROUND(AVG(opponent_elo), 1) AS avg_opponent_elo FROM opp WHERE opponent_elo IS NOT NULL"
)

let opponents_rows = (open $db_path | query db $opponents_query)
let rated_rows = (open $db_path | query db $rated_query)

if ($opponents_rows | is-empty) {
  error make { msg: 'opponents replacement query returned no rows' }
}

if ($rated_rows | is-empty) {
  error make { msg: 'rated replacement query returned no rows' }
}

if not ($opponents_rows | columns | any { |c| $c == 'opponent' }) {
  error make { msg: 'opponents replacement query missing opponent column' }
}

if not ($rated_rows | columns | any { |c| $c == 'win_pct' }) {
  error make { msg: 'rated replacement query missing win_pct column' }
}

print 'removed-commands-test-ok'
