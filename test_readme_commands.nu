use ./modules/config.nu *
use ./modules/db.nu *
use ./modules/sync.nu *
use ./modules/query.nu *
use ./modules/engine.nu *
use ./modules/critter.nu *
use ./modules/dynamic.nu *
use ./modules/eco.nu *

let fixture_config = './test-fixtures/config.nuchessdb.nuon'
let fixture_archives = './test-fixtures/chesscom/archives.json'
let fixture_pgn = './test-fixtures/chesscom/hikaru-game.pgn'
let db_path = './data/nuchessdb.sqlite'

$env.NUCHESSDB_CONFIG = $fixture_config
$env.NUCHESSDB_TEST_ARCHIVES_JSON = $fixture_archives
$env.NUCHESSDB_TEST_PGN_MODE = 'fixture'
$env.NUCHESSDB_TEST_PGN_FIXTURE = $fixture_pgn
$env.NUCHESSDB_TEST_CRITTER_MODE = 'fixture'
$env.NUCHESSDB_TEST_ENGINE_MODE = 'fixture'
$env.NUCHESSDB_TEST_DYNAMIC_MODE = 'fixture'

clean-db | ignore
clean-sync-cache | ignore
init-db | ignore

let sync_result = (sync-games ['chesscom' 'all' 'hikaru'])

open $db_path | query db "INSERT OR IGNORE INTO position_color_stats (position_id, white_wins, draws, black_wins, occurrences) SELECT id, 1, 0, 0, 1 FROM positions LIMIT 1;" | ignore

if ((show-overview).games) != 4 {
  error make { msg: 'status overview not updated after sync' }
}

if ((recent-games 10) | is-empty) {
  error make { msg: 'recent command returned no games after sync' }
}

if ((top-positions 10) | is-empty) {
  error make { msg: 'top command returned no positions after sync' }
}

if ((position-report 10) | is-empty) {
  error make { msg: 'report command returned no positions after sync' }
}

let _ = (enqueue-hot-positions 10)
let queue_rows = (queued-enrichment 10)
if ($queue_rows | is-empty) {
  error make { msg: 'queue command returned no engine jobs after enqueue' }
}

let qstats_rows = (queue-stats)
if ($qstats_rows | is-empty) {
  error make { msg: 'qstats command returned no rows after enqueue' }
}

let eval_result = (eval-queue 10)
if $eval_result.evaluated < 0 {
  error make { msg: 'eval command returned invalid result' }
}

let engine_rows = (engine-summary 10)

let _ = $engine_rows

let _ = (critter-enqueue-games 10)
let critter_queue = (queued-critter-evals 10)
if ($critter_queue | is-empty) {
  error make { msg: 'critter-queue command returned no jobs after enqueue' }
}

let critter_qstats_rows = (critter-queue-stats)
if ($critter_qstats_rows | is-empty) {
  error make { msg: 'critter-qstats command returned no rows after enqueue' }
}

let critter_eval_result = (critter-eval-queue 10)
if $critter_eval_result.evaluated < 0 {
  error make { msg: 'critter-eval command returned invalid result' }
}

let _ = (refresh-dynamic-enrichment-queue 10)
let dynamic_queue = (queued-dynamic-runs 10)
if ($dynamic_queue | is-empty) {
  error make { msg: 'dynamic-queue command returned no jobs after enqueue' }
}

let dynamic_qstats_rows = (dynamic-queue-stats)
if ($dynamic_qstats_rows | is-empty) {
  error make { msg: 'dynamic-qstats command returned no rows after enqueue' }
}

let dynamic_eval_result = (dynamic-eval-queue 10)
if $dynamic_eval_result.evaluated < 0 {
  error make { msg: 'dynamic-eval command returned invalid result' }
}

let eco_rows = (position-report 10 | eco-classify)
if ($eco_rows | is-empty) {
  error make { msg: 'eco-classify returned no rows after sync' }
}

print 'readme-command-test-ok'
