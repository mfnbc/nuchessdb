use ./utils.nu *
use ./config.nu *
use ./db.nu *
use ./critter.nu *

def headers-list-to-record [headers: list<record>] {
  $headers | reduce -f {} { |row, acc| $acc | upsert $row.key $row.value }
}

export def bulk-insert-positions [rows: list<record>] {
  let values = ($rows | each { |row|
    let fen = (strip-fen $row.fen)
    let hash = $row.hash
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

export def bulk-insert-moves [rows: list<record>] {
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

export def calculate-stats-stmts [edges: list<record>] {
  # Position Stats
  let pos_stats = ($edges | group-by to_hash | items { |hash, group|
    let w_wins = ($group | where result == "1-0" | length)
    let b_wins = ($group | where result == "0-1" | length)
    let draws  = ($group | where result == "1/2-1/2" | length)
    let total  = ($group | length)
    
    let me_wins = ($group | where { |r| ($r.is_me_white and $r.result == "1-0") or ($r.is_me_black and $r.result == "0-1") } | length)
    let me_losses = ($group | where { |r| ($r.is_me_white and $r.result == "0-1") or ($r.is_me_black and $r.result == "1-0") } | length)
    let me_draws = ($group | where { |r| ($r.is_me_white or $r.is_me_black) and $r.result == "1/2-1/2" } | length)
    let me_total = ($me_wins + $me_losses + $me_draws)

    let h_val = $hash
    let w_val = ($w_wins | into string)
    let d_val = ($draws | into string)
    let b_val = ($b_wins | into string)
    let t_val = ($total | into string)
    let mw_val = ($me_wins | into string)
    let md_val = ($me_draws | into string)
    let ml_val = ($me_losses | into string)
    let mt_val = ($me_total | into string)

    [
      "INSERT INTO position_color_stats (position_id, white_wins, draws, black_wins, occurrences, me_wins, me_draws, me_losses, me_occurrences) VALUES ("
      "(SELECT id FROM positions WHERE canonical_hash = '", $h_val, "'),"
      $w_val, "," $d_val, "," $b_val, "," $t_val, "," $mw_val, "," $md_val, "," $ml_val, "," $mt_val, ")"
      " ON CONFLICT(position_id) DO UPDATE SET "
      "white_wins = white_wins + excluded.white_wins, "
      "draws = draws + excluded.draws, "
      "black_wins = black_wins + excluded.black_wins, "
      "occurrences = occurrences + excluded.occurrences, "
      "me_wins = me_wins + excluded.me_wins, "
      "me_draws = me_draws + excluded.me_draws, "
      "me_losses = me_losses + excluded.me_losses, "
      "me_occurrences = me_occurrences + excluded.me_occurrences;"
    ] | str join
  })

  # Move Stats
  let move_stats = ($edges | group-by { |e| $e.from_hash + $e.to_hash + $e.uci } | items { |key, group|
    let first = ($group | first)
    let w_wins = ($group | where result == "1-0" | length)
    let b_wins = ($group | where result == "0-1" | length)
    let draws  = ($group | where result == "1/2-1/2" | length)
    let total  = ($group | length)

    let me_wins = ($group | where { |r| ($r.is_me_white and $r.result == "1-0") or ($r.is_me_black and $r.result == "0-1") } | length)
    let me_losses = ($group | where { |r| ($r.is_me_white and $r.result == "0-1") or ($r.is_me_black and $r.result == "1-0") } | length)
    let me_draws = ($group | where { |r| ($r.is_me_white or $r.is_me_black) and $r.result == "1/2-1/2" } | length)
    let me_total = ($me_wins + $me_losses + $me_draws)

    let from_hash = $first.from_hash
    let to_hash = $first.to_hash
    let uci = $first.uci

    let w_val = ($w_wins | into string)
    let b_val = ($b_wins | into string)
    let d_val = ($draws | into string)
    let t_val = ($total | into string)
    let mw_val = ($me_wins | into string)
    let ml_val = ($me_losses | into string)
    let md_val = ($me_draws | into string)
    let mt_val = ($me_total | into string)

    [
      "INSERT INTO move_stats (move_id, white_wins, draws, black_wins, occurrences, me_wins, me_draws, me_losses, me_occurrences) VALUES ("
      "(SELECT id FROM moves WHERE from_position_id = (SELECT id FROM positions WHERE canonical_hash = '", $from_hash, "')"
      " AND to_position_id = (SELECT id FROM positions WHERE canonical_hash = '", $to_hash, "')"
      " AND move_uci = '", $uci, "'),"
      $w_val, "," $d_val, "," $b_val, "," $t_val, "," $mw_val, "," $md_val, "," $ml_val, "," $mt_val, ")"
      " ON CONFLICT(move_id) DO UPDATE SET "
      "white_wins = white_wins + excluded.white_wins, "
      "draws = draws + excluded.draws, "
      "black_wins = black_wins + excluded.black_wins, "
      "occurrences = occurrences + excluded.occurrences, "
      "me_wins = me_wins + excluded.me_wins, "
      "me_draws = me_draws + excluded.me_draws, "
      "me_losses = me_losses + excluded.me_losses, "
      "me_occurrences = me_occurrences + excluded.me_occurrences;"
    ] | str join
  })

  $pos_stats | append $move_stats
}

def account-upsert-sql [platform: string, username: string, is_me: bool] {
  if ($username | is-empty) { "" } else {
    let p_q = (sql-string $platform)
    let u_q = (sql-string $username)
    let me = if $is_me { 1 } else { 0 }
    "INSERT INTO accounts (platform, username, is_me) VALUES (" + $p_q + "," + $u_q + "," + ($me | into string) + ") ON CONFLICT(platform, username) DO UPDATE SET is_me = excluded.is_me;"
  }
}

export def import-pgn-file [path: string, platform: string] {
  let cfg = load-config
  let db_path = $cfg.database.path
  let text = (open $path)
  
  # Optimize database for bulk writes
  open $db_path | query db "PRAGMA journal_mode=WAL;" | ignore
  open $db_path | query db "PRAGMA synchronous=NORMAL;" | ignore
  
  # Use scan-pgn first for lightweight game/result mapping
  print "Scanning PGN..."
  let scan_data = ($text | chessdb scan-pgn)
  
  # Use pgn-to-batch for full move/FEN data
  print "Parsing batch..."
  let batch = ($text | chessdb pgn-to-batch)
  
  let initial_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
  let initial_hash = (strip-fen $initial_fen | chessdb zobrist)
  let me_username = (if $platform == "chesscom" { $cfg.identity.me.chesscom } else { $cfg.identity.me.lichess })
  let chunk_size = 400

  # 1. Unique Positions (Stripped)
  let unique_positions = ($batch.unique_positions | rename -c {zobrist: hash} | uniq-by hash)
  
  # Insert positions (ON CONFLICT DO NOTHING handles duplicates)
  let pos_stmts = ($unique_positions | chunks-of $chunk_size | each { |chunk| bulk-insert-positions $chunk })
  run-sql $db_path $pos_stmts
  
  # Check which positions already have Critter evals (batch query)
  let position_hashes = ($unique_positions | get hash | each { |h| "'" + $h + "'" } | str join ", ")
  let existing_evals = if ($position_hashes | is-empty) { [] } else {
    open $db_path | query db ([
      "SELECT p.canonical_hash FROM positions p ",
      "JOIN position_critter_evals e ON e.position_id = p.id ",
      "WHERE p.canonical_hash IN (", $position_hashes, ")"
    ] | str join)
  }
  let hashes_with_evals = if ($existing_evals | is-empty) { [] } else { $existing_evals | get canonical_hash }
  let needs_eval = ($unique_positions | where { |p| not ($p.hash in $hashes_with_evals) })

  # 2. Accounts & Games (with path_json)
  let account_stmts = ($batch.games | each { |g|
    let headers = (headers-list-to-record $g.headers)
    let white = ($headers | get -o White | default "")
    let black = ($headers | get -o Black | default "")
    [
      (account-upsert-sql $platform $white ($me_username != "" and ($white | str downcase) == ($me_username | str downcase)))
      (account-upsert-sql $platform $black ($me_username != "" and ($black | str downcase) == ($me_username | str downcase)))
    ]
  } | flatten | where { |s| not ($s | is-empty) } | uniq)

  let game_stmts = ($batch.games | each { |g|
    let headers = (headers-list-to-record $g.headers)
    let white = ($headers | get -o White | default "")
    let black = ($headers | get -o Black | default "")
    
    # Path hashes are already pre-computed in the moves array!
    let move_hashes = ($g.moves | get zobrist)
    let path_hashes = ([$initial_hash] | append $move_hashes)
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

    ["INSERT INTO games (platform, source_game_id, white_account_id, black_account_id, result, raw_pgn, path_json, imported_at) VALUES (", $platform_q, ",", $src_q, ",", $white_account, ",", $black_account, ",", $res_q, ",", $pgn_q, ",", $path_q, ", datetime('now')) ON CONFLICT DO NOTHING;"] | str join
  })
  
  run-sql $db_path ($account_stmts | append $game_stmts | where { |s| not ($s | is-empty) })

  # 3. Moves (Edges)
  let all_edges = ($batch.games | each { |g|
    let headers = (headers-list-to-record $g.headers)
    let white = ($headers | get -o White | default "")
    let black = ($headers | get -o Black | default "")
    let is_me_white = ($me_username != "" and ($white | str downcase) == ($me_username | str downcase))
    let is_me_black = ($me_username != "" and ($black | str downcase) == ($me_username | str downcase))
    
    let move_hashes = ($g.moves | get zobrist)
    let hashes = ([$initial_hash] | append $move_hashes)
    
    $g.moves | enumerate | each { |item|
      let row = $item.item
      { 
        from_hash: ($hashes | get $item.index), 
        to_hash: ($hashes | get ($item.index + 1)), 
        uci: $row.uci, 
        san: $row.san,
        result: $g.result,
        is_me_white: $is_me_white,
        is_me_black: $is_me_black,
        full_fen: $row.fen # Keep for critter
      }
    }
  } | flatten)
  
  if not ($all_edges | is-empty) {
    let unique_edges = ($all_edges | insert key { |e| $e.from_hash + $e.to_hash + $e.uci } | uniq-by key)
    let move_stmts = ($unique_edges | chunks-of $chunk_size | each { |chunk| bulk-insert-moves $chunk })
    run-sql $db_path $move_stmts
  }

  # 4. Statistics (Global & Me)
  print "Calculating statistics..."
  let stat_stmts = (calculate-stats-stmts $all_edges)
  run-sql $db_path $stat_stmts

  # 5. In-line Critter Evaluation (always enabled)
  # Note: needs_eval was already computed above (positions without Critter evals)
  
  if not ($needs_eval | is-empty) {
      print $"Evaluating ($needs_eval | length) new positions with batch Critter analysis..."
      use ./critter.nu *
      let c_cfg = (load-config | get enrichment.critter)
      let cn = ($c_cfg.name | default "critter-eval")
      let cm = ($c_cfg.model | default "")
      let created_at = (date now | format date "%Y-%m-%d %H:%M:%S")
      
      # Batch evaluation - send all FENs at once
      let target_fens = ($needs_eval | get fen)
      let eval_records = ($target_fens | chessdb critter-eval)
      
      # Combine hashes with evaluation results
      let evals = ($needs_eval | enumerate | each { |item|
          { hash: $item.item.hash, eval_record: ($eval_records | get $item.index) }
      })
      
      # Batch fetch position IDs for all evaluated positions
      if not ($evals | is-empty) {
          let eval_hashes = ($evals | get hash | each { |h| "'" + $h + "'" } | str join ", ")
          let position_ids = (open $db_path | query db ([
            "SELECT id, canonical_hash FROM positions WHERE canonical_hash IN (", $eval_hashes, ")"
          ] | str join))
          
          # Join evals with position IDs
          let evals_with_ids = ($evals | each { |e|
              let pos_id = ($position_ids | where canonical_hash == $e.hash | get 0.id)
              { position_id: $pos_id, eval_record: $e.eval_record }
          })
          
          let eval_stmts = (bulk-critter-eval-insert-sql $evals_with_ids $cn $cm $created_at)
          run-sql $db_path $eval_stmts
      }
  }

  print "Import complete (Structural Collapse, Stats, and Critter enabled)."
}
