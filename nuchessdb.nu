#!/usr/bin/env nu

# nuchessdb - Chess database and enrichment pipeline
#
# Usage:
#   nu nuchessdb.nu init
#   nu nuchessdb.nu sync chesscom <username> [--with-critter]
#   nu nuchessdb.nu import <path.pgn> <platform> [--with-critter]
#   nu nuchessdb.nu status
#   nu nuchessdb.nu report [limit]

use modules/db.nu *
use modules/import.nu *
use modules/sync.nu *
use modules/query.nu *
use modules/critter.nu *
use modules/coach.nu *
use modules/eco.nu *

def main [...args] {
  if ($args | is-empty) {
    print-help
    return
  }

  let command = $args.0
  let rest = if ($args | length) > 1 { $args | skip 1 } else { [] }

  match $command {
    "init" => {
      print "Initializing database..."
      let result = (init-db)
      print $"✓ Database initialized: ($result.database)"
      print $"✓ Schema loaded: ($result.schema)"
      print $"✓ ECO data: ($result.eco_data)"
    }

    "sync" => {
      if ($rest | length) < 2 {
        print "Usage: nu nuchessdb.nu sync <platform> <username> [--with-critter]"
        print "Example: nu nuchessdb.nu sync chesscom hikaru --with-critter"
        return
      }

      let platform = $rest.0
      let username = $rest.1
      let with_critter = ($rest | any { |arg| $arg == "--with-critter" })

      if $platform != "chesscom" and $platform != "lichess" {
        print $"Error: platform must be 'chesscom' or 'lichess', got '($platform)'"
        return
      }

      print $"Syncing ($platform) games for ($username)..."
      init-db | ignore

      # Sync all archives
      let result = (sync-games [$platform "all" $username])
      
      if ($result.archives | is-empty) {
        print "No games found or sync failed"
        return
      }

      let imported_count = ($result.archives | where skipped == false | length)
      print $"✓ Imported ($imported_count) archives"

      # Run critter eval if requested
      if $with_critter {
        print "Running Critter evaluation on new positions..."
        let eval_result = (critter-eval-queue 100)
        print $"✓ Evaluated ($eval_result | length) positions"
      }

      show-overview
    }

    "import" => {
      if ($rest | length) < 2 {
        print "Usage: nu nuchessdb.nu import <path.pgn> <platform> [--with-critter]"
        print "Example: nu nuchessdb.nu import ./data/games.pgn chesscom --with-critter"
        return
      }

      let path = $rest.0
      let platform = $rest.1
      let with_critter = ($rest | any { |arg| $arg == "--with-critter" })

      if not ($path | path exists) {
        print $"Error: file not found: ($path)"
        return
      }

      if $platform != "chesscom" and $platform != "lichess" {
        print $"Error: platform must be 'chesscom' or 'lichess', got '($platform)'"
        return
      }

      print $"Importing ($path) as ($platform) games..."
      init-db | ignore

      if $with_critter {
        import-pgn-file $path $platform --with-critter
      } else {
        import-pgn-file $path $platform
      }

      print "✓ Import complete"
      show-overview
    }

    "status" => {
      let overview = (show-overview)
      print "=== nuchessdb Status ==="
      print $"Database: ($overview.database)"
      print $"Games: ($overview.games)"
      print $"Positions: ($overview.positions)"
      print $"Moves: ($overview.moves)"
      print $"Critter Evaluations: ($overview.critter_evals)"
      print $"Annotations: ($overview.annotations)"
    }

    "report" => {
      let limit = if ($rest | is-empty) { 20 } else { $rest.0 | into int }
      print $"Top ($limit) positions by frequency and 'Me' collapse rate:"
      position-report $limit | table --expand
    }

    "recent" => {
      let limit = if ($rest | is-empty) { 10 } else { $rest.0 | into int }
      print $"Last ($limit) imported games:"
      recent-games $limit | table --expand
    }

    "top" => {
      let limit = if ($rest | is-empty) { 20 } else { $rest.0 | into int }
      print $"Top ($limit) most-visited positions:"
      top-positions $limit | table --expand
    }

    "critter-eval" => {
      let limit = if ($rest | is-empty) { 20 } else { $rest.0 | into int }
      print $"Running Critter evaluation on ($limit) queued positions..."
      let result = (critter-eval-queue $limit)
      print $"✓ Evaluated ($result | length) positions"
      show-overview
    }

    "coach-review" => {
      if ($rest | is-empty) {
        print "Usage: nu nuchessdb.nu coach-review <game_id>"
        print "Example: nu nuchessdb.nu coach-review 1"
        return
      }
      let game_id = ($rest.0 | into int)
      print $"Reviewing game ($game_id) with AI coach..."
      coach-review $game_id
    }

    "eco-classify" => {
      let limit = if ($rest | is-empty) { 20 } else { $rest.0 | into int }
      print $"Top ($limit) positions with ECO opening classification:"
      position-report $limit | eco-classify | table --expand
    }

    "help" | "--help" | "-h" => {
      print-help
    }

    _ => {
      print $"Unknown command: ($command)"
      print "Run 'nu nuchessdb.nu help' for usage information"
    }
  }
}

def print-help [] {
  print "nuchessdb - Chess database and enrichment pipeline

USAGE:
  nu nuchessdb.nu <command> [args...]

COMMANDS:
  init                                  Initialize database and schema
  sync <platform> <username> [flags]    Download and import games
  import <path.pgn> <platform> [flags]  Import PGN file
  status                                Show database overview
  report [limit]                        Position performance report (default: 20)
  recent [limit]                        Recently imported games (default: 10)
  top [limit]                           Most-visited positions (default: 20)
  critter-eval [limit]                  Run Critter evaluation queue (default: 20)
  coach-review <game_id>                Generate AI coaching for a game
  eco-classify [limit]                  Top positions with ECO names (default: 20)
  help                                  Show this help message

FLAGS:
  --with-critter                        Run Critter evaluation during import

EXAMPLES:
  # Initialize database
  nu nuchessdb.nu init

  # Sync all games from chess.com with evaluation
  nu nuchessdb.nu sync chesscom hikaru --with-critter

  # Import a PGN file
  nu nuchessdb.nu import ./data/games.pgn chesscom

  # Check status
  nu nuchessdb.nu status

  # View positions where you lose most often
  nu nuchessdb.nu report 10

  # Review a game with AI coach
  nu nuchessdb.nu coach-review 1
"
}
