use ./config.nu *
use ./db.nu *
use ./import.nu *
use ./sync.nu *
use ./query.nu *

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
    "help" => { print "nuchessdb commands: init, import <path> [platform], sync chesscom [all] <username>, status, recent [limit], top [limit], report [limit]" }
    _ => { print $'unknown command: ($command)' }
  }
}
