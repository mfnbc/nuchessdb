use ./config.nu *
use ./db.nu *
use ./import.nu *
use ./sync.nu *
use ./query.nu *
use ./engine.nu *
use ./critter.nu *
use ./dynamic.nu *
use ./eco.nu *

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
    "critter-enqueue" => {
      let limit = if ($rest | is-empty) { 100000 } else { $rest | get 0 | into int }
      refresh-critter-enrichment-queue $limit | to nuon | print
    }
    "critter-enqueue-games" => {
      let limit = if ($rest | is-empty) { 100000 } else { $rest | get 0 | into int }
      critter-enqueue-games $limit | to nuon | print
    }
    "critter-eval" => {
      let limit = if ($rest | is-empty) { 20 } else { $rest | get 0 | into int }
      critter-eval-queue $limit | to nuon | print
    }
    "critter-queue" => {
      let limit = if ($rest | is-empty) { 20 } else { $rest | get 0 | into int }
      queued-critter-evals $limit | to nuon | print
    }
    "critter-qstats" => { critter-queue-stats | to nuon | print }
    "dynamic-enqueue" => {
      let limit = if ($rest | is-empty) { 100000 } else { $rest | get 0 | into int }
      refresh-dynamic-enrichment-queue $limit | to nuon | print
    }
    "dynamic-eval" => {
      let limit = if ($rest | is-empty) { 20 } else { $rest | get 0 | into int }
      dynamic-eval-queue $limit | to nuon | print
    }
    "dynamic-queue" => {
      let limit = if ($rest | is-empty) { 20 } else { $rest | get 0 | into int }
      queued-dynamic-runs $limit | to nuon | print
    }
    "dynamic-qstats" => { dynamic-queue-stats | to nuon | print }
    "eco-classify" => {
      let limit = if ($rest | is-empty) { 20 } else { $rest | get 0 | into int }
      position-report $limit | eco-classify | to nuon | print
    }
    "bench" => { benchmark-sync $rest | to nuon | print }
    "qstats" => { queue-stats | to nuon | print }
    "help" => { print "nuchessdb — Nushell chess database and enrichment pipeline

SETUP
  init                        Create the SQLite schema

IMPORT & SYNC
  import <path> [platform]    Import a PGN or chess.com JSON export
  sync chesscom [all] <user>  Download and import chess.com archives
  bench <sync-args...>        Time a sync run

QUERIES
  status                      Overview: game count, position count, queue depth
  recent [limit]              Most recently imported games  (default 10)
  top [limit]                 Most-visited positions        (default 20)
  report [limit]              Positions with outcome stats  (default 20)
  opponents [limit]           Most-played opponents         (default 20)
  rated [limit]               Opponents sorted by rating    (default 50)

ENGINE EVAL (Stockfish / lc0 static)
  enqueue [limit]             Queue hot positions for engine eval   (default 50)
  queue [limit]               Show pending engine eval queue        (default 50)
  qstats                      Engine eval queue statistics
  eval [limit]                Run engine eval on queued positions   (default 20)
  engine [limit]              Show stored engine eval results       (default 20)

CRITTER EVAL (Open Critter decomposed)
  critter-enqueue [limit]     Queue popular positions (occurrences>=3) (default all)
  critter-enqueue-games [lim] Queue positions from games, newest first  (default all)
  critter-queue [limit]       Show pending critter eval queue        (default 20)
  critter-qstats              Critter eval queue statistics
  critter-eval [limit]        Run critter eval on queued positions   (default 20)

DYNAMIC EVAL (engine move ladder)
  dynamic-enqueue [limit]     Queue positions for dynamic eval      (default all)
  dynamic-queue [limit]       Show pending dynamic eval queue       (default 20)
  dynamic-qstats              Dynamic eval queue statistics
  dynamic-eval [limit]        Run dynamic eval on queued positions  (default 20)

OPENINGS (ECO classification)
  eco-classify [limit]        Top positions with ECO opening names  (default 20)" }
    _ => { print $'unknown command: ($command)' }
  }
}
