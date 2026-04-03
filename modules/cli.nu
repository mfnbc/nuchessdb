use ./config.nu *
use ./db.nu *
use ./import.nu *
use ./sync.nu *
use ./query.nu *
use ./engine.nu *

def benchmark-sync [args: list<string>] {
  let started = (date now)
  let result = (sync-games $args)
  let finished = (date now)

  {
    started: $started
    finished: $finished
    result: $result
  }
}

export def run [args: list<string>] {
  let command = if ($args | is-empty) { "help" } else { $args.0 }
  let rest = if ($args | length) > 1 { $args | skip 1 } else { [] }

  match $command {
    "init" => { init-db | to nuon | print }
    "import" => { import-games $rest | to nuon | print }
    "sync" => { sync-games $rest | to nuon | print }
    "status" => { show-overview | to nuon | print }
    "recent" => {
      let limit = if ($rest | is-empty) { 10 } else { $rest | get 0 | into int }
      recent-games $limit | to nuon | print
    }
    "top" => {
      let limit = if ($rest | is-empty) { 20 } else { $rest | get 0 | into int }
      top-positions $limit | to nuon | print
    }
    "report" => {
      let limit = if ($rest | is-empty) { 20 } else { $rest | get 0 | into int }
      position-report $limit | to nuon | print
    }
    "opponents" => {
      let limit = if ($rest | is-empty) { 20 } else { $rest | get 0 | into int }
      most-played-opponents $limit | to nuon | print
    }
    "rated" => {
      let limit = if ($rest | is-empty) { 50 } else { $rest | get 0 | into int }
      highest-rated-opponents $limit | to nuon | print
    }
    "queue" => {
      let limit = if ($rest | is-empty) { 50 } else { $rest | get 0 | into int }
      queued-enrichment $limit | to nuon | print
    }
    "enqueue" => {
      let limit = if ($rest | is-empty) { 50 } else { $rest | get 0 | into int }
      enqueue-hot-positions $limit | to nuon | print
    }
    "eval" => {
      let limit = if ($rest | is-empty) { 20 } else { $rest | get 0 | into int }
      eval-queue $limit | to nuon | print
    }
    "engine" => {
      let limit = if ($rest | is-empty) { 20 } else { $rest | get 0 | into int }
      engine-summary $limit | to nuon | print
    }
    "bench" => { benchmark-sync $rest | to nuon | print }
    "qstats" => { queue-stats | to nuon | print }
    "help" => { print "nuchessdb commands: init, import <path> [platform], sync chesscom [all] <username>, bench <sync-args...>, eval [limit], engine [limit], qstats, status, recent [limit], top [limit], report [limit], opponents [limit], rated [limit], queue [limit], enqueue [limit]" }
    _ => { print $'unknown command: ($command)' }
  }
}
