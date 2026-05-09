use ./utils.nu *
use ./config.nu *
use ./db.nu *

def headers-list-to-record [headers: list<record>] {
  $headers | reduce -f {} { |row, acc| $acc | upsert $row.key $row.value }
}

def bulk-insert-positions [rows: list<record>] {
  let values = ($rows | each { |row|
    let fen = (strip-fen $row.fen)
    let hash = ($fen | chessdb zobrist)
    let parts = ($fen | split row " ")
    let side     = ($parts | get 1)
    let castling = ($parts | get 2)
    let ep       = ($parts | get 3)
    [
      "(", (sql-string $hash), ",", (sql-string $fen), ",",
      (sql-string $side), ",", (sql-string $castling), ",", (sql-string $ep), ",",
      "datetime('now'))"
    ] | str join
  } | str join ",")
  [
    "INSERT INTO positions(canonical_hash,canonical_fen,side_to_move,castling,en_passant,created_at) VALUES ",
    $values,
    " ON CONFLICT(canonical_hash) DO NOTHING;"
  ] | str join
}

def bulk-insert-moves [rows: list<record>] {
  let values = ($rows | each { |r|
    let f_q = (sql-string $r.from_hash)
    let t_q = (sql-string $r.to_hash)
    let u_q = (sql-string $r.uci)
    let s_q = (sql-string $r.san)
    [
      "((SELECT id FROM positions WHERE canonical_hash=", $f_q, "),",
      "(SELECT id FROM positions WHERE canonical_hash=", $t_q, "),",
      $u_q, ",", $s_q, ")"
    ] | str join
  } | str join ",")
  [
    "INSERT INTO moves(from_position_id,to_position_id,move_uci,move_san) VALUES ",
    $values,
    " ON CONFLICT(from_position_id,to_position_id,move_uci) DO NOTHING;"
  ] | str join
}

export def import-pgn-file [path: string, platform: string] {
  let cfg = load-config
  let db_path = $cfg.database.path
  let text = (open $path)
  let batch = ($text | chessdb pgn-to-batch)
  let initial_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
  let initial_hash = (strip-fen $initial_fen | chessdb zobrist)
  let me_username = (if $platform == "chesscom" { $cfg.identity.me.chesscom } else { $cfg.identity.me.lichess })
  let chunk_size = 400

  # 1. Unique Positions (Stripped)
  let unique_positions = ($batch.unique_positions | each { |p| { hash: (strip-fen $p.fen | chessdb zobrist), fen: $p.fen } } | uniq-by hash)
  let pos_stmts = ($unique_positions | chunks-of $chunk_size | each { |chunk| bulk-insert-positions $chunk })
  run-sql $db_path $pos_stmts

  # 2. Accounts & Games (with path_json)
  mut account_stmts = []
  mut game_stmts = []
  
  for g in $batch.games {
    let headers = (headers-list-to-record $g.headers)
    let white = ($headers | get -o White | default "")
    let black = ($headers | get -o Black | default "")
    $account_stmts = ($account_stmts | append (account-upsert-sql $platform $white ($me_username != "" and ($white | str downcase) == ($me_username | str downcase))))
    $account_stmts = ($account_stmts | append (account-upsert-sql $platform $black ($me_username != "" and ($black | str downcase) == ($me_username | str downcase))))
    
    # Generate path of hashes
    let path_hashes = ([$initial_hash] | append ($g.moves | each { |m| (strip-fen $m.fen | chessdb zobrist) }))
    let source_game_id = $"($path)#($g.game_index)"
    
    let white_q = (sql-string $white)
    let black_q = (sql-string $black)
    let platform_q = (sql-string $platform)
    let res_q = (sql-string $g.result)
    let src_q = (sql-string $source_game_id)
    let pgn_q = (sql-string $text)
    let path_q = (sql-string ($path_hashes | to json))

    let white_account = if ($white | is-empty) { "NULL" } else { "(SELECT id FROM accounts WHERE platform = " + $platform_q + " AND username = " + $white_q + ")" }
    let black_account = if ($black | is-empty) { "NULL" } else { "(SELECT id FROM accounts WHERE platform = " + $platform_q + " AND username = " + $black_q + ")" }

    $game_stmts = ($game_stmts | append (["INSERT INTO games (platform, source_game_id, white_account_id, black_account_id, result, raw_pgn, path_json, imported_at) VALUES (", $platform_q, ",", $src_q, ",", $white_account, ",", $black_account, ",", $res_q, ",", $pgn_q, ",", $path_q, ", datetime('now')) ON CONFLICT DO NOTHING;"] | str join))
  }
  run-sql $db_path ($account_stmts | append $game_stmts | where { |s| not ($s | is-empty) })

  # 3. Moves (Edges)
  let all_edges = ($batch.games | each { |g|
    let hashes = ([$initial_hash] | append ($g.moves | each { |m| (strip-fen $m.fen | chessdb zobrist) }))
    $g.moves | enumerate | each { |item|
      let row = $item.item
      { from_hash: ($hashes | get $item.index), to_hash: (strip-fen $row.fen | chessdb zobrist), uci: $row.uci, san: $row.san }
    }
  } | flatten)
  
  if not ($all_edges | is-empty) {
    let unique_edges = ($all_edges | insert key { |e| $e.from_hash + $e.to_hash + $e.uci } | uniq-by key)
    let move_stmts = ($unique_edges | chunks-of $chunk_size | each { |chunk| bulk-insert-moves $chunk })
    run-sql $db_path $move_stmts
  }

  print "Import complete (Structural Collapse enabled)."
}

def account-upsert-sql [platform: string, username: string, is_me: bool] {
  if ($username | is-empty) { "" } else {
    let p_q = (sql-string $platform)
    let u_q = (sql-string $username)
    let me = if $is_me { 1 } else { 0 }
    "INSERT INTO accounts (platform, username, is_me) VALUES (" + $p_q + "," + $u_q + "," + ($me | into string) + ") ON CONFLICT(platform, username) DO UPDATE SET is_me = excluded.is_me;"
  }
}
