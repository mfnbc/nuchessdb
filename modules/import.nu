use ./config.nu *
use ./db.nu *

def sql-string [value: any] {
  if $value == null {
    "NULL"
  } else {
    let text = ($value | into string | str replace -a "'" "''")
    $"'($text)'"
  }
}

def sql-int [value: any] {
  if $value == null {
    "NULL"
  } else {
    $value | into string
  }
}

def parse-pgn-headers [pgn: string] {
  let header_block = ($pgn | split row "\n\n" | first)
  let pairs = (
    $header_block
    | lines
    | parse --regex '^\[(?<key>[A-Za-z0-9_]+)\s+"(?<value>.*)"\]$'
  )

  $pairs
  | reduce -f {} { |row, acc|
      $acc | upsert ($row.key) ($row.value)
    }
}

def split-pgn-games [text: string] {
  let trimmed = ($text | str trim)
  if ($trimmed | is-empty) {
    []
  } else {
    $trimmed
    | split row "\n\n[Event "
    | enumerate
    | each { |it|
        if $it.index == 0 {
          $it.item
        } else {
          $'[Event ($it.item)'
        }
      }
  }
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
  let canonical_hash = (echo $canonical_fen | shakmaty zobrist)
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

def import-one-game [platform: string, source_game_id: string, raw_pgn: string, cfg: record, db] {
  let headers = (parse-pgn-headers $raw_pgn)
  let result = ($headers | get -o Result | default "*")
  let white = ($headers | get -o White | default "")
  let black = ($headers | get -o Black | default "")

  let states = (echo $raw_pgn | shakmaty pgn-to-fens)
  let rows = if ($states | is-empty) { [] } else { $states }

  let initial_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
  let me_username = (if $platform == "chesscom" { $cfg.identity.me.chesscom } else if $platform == "lichess" { $cfg.identity.me.lichess } else { "" })

  let sql_parts = [
    (account-upsert-sql $platform $white ($me_username != "" and ($white | str downcase) == ($me_username | str downcase))),
    (account-upsert-sql $platform $black ($me_username != "" and ($black | str downcase) == ($me_username | str downcase))),
    (game-insert-sql $platform $source_game_id $raw_pgn $headers),
  ]

  let start_pos = (position-upsert-sql $initial_fen)
  let sql_parts = ($sql_parts | append $start_pos.sql)
  let sql_parts = ($sql_parts | append (color-stats-sql $start_pos.canonical_hash $result))
  let sql_parts = ($sql_parts | append (player-stats-sql $start_pos.canonical_hash $me_username $white $black $result $platform))

  let replay = ($rows | reduce -f {
    sql_parts: $sql_parts
    seen_positions: [$start_pos.canonical_hash]
    previous_fen: $initial_fen
    previous_hash: $start_pos.canonical_hash
  } { |row, acc|
    let before_pos = (position-upsert-sql $acc.previous_fen)
    let after_pos = (position-upsert-sql $row.fen)
    let mover = if $row.color == "white" { $white } else { $black }
    let before_seen = ($acc.seen_positions | any { |h| $h == $before_pos.canonical_hash })
    let after_seen = ($acc.seen_positions | any { |h| $h == $after_pos.canonical_hash })
    let before_color_sql = if $before_seen { "" } else { (color-stats-sql $before_pos.canonical_hash $result) }
    let before_player_sql = if $before_seen { "" } else { (player-stats-sql $before_pos.canonical_hash $me_username $white $black $result $platform) }
    let after_color_sql = if $after_seen { "" } else { (color-stats-sql $after_pos.canonical_hash $result) }
    let after_player_sql = if $after_seen { "" } else { (player-stats-sql $after_pos.canonical_hash $me_username $white $black $result $platform) }

    {
      sql_parts: (
        $acc.sql_parts
        | append $before_pos.sql
        | append $before_color_sql
        | append $before_player_sql
        | append $after_pos.sql
        | append $after_color_sql
        | append $after_player_sql
        | append (move-sql $platform $source_game_id ($row.ply | into int) $row.san $row.uci $before_pos.canonical_hash $after_pos.canonical_hash $mover)
      )
      seen_positions: ($acc.seen_positions | append $before_pos.canonical_hash | append $after_pos.canonical_hash)
      previous_fen: $row.fen
      previous_hash: $after_pos.canonical_hash
    }
  })

  let statements = ($replay.sql_parts | where { |stmt| not ($stmt | is-empty) })

  if (not ($statements | is-empty)) {
    for stmt in $statements {
      $db | query db $stmt | ignore
    }
  }

  {
    source_game_id: $source_game_id
    result: $result
    white: $white
    black: $black
    moves: ($rows | length)
  }
}

def import-json-games [path: string, platform: string] {
  let cfg = load-config
  let db = (open-db $cfg.database.path)
  let payload = (open $path)
  let games = if ($payload | describe) == "list<record>" {
    $payload
  } else if ($payload | describe) == "record" and ($payload | columns | any { |c| $c == "games" }) {
    $payload.games
  } else {
    error make { msg: $'Unsupported JSON export shape in ($path)' }
  }

  $games | reduce -f { index: 0, results: [] } { |row, acc|
      let idx = ($acc.index | into string)
      let source_game_id = (if ($row | columns | any { |c| $c == "id" }) { $row.id | into string } else if ($row | columns | any { |c| $c == "url" }) { $row.url | into string } else { $'($path)#($idx)' })
      let raw_pgn = (if ($row | columns | any { |c| $c == "pgn" }) { $row.pgn | into string } else { error make { msg: $'JSON row missing pgn field in ($path)' } })
      let imported = (import-one-game $platform $source_game_id $raw_pgn $cfg $db)

      { index: ($acc.index + 1), results: ($acc.results | append $imported) }
    }
  | get results
}

def import-pgn-file [path: string, platform: string] {
  let cfg = load-config
  let db = (open-db $cfg.database.path)
  let text = (open $path)
  let games = (split-pgn-games $text)

  $games | reduce -f { index: 0, results: [] } { |item, acc|
      let idx = ($acc.index | into string)
      let raw_pgn = ($item | str trim)
      let source_game_id = $'($path)#($idx)'
      let imported = (import-one-game $platform $source_game_id $raw_pgn $cfg $db)

      { index: ($acc.index + 1), results: ($acc.results | append $imported) }
    }
  | get results
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

  { path: $path, platform: $platform, games_seen: ($results | length), database: $db_path }
}
