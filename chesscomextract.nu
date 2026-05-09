#!/usr/bin/env nu

# chesscomextract.nu
# Download the latest chess.com archive for a username, save the PGN to disk,
# and simultaneously parse it into a Nushell list of game records and a
# flattened list of move rows (including fen and zobrist). Single-file, no modules.

def usage [] {
  print "Usage: nu chesscomextract.nu <username>"
  exit 1
}

if ($nu.args | length) == 0 { usage }

let username = ($nu.args | get 0)

let archives_url = $"https://api.chess.com/pub/player/($username)/games/archives"
print $"Fetching archive list for ($username)..."

let archives = try { http get $archives_url } catch { error make { msg: $"failed to fetch archives for ($username)" } }

let latest = ($archives.archives | last)
if ($latest | is-empty) { error make { msg: $"no archives found for ($username)" } }

let archive_id = ($latest | split row "/" | last 2 | str join "-")
let out_dir = $"./data/raw/chesscom/($username)"
let out_file = $"($out_dir)/($archive_id).pgn"

mkdir ($out_dir)  # idempotent

let pgn_url = $"($latest)/pgn"
print $"Downloading PGN: ($pgn_url)"

let raw_pgn = try { http get $pgn_url } catch { error make { msg: $"failed to download pgn ($pgn_url)" } }

# Save the PGN to disk while keeping it in memory
$raw_pgn | save --force $out_file
print $"Saved PGN to ($out_file)"

# Parse the PGN into a batch record using the Rust plugin
print "Parsing PGN into batch..."
let batch = ($raw_pgn | chessdb pgn-to-batch)

# Extract the list of games (each game is a record with headers and moves[])
let games = ($batch | get games)

# Save games as JSON (single file list) so downstream tools can consume it
let games_json_file = $"($out_dir)/($archive_id)-games.json"
($games | to json) | save --force $games_json_file
print $"Wrote games JSON to ($games_json_file) (count: ($games | length))"

# Build a flattened list of move rows (game_index, ply, move_number, color, san, uci, fen, zobrist)
let moves = ($games | each { |g|
  let gi = ($g | get game_index)
  ($g.moves | each { |m|
    { game_index: $gi, ply: ($m | get ply), move_number: ($m | get move_number), color: ($m | get color), san: ($m | get san), uci: ($m | get uci), fen: ($m | get fen), zobrist: ($m | get zobrist) }
  })
} | flatten)

let moves_json_file = $"($out_dir)/($archive_id)-moves.json"
($moves | to json) | save --force $moves_json_file
print $"Wrote flattened moves JSON to ($moves_json_file) (count: ($moves | length))"

# Also output the Nushell lists so caller can consume them directly
echo { archive: $latest, pgn_file: $out_file, games: $games, moves: $moves }
