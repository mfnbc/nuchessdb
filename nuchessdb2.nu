#!/usr/bin/env nu

# nuchessdb2.nu - Minimal single-file compact replacement for nuchessdb
# Purpose: simple self-contained tool (init/import/status/recent/report/help)
# This intentionally avoids the large modules/ sub-system and stores imported
# games as one JSON-per-line NDJSON file: nuchessdb_games.ndjson

# Storage helpers: support ndjson (default) and a single-file JSON-array format (.nuon)
# Choose formats by existence: .nuon file preferred if present, otherwise .ndjson

def _db_format [] {
  if ("./nuchessdb_games.nuon" | path exists) { "nuon" } elif ("./nuchessdb_games.ndjson" | path exists) { "ndjson" } else { "ndjson" }
}

def _db_path_for [fmt: string] {
  if $fmt == "nuon" { "./nuchessdb_games.nuon" } else { "./nuchessdb_games.ndjson" }
}

def _db_path [] { _db_path_for (_db_format) }

def ensure-db [] {
  let fmt = (_db_format)
  let path = (_db_path_for $fmt)
  if not ($path | path exists) {
    if $fmt == "ndjson" {
      "" | save --raw --force $path
    } else {
      # For nuon (JSON array) start with an empty array
      "[]" | save --raw --force $path
    }
    print $"Created compact DB: ($path) (format: ($fmt))"
  } else {
    $path
  }
}

# Read all records from DB as a Nushell list of records

def read-db-records [] {
  let fmt = (_db_format)
  let path = (_db_path_for $fmt)
  if not ($path | path exists) { [] } else {
    if $fmt == "ndjson" {
      (open --raw $path | lines | where { $it != "" } | each { ($it) | from json })
    } else {
      # nuon: expect a single JSON array
      let raw = (open --raw $path)
      try { ($raw | from json) } catch { [] }
    }
  }
}

# Overwrite DB with provided list of records

def write-db-records [rows] {
  let fmt = (_db_format)
  let path = (_db_path_for $fmt)
  if $fmt == "ndjson" {
    # overwrite file and append one JSON object per line
    "" | save --raw --force $path
    ($rows | each { ($it | to json) | save --append --raw $path })
  } else {
    # write a single JSON array
    ($rows | to json) | save --raw --force $path
  }
}

# Append a list of records to DB (efficient for ndjson; for nuon we merge)

def append-db-records [rows] {
  let fmt = (_db_format)
  let path = (_db_path_for $fmt)
  if $fmt == "ndjson" {
    ($rows | each { ($it | to json) | save --append --raw $path })
    if not ((open --raw $path) | str ends-with "\n") { "" | save --append --raw $path }
  } else {
    let existing = (read-db-records)
    let merged = ($existing + $rows)
    write-db-records $merged
  }
}

# Parse a single PGN chunk into a record with headers + moves
# Very small, forgiving parser: headers are lines starting with '['
# moves are the remaining text after first blank line

def parse-pgn-chunk [chunk: string] {
  let lines = ($chunk | lines)
  let header_lines = ($lines | where { |l| $l | str starts-with "[" })
  let header_map = (
    $header_lines
    | each { |hl|
        let parsed = ($hl | parse --regex '\\[(?<k>[^\s]+)\s+"(?<v>.*)"\]')
        if ($parsed | is-empty) { [] } else { { ($parsed.0.k): ($parsed.0.v) } }
      }
    | merge --fold
  )

  # moves: take lines that are not headers and join them
  let moves_lines = ($lines | where { |l| not ($l | str starts-with "[") } | where { |l| $l != "" })
  let moves_text = ($moves_lines | str join " ")

  { headers: $header_map, moves: $moves_text, raw: $chunk }
}

# Import a PGN file or chess.com JSON dump into ndjson file
# This will detect chess.com JSON (a games array or top-level list) and import
# each game record; otherwise fall back to PGN parsing.

def import-pgn-file [path: string, platform: string] {
  if not ($path | path exists) {
    print "Error: file not found: ($path)"
    return
  }

  ensure-db | ignore
  let db = (_db_path)

  # read raw file
  let raw = (open --raw $path)

  # If the source already looks like JSON (chess.com API returns JSON of games),
  # parse and import each game object directly.
  if ($raw | str starts-with "[") or ($raw | str contains '"games"') {
    try {
      let parsed = ($raw | from json)
      # if parsed has a `games` field, use that, otherwise assume parsed is a list
      let games = (
        try { $parsed.games } catch { $parsed }
      )

      # If `games` is a single record (not a list), wrap it in a list
      let maybe_first = (try { ($games | get 0) } catch { null })
      let games_list = if ($maybe_first | is-empty) { [$games] } else { $games }

      let imported = (
        $games_list
        | each { |g| $g }
      )

      # append into storage (format-aware)
      append-db-records $imported
      let count = ($imported | length)
      print $"✓ Imported ($count) games from JSON into ($db)"
      { imported: $count, rows: $imported }
    } catch {
      # parsing as JSON failed; fall back to PGN splitting
      # (fall through to legacy PGN logic below)
      # For safety, warn the user.
      print "Warning: failed to parse as JSON, falling back to PGN parser"
    }
  }

  # split roughly into game chunks. This is a forgiving heuristic; if your
  # PGN is nonstandard some games may be merged or split incorrectly.
  let chunks = ($raw | str split "\n\n\n")

  let imported = (
    $chunks
    | each { |chunk|
        if ($chunk | str contains "\n[") or ($chunk | str starts-with "[") {
          let piece = if ($chunk | str starts-with "[") { $chunk } else { $chunk | str trim-left "\n" }
          let parsed = (parse-pgn-chunk $piece)
          let meta = { platform: $platform }
          let record = ($meta | merge $parsed)
          $record
        } else { [] }
      }
    | where { |r| not ($r | is-empty) }
  )

  # append into storage (format-aware)
  append-db-records $imported

  let count = ($imported | length)
  print $"✓ Imported ($count) games into ($db)"
  { imported: $count, rows: $imported }
}

# Count games in compact DB

def db-count [] {
  let rows = (read-db-records)
  ($rows | length)
}

# Show status overview

def show-status [] {
  let n = (db-count)
  print "=== nuchessdb2 Status ==="
  print $"Games: ($n)"
}

# Show recent games

def recent-games [limit: int = 10] {
  let rows = (read-db-records)
  if ($rows | is-empty) { [] } else { ($rows | last $limit) }
}

# Report top openings by headers.Opening (fallback: Unknown)

def opening-report [limit: int = 20] {
  let rows = (read-db-records)
  if ($rows | is-empty) { [] } else {
    ($rows
      | each { { opening: ($in.headers.Opening | default "Unknown") } }
      | group-by opening
      | each { { opening: $in.key, count: ($in.items | length) } }
      | sort-by count desc
      | first $limit)
  }
}

# Main CLI dispatcher

def main [...args] {
  if ($args | is-empty) { print-help; return }
  let cmd = $args.0
  let rest = if ($args | length) > 1 { $args | skip 1 } else { [] }

  match $cmd {
    "init" => { ensure-db | ignore; print "Database initialized (compact NDJSON)" }
    "import" => {
      if ($rest | length) < 2 { print "Usage: nu nuchessdb2.nu import <path.pgn> <platform>"; return }
      let path = $rest.0
      let platform = $rest.1
      import-pgn-file $path $platform | ignore
      show-status
    }
    "status" => { show-status }
    "recent" => {
      let limit = if ($rest | is-empty) { 10 } else { ($rest.0 | into int) }
      let rows = (recent-games $limit)
      if ($rows | is-empty) { print "No games found" } else { $rows | table }
    }
    "report" => {
      let limit = if ($rest | is-empty) { 20 } else { ($rest.0 | into int) }
      opening-report $limit | table --expand
    }
    "convert" => {
      if ($rest | is-empty) { print "Usage: nu nuchessdb2.nu convert <ndjson|nuon>"; return }
      let fmt = $rest.0
      if ($fmt != "ndjson" and $fmt != "nuon") { print "Supported formats: ndjson, nuon"; return }
      let rows = (read-db-records)
      if ($rows | is-empty) { print "No records to convert"; return }
      # write to the requested format path
      let dest = (_db_path_for $fmt)
      if ($fmt == "ndjson") {
        # overwrite ndjson
        "" | save --raw --force $dest
        ($rows | each { ($it | to json) | save --append --raw $dest })
        if not ((open --raw $dest) | str ends-with "\n") { "" | save --append --raw $dest }
      } else {
        ($rows | to json) | save --raw --force $dest
      }
      print $"Converted DB to ($dest) (format: ($fmt))"
    }
    "help" | "--help" | "-h" => { print-help }
    _ => { print $"Unknown command: ($cmd)"; print "Run 'nu nuchessdb2.nu help' for usage" }
  }
}

# Help text

def print-help [] {
  print "nuchessdb2 - compact chess DB wrapper (NDJSON)

USAGE:
  nu nuchessdb2.nu <command> [args...]

COMMANDS:
  init                      Create compact NDJSON DB file
  import <path.pgn> <plat>  Import PGN file (platform: chesscom|lichess|other)
  status                    Show DB status (game count)
  recent [n]                Show n most recent games (default 10)
  report [n]                Top n openings by occurrence (default 20)
  convert <format>          Convert DB to 'ndjson' or 'nuon' (safe)
  help                      Show this help message
" }

# If script invoked directly, call main with provided args

main $nu.args
