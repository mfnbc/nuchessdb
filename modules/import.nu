use ./utils.nu *
use ./config.nu *
use ./db.nu *
use ./critter.nu *
use ./dynamic.nu *

def headers-list-to-record [headers: list<record>] {
  $headers | reduce -f {} { |row, acc| $acc | upsert $row.key $row.value }
}

def game-insert-sql [platform: string, source_game_id: string, raw_pgn: string, headers: record] {
  let white = ($headers | get -o White | default "")
  let black = ($headers | get -o Black | default "")
  let result = ($headers | get -o Result | default "*")
  let time_control = ($headers | get -o TimeControl | default "")
  let white_elo = ($headers | get -o WhiteElo | default "")
  let black_elo = ($headers | get -o BlackElo | default "")
  let platform_q = (sql-string $platform)
  let source_q = (sql-string $source_game_id)
  let result_q = (sql-string $result)
  let tc_q = (sql-string $time_control)
  let white_elo_q = (sql-int $white_elo)
  let black_elo_q = (sql-int $black_elo)
  let white_q = (sql-string $white)
  let black_q = (sql-string $black)
  let raw_q = (sql-string $raw_pgn)
  let played_at = (
    if (($headers | get -o UTCDate | default "") != "" and ($headers | get -o UTCTime | default "") != "") {
      $'($headers.UTCDate) ($headers.UTCTime)'
    } else {
      ""
    }
  )
  let played_at_q = (sql-string $played_at)

  let white_account = if ($white | is-empty) { "NULL" } else { ["(SELECT id FROM accounts WHERE platform = ", $platform_q, " AND username = ", $white_q, ")"] | str join }
  let black_account = if ($black | is-empty) { "NULL" } else { ["(SELECT id FROM accounts WHERE platform = ", $platform_q, " AND username = ", $black_q, ")"] | str join }

  [
    "INSERT INTO games (platform, source_game_id, white_account_id, black_account_id, result, time_control, played_at, white_elo, black_elo, raw_pgn, imported_at) VALUES (",
    $platform_q, ", ", $source_q, ", ", $white_account, ", ", $black_account, ", ", $result_q, ", ", $tc_q, ", ", $played_at_q, ", ", $white_elo_q, ", ", $black_elo_q, ", ", $raw_q, ", datetime('now')) ON CONFLICT(platform, source_game_id) DO UPDATE SET white_account_id = excluded.white_account_id, black_account_id = excluded.black_account_id, result = excluded.result, time_control = excluded.time_control, played_at = excluded.played_at, white_elo = excluded.white_elo, black_elo = excluded.black_elo, raw_pgn = excluded.raw_pgn, imported_at = excluded.imported_at;"
  ] | str join
}

def account-upsert-sql [platform: string, username: string, is_me: bool] {
  if ($username | is-empty) {
    ""
  } else {
    let me_flag = if $is_me { 1 } else { 0 }
    let platform_q = (sql-string $platform)
    let username_q = (sql-string $username)
    (["INSERT INTO accounts (platform, username, is_me) VALUES (", $platform_q, ", ", $username_q, ", ", ($me_flag | into string), ") ON CONFLICT(platform, username) DO UPDATE SET is_me = excluded.is_me;"] | str join)
  }
}

def position-upsert-sql [fen: string] {
  let canonical_fen = $fen
  let canonical_hash = ($canonical_fen | shakmaty zobrist)
  let side = ($canonical_fen | split row " " | get 1)
  let castling = ($canonical_fen | split row " " | get 2)
  let ep = ($canonical_fen | split row " " | get 3)
  let halfmove = ($canonical_fen | split row " " | get 4)
  let fullmove = ($canonical_fen | split row " " | get 5)
  let canonical_hash_q = (sql-string $canonical_hash)
  let canonical_fen_q = (sql-string $canonical_fen)
  let raw_q = (sql-string $fen)
  let side_q = (sql-string $side)
  let castling_q = (sql-string $castling)
  let ep_q = (sql-string $ep)

  {
    canonical_hash: $canonical_hash,
    canonical_fen: $canonical_fen,
    sql: (["INSERT INTO positions (canonical_hash, canonical_fen, raw_fen, side_to_move, castling, en_passant, halfmove_clock, fullmove_number, created_at) VALUES (", $canonical_hash_q, ", ", $canonical_fen_q, ", ", $raw_q, ", ", $side_q, ", ", $castling_q, ", ", $ep_q, ", ", ($halfmove | into string), ", ", ($fullmove | into string), ", datetime('now')) ON CONFLICT(canonical_hash) DO UPDATE SET canonical_fen = excluded.canonical_fen, raw_fen = excluded.raw_fen, side_to_move = excluded.side_to_move, castling = excluded.castling, en_passant = excluded.en_passant, halfmove_clock = excluded.halfmove_clock, fullmove_number = excluded.fullmove_number;"] | str join)
  }
}

def position-upsert-sql-by-hash [canonical_hash: string, fen: string] {
  let canonical_fen = $fen
  let side = ($canonical_fen | split row " " | get 1)
  let castling = ($canonical_fen | split row " " | get 2)
  let ep = ($canonical_fen | split row " " | get 3)
  let halfmove = ($canonical_fen | split row " " | get 4)
  let fullmove = ($canonical_fen | split row " " | get 5)
  let canonical_hash_q = (sql-string $canonical_hash)
  let canonical_fen_q = (sql-string $canonical_fen)
  let raw_q = (sql-string $fen)
  let side_q = (sql-string $side)
  let castling_q = (sql-string $castling)
  let ep_q = (sql-string $ep)

  {
    canonical_hash: $canonical_hash,
    canonical_fen: $canonical_fen,
    sql: ([
      "INSERT INTO positions (canonical_hash, canonical_fen, raw_fen, side_to_move, castling, en_passant, halfmove_clock, fullmove_number, created_at) VALUES (",
      $canonical_hash_q, ", ", $canonical_fen_q, ", ", $raw_q, ", ", $side_q, ", ", $castling_q, ", ", $ep_q, ", ", ($halfmove | into string), ", ", ($fullmove | into string), ", datetime('now')) ON CONFLICT(canonical_hash) DO UPDATE SET canonical_fen = excluded.canonical_fen, raw_fen = excluded.raw_fen, side_to_move = excluded.side_to_move, castling = excluded.castling, en_passant = excluded.en_passant, halfmove_clock = excluded.halfmove_clock, fullmove_number = excluded.fullmove_number;"
    ] | str join)
  }
}

def prepare-batch-position-load [rows: list<record>] {
  let initial_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
  let start_pos = (position-upsert-sql $initial_fen)

  let acc = (
    $rows
    | reduce -f {
        seen: ({ } | upsert $start_pos.canonical_hash { fen: $initial_fen, game_indexes: [], occurrences: 0 })
        statements: [$start_pos.sql]
        repeated_rows: 0
      } { |row, acc|
        let existing = ($acc.seen | get -o $row.zobrist)
        if $existing == null {
          let pos = (position-upsert-sql-by-hash $row.zobrist $row.fen)
          {
            seen: ($acc.seen | upsert $row.zobrist { fen: $row.fen, game_indexes: [$row.game_index], occurrences: 1 })
            statements: ($acc.statements | append $pos.sql)
            repeated_rows: $acc.repeated_rows
          }
        } else {
          let game_indexes = if ($existing.game_indexes | any { |i| $i == $row.game_index }) { $existing.game_indexes } else { ($existing.game_indexes | append $row.game_index) }
          {
            seen: ($acc.seen | upsert $row.zobrist { fen: $existing.fen, game_indexes: $game_indexes, occurrences: ($existing.occurrences + 1) })
            statements: $acc.statements
            repeated_rows: ($acc.repeated_rows + 1)
          }
        }
      }
  )

  let collision_hashes = (
    $acc.seen
    | columns
    | where { |hash| (($acc.seen | get $hash).occurrences > 1) }
  )

  let collisions = (
    $collision_hashes
    | each { |hash|
        let entry = ($acc.seen | get $hash)
        { zobrist: $hash, fen: $entry.fen, occurrences: $entry.occurrences, game_indexes: $entry.game_indexes }
      }
  )

  {
    statements: $acc.statements,
    summary: {
      unique_positions: ($acc.seen | columns | length),
      repeated_positions: ($collisions | length),
      repeated_rows: $acc.repeated_rows,
      collision_positions: $collisions,
    },
  }
}

def prepare-batch-position-load-with-source [rows: list<record>, source_label: string] {
  let prep = (prepare-batch-position-load $rows)
  let collisions = (
    $prep.summary.collision_positions
    | each { |entry|
        {
          source_game_id: $source_label,
          batch_index: 0,
          zobrist: $entry.zobrist,
          fen: $entry.fen,
          occurrences: $entry.occurrences,
          game_indexes: $entry.game_indexes,
        }
      }
  )

  { statements: $prep.statements, summary: ($prep.summary | upsert collision_positions $collisions) }
}

def collision-insert-sql [source_game_id: string, batch_index: int, entry: record] {
  let source_q = (sql-string $source_game_id)
  let zobrist_q = (sql-string $entry.zobrist)
  let fen_q = (sql-string $entry.fen)
  let game_indexes_q = (sql-string ($entry.game_indexes | to json))

  [
    "INSERT INTO position_import_collisions (source_game_id, batch_index, zobrist, fen, occurrences, game_indexes_json, created_at) VALUES (",
    $source_q, ", ", ($batch_index | into string), ", ", $zobrist_q, ", ", $fen_q, ", ", ($entry.occurrences | into string), ", ", $game_indexes_q, ", datetime('now')) ON CONFLICT(source_game_id, zobrist) DO UPDATE SET batch_index = excluded.batch_index, fen = excluded.fen, occurrences = excluded.occurrences, game_indexes_json = excluded.game_indexes_json, created_at = excluded.created_at;"
  ] | str join
}

def collision-statements [entries: list<record>] {
  $entries | each { |e| collision-insert-sql $e.source_game_id $e.batch_index $e }
}

def color-stats-sql [canonical_hash: string, result: string] {
  let white = if $result == "1-0" { 1 } else { 0 }
  let black = if $result == "0-1" { 1 } else { 0 }
  let draw = if $result == "1/2-1/2" { 1 } else { 0 }
  let canonical_hash_q = (sql-string $canonical_hash)

  ["INSERT INTO position_color_stats (position_id, white_wins, draws, black_wins, occurrences) VALUES ((SELECT id FROM positions WHERE canonical_hash = ", $canonical_hash_q, "), ", ($white | into string), ", ", ($draw | into string), ", ", ($black | into string), ", 1) ON CONFLICT(position_id) DO UPDATE SET white_wins = white_wins + excluded.white_wins, draws = draws + excluded.draws, black_wins = black_wins + excluded.black_wins, occurrences = occurrences + 1;"] | str join
}

def player-stats-sql [canonical_hash: string, me_username: string, white_username: string, black_username: string, result: string, platform: string] {
  if ($me_username | is-empty) {
    ""
  } else {
    let me_is_white = ($me_username | str downcase) == ($white_username | str downcase)
    let me_is_black = ($me_username | str downcase) == ($black_username | str downcase)

    if (not $me_is_white and not $me_is_black) {
      ""
    } else {
      let wins = if (($me_is_white and $result == "1-0") or ($me_is_black and $result == "0-1")) { 1 } else { 0 }
      let draws = if $result == "1/2-1/2" { 1 } else { 0 }
      let losses = if (($me_is_white and $result == "0-1") or ($me_is_black and $result == "1-0")) { 1 } else { 0 }
      let canonical_hash_q = (sql-string $canonical_hash)
      let platform_q = (sql-string $platform)
      let me_q = (sql-string $me_username)

      ["INSERT INTO position_player_stats (position_id, account_id, wins, draws, losses, occurrences) VALUES ((SELECT id FROM positions WHERE canonical_hash = ", $canonical_hash_q, "), (SELECT id FROM accounts WHERE platform = ", $platform_q, " AND lower(username) = lower(", $me_q, ")), ", ($wins | into string), ", ", ($draws | into string), ", ", ($losses | into string), ", 1) ON CONFLICT(position_id, account_id) DO UPDATE SET wins = wins + excluded.wins, draws = draws + excluded.draws, losses = losses + excluded.losses, occurrences = occurrences + 1;"] | str join
    }
  }
}

def move-sql [platform: string, source_game_id: string, ply: int, move_san: string, move_uci: string, before_hash: string, after_hash: string, mover_username: string] {
  let mover_id = if ($mover_username | is-empty) {
    "NULL"
  } else {
    let platform_q = (sql-string $platform)
    let mover_q = (sql-string $mover_username)
    ["(SELECT id FROM accounts WHERE platform = ", $platform_q, " AND username = ", $mover_q, ")"] | str join
  }
  let platform_q = (sql-string $platform)
  let source_q = (sql-string $source_game_id)
  let move_san_q = (sql-string $move_san)
  let move_uci_q = (sql-string $move_uci)
  let before_q = (sql-string $before_hash)
  let after_q = (sql-string $after_hash)

  ["INSERT INTO game_positions (game_id, ply, move_san, move_uci, position_before_id, position_after_id, mover_account_id) VALUES ((SELECT id FROM games WHERE platform = ", $platform_q, " AND source_game_id = ", $source_q, "), ", ($ply | into string), ", ", $move_san_q, ", ", $move_uci_q, ", (SELECT id FROM positions WHERE canonical_hash = ", $before_q, "), (SELECT id FROM positions WHERE canonical_hash = ", $after_q, "), ", $mover_id, ");"] | str join
}

def build-game-import-statements [platform: string, source_game_id: string, raw_pgn: string, headers: record, cfg: record, rows: list<record>] {
  let result = ($headers | get -o Result | default "*")
  let white = ($headers | get -o White | default "")
  let black = ($headers | get -o Black | default "")
  let me_username = (if $platform == "chesscom" { $cfg.identity.me.chesscom } else if $platform == "lichess" { $cfg.identity.me.lichess } else { "" })

  let sql_parts = [
    (account-upsert-sql $platform $white ($me_username != "" and ($white | str downcase) == ($me_username | str downcase))),
    (account-upsert-sql $platform $black ($me_username != "" and ($black | str downcase) == ($me_username | str downcase))),
    (game-insert-sql $platform $source_game_id $raw_pgn $headers),
  ]

  let initial_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
  let initial_hash = ($initial_fen | shakmaty zobrist)
  let sql_parts = ($sql_parts | append (color-stats-sql $initial_hash $result))
  let sql_parts = ($sql_parts | append (player-stats-sql $initial_hash $me_username $white $black $result $platform))

  let replay = ($rows | reduce -f {
    sql_parts: $sql_parts
    seen_positions: [$initial_hash]
    previous_fen: $initial_fen
    previous_hash: $initial_hash
  } { |row, acc|
    let before_hash = $acc.previous_hash
    let after_hash = $row.zobrist
    let mover = if $row.color == "white" { $white } else { $black }
    let before_seen = ($acc.seen_positions | any { |h| $h == $before_hash })
    let after_seen = ($acc.seen_positions | any { |h| $h == $after_hash })
    let before_color_sql = if $before_seen { "" } else { (color-stats-sql $before_hash $result) }
    let before_player_sql = if $before_seen { "" } else { (player-stats-sql $before_hash $me_username $white $black $result $platform) }
    let after_color_sql = if $after_seen { "" } else { (color-stats-sql $after_hash $result) }
    let after_player_sql = if $after_seen { "" } else { (player-stats-sql $after_hash $me_username $white $black $result $platform) }

    {
      sql_parts: (
        $acc.sql_parts
        | append $before_color_sql
        | append $before_player_sql
        | append $after_color_sql
        | append $after_player_sql
        | append (move-sql $platform $source_game_id ($row.ply | into int) $row.san $row.uci $before_hash $after_hash $mover)
      )
      seen_positions: ($acc.seen_positions | append $before_hash | append $after_hash)
      previous_fen: $row.fen
      previous_hash: $after_hash
    }
  })

  let statements = ($replay.sql_parts | where { |stmt| not ($stmt | is-empty) })

  {
    source_game_id: $source_game_id,
    result: $result,
    white: $white,
    black: $black,
    moves: ($rows | length),
    statements: $statements,
  }
}

def normalize-batch-game [game: record] {
  {
    game_index: $game.game_index,
    source_game_id: $game.source_game_id,
    headers: (headers-list-to-record $game.headers),
    result: $game.result,
    moves: $game.moves,
  }
}

def import-json-games [path: string, platform: string] {
  let cfg = load-config
  let payload = (open $path)
  let games = if ($payload | describe) == "list<record>" {
    $payload
  } else if ($payload | describe) == "record" and ($payload | columns | any { |c| $c == "games" }) {
    $payload.games
  } else {
    error make { msg: $'Unsupported JSON export shape in ($path)' }
  }

  let plan = (
    $games
    | reduce -f { index: 0, statements: [], results: [] } { |row, acc|
        let idx = ($acc.index | into string)
        let source_game_id = (if ($row | columns | any { |c| $c == "id" }) { $row.id | into string } else if ($row | columns | any { |c| $c == "url" }) { $row.url | into string } else { $'($path)#($idx)' })
        let raw_pgn = (if ($row | columns | any { |c| $c == "pgn" }) { $row.pgn | into string } else { error make { msg: $'JSON row missing pgn field in ($path)' } })
        let batch = ($raw_pgn | shakmaty pgn-to-batch)
        let normalized_games = ($batch.games | each { |game| normalize-batch-game $game })
        let prep = (prepare-batch-position-load-with-source $batch.positions $source_game_id)
        let game_builds = (
          $normalized_games
          | each { |game|
              let game_id = $'($source_game_id)#($game.game_index)'
              build-game-import-statements $platform $game_id $raw_pgn $game.headers $cfg $game.moves
            }
        )
        let game_results = (
          $game_builds
          | each { |plan|
              {
                source_game_id: $plan.source_game_id,
                result: $plan.result,
                white: $plan.white,
                black: $plan.black,
                moves: $plan.moves,
                dedup_summary: $prep.summary,
              }
            }
        )
        let game_statements = ($game_builds | each { |plan| $plan.statements } | flatten)

        {
          index: ($acc.index + 1),
          statements: ($acc.statements | append $prep.statements | append (collision-statements $prep.summary.collision_positions) | append $game_statements),
          results: ($acc.results | append $game_results | flatten),
        }
      }
  )

  if not ($plan.statements | is-empty) {
    run-sql ($cfg.database.path) $plan.statements
  }

  $plan.results
}

def import-pgn-file [path: string, platform: string] {
  let cfg = load-config
  let text = (open $path)
  let batch = ($text | shakmaty pgn-to-batch)
  let normalized_games = ($batch.games | each { |game| normalize-batch-game $game })
  let prep = (prepare-batch-position-load-with-source $batch.positions $path)
  let game_builds = (
    $normalized_games
    | each { |game|
        let game_id = $'($path)#($game.game_index)'
        build-game-import-statements $platform $game_id $text $game.headers $cfg $game.moves
      }
  )
  let game_plans = (
    $game_builds
    | each { |plan|
        {
          source_game_id: $plan.source_game_id,
          result: $plan.result,
          white: $plan.white,
          black: $plan.black,
          moves: $plan.moves,
          dedup_summary: $prep.summary,
        }
      }
  )
  let game_statements = ($game_builds | each { |plan| $plan.statements } | flatten)
  let statements = ($prep.statements | append (collision-statements $prep.summary.collision_positions) | append $game_statements)

  if not ($statements | is-empty) {
    run-sql ($cfg.database.path) $statements
  }

  $game_plans
}

export def import-games [args: list<string>] {
  let cfg = load-config
  let db_path = $cfg.database.path

  if ($args | is-empty) {
    error make { msg: "import requires a path" }
  }

  let path = ($args | get 0)
  let platform = (if ($args | length) > 1 { $args | get 1 } else { "chesscom" })

  let results = if (($path | path parse | get extension) == "json") {
    import-json-games $path $platform
  } else {
    import-pgn-file $path $platform
  }

  let _ = (refresh-critter-enrichment-queue)
  let _ = (refresh-dynamic-enrichment-queue)

  { path: $path, platform: $platform, games_seen: ($results | length), database: $db_path, critter_queue_refreshed: true, dynamic_queue_refreshed: true }
}
