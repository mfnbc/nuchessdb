plugin use chessdb

use ./modules/utils.nu *
use ./modules/config.nu *
use ./modules/db.nu *
use ./modules/sync.nu *
use ./modules/critter.nu *

let fixture_config = './test-fixtures/config.nuchessdb.nuon'
let fixture_archives = './test-fixtures/chesscom/archives.json'
let fixture_pgn = './test-fixtures/chesscom/hikaru-game.pgn'
let db_path = './data/nuchessdb.sqlite'

$env.NUCHESSDB_CONFIG = $fixture_config
$env.NUCHESSDB_TEST_ARCHIVES_JSON = $fixture_archives
$env.NUCHESSDB_TEST_PGN_MODE = 'fixture'
$env.NUCHESSDB_TEST_PGN_FIXTURE = $fixture_pgn
$env.NUCHESSDB_TEST_CRITTER_MODE = 'fixture'

clean-db | ignore
clean-sync-cache | ignore
init-db | ignore

let all_result = (sync-games ['chesscom' 'all' 'hikaru'])
let state_after_all = (sync-chesscom-status 'hikaru')

if ($state_after_all.missing_archives | sort) != ['2024/03'] {
  error make { msg: $'unexpected missing archives after all: ($state_after_all.missing_archives)' }
}

if ($state_after_all.completed_archives | length) != 4 {
  error make { msg: $'unexpected completed count after all: ($state_after_all.completed_archives | length)' }
}

let games_after_all = ((open $db_path | query db "SELECT COUNT(*) AS n FROM games" | get n | get 0))
if $games_after_all != 4 {
  error make { msg: $'expected 4 games after initial sync, got ($games_after_all)' }
}

$env.NUCHESSDB_TEST_PGN_MODE = 'fixture-ready'
let update_result = (sync-games ['chesscom' 'update' 'hikaru'])
let state_after_update = (sync-chesscom-status 'hikaru')

if not ($state_after_update.missing_archives | is-empty) {
  error make { msg: $'expected no missing archives after update: ($state_after_update.missing_archives)' }
}

if ($state_after_update.completed_archives | length) != 5 {
  error make { msg: $'unexpected completed count after update: ($state_after_update.completed_archives | length)' }
}

let games_after_update = ((open $db_path | query db "SELECT COUNT(*) AS n FROM games" | get n | get 0))
if $games_after_update != 5 {
  error make { msg: $'expected 5 games after retry, got ($games_after_update)' }
}

let _ = (critter-enqueue-games 100)
let queue_before = (queued-critter-evals 100)

if ($queue_before | is-empty) {
  error make { msg: 'expected critter queue to be populated after enqueue' }
}

let eval_result = (critter-eval-queue 100)
let queue_after = (queued-critter-evals 100)

if $eval_result.evaluated <= 0 {
  error make { msg: 'expected critter eval jobs to be processed' }
}

if not ($queue_after | is-empty) {
  error make { msg: 'expected critter queue to be drained by eval' }
}

print 'quickstart-pipeline-test-ok'
