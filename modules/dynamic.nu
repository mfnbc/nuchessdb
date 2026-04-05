use ./utils.nu *
use ./config.nu *
use ./db.nu *

def dynamic-config [] {
  let cfg = load-config
  $cfg.enrichment.dynamic
}

def dynamic-engine-name [] {
  let dcfg = dynamic-config
  ($dcfg.engine_name | default "lc0")
}

def dynamic-elo-tune [] {
  let dcfg = dynamic-config
  ($dcfg.elo_tune | default 1200)
}

def dynamic-engine-binary [] {
  let dcfg = dynamic-config
  let binary = ($dcfg.binary | default "")
  if ($binary | is-empty) {
    error make { msg: "enrichment.dynamic.binary is not configured in config/nuchessdb.nuon" }
  }
  $binary
}

def dynamic-depth [] {
  let dcfg = dynamic-config
  ($dcfg.depth | default 12)
}

def ensure-dynamic-profile-id [] {
  let cfg = load-config
  let db_path = $cfg.database.path
  let engine_name = (dynamic-engine-name)
  let elo_tune = (dynamic-elo-tune)
  let engine_name_q = (sql-string $engine_name)
  let elo_q = (sql-int $elo_tune)
  let created_at_q = (sql-string (date now | format date "%Y-%m-%d %H:%M:%S"))

  open $db_path | query db ([
    "INSERT INTO dynamic_model_profiles (engine_name, elo_tune, created_at) VALUES (", $engine_name_q, ", ", $elo_q, ", ", $created_at_q, ") ON CONFLICT(engine_name, elo_tune) DO NOTHING;"
  ] | str join) | ignore

  let rows = (open $db_path | query db ([
    "SELECT id FROM dynamic_model_profiles WHERE engine_name = ", $engine_name_q, " AND elo_tune = ", $elo_q, " LIMIT 1;"
  ] | str join))

  if ($rows | is-empty) {
    error make { msg: "failed to resolve dynamic model profile id" }
  }

  $rows.0.id
}

export def refresh-dynamic-enrichment-queue [limit: int = 100000] {
  let cfg = load-config
  let db_path = $cfg.database.path
  let profile_id = (ensure-dynamic-profile-id)
  let profile_id_q = (sql-int $profile_id)

  open $db_path | query db ([
    "INSERT INTO position_dynamic_queue (position_zobrist, profile_id, priority, source, status, queued_at) SELECT p.canonical_hash, ", $profile_id_q, ", COALESCE(s.occurrences, 0) AS priority, 'popular' AS source, 'pending' AS status, datetime('now') AS queued_at FROM positions p LEFT JOIN position_color_stats s ON s.position_id = p.id LEFT JOIN position_dynamic_runs r ON r.position_zobrist = p.canonical_hash AND r.profile_id = ", $profile_id_q, " WHERE r.id IS NULL ORDER BY COALESCE(s.occurrences, 0) DESC, p.id DESC LIMIT ", ($limit | into string), " ON CONFLICT(position_zobrist, profile_id) DO UPDATE SET priority = excluded.priority, source = excluded.source, status = 'pending', queued_at = excluded.queued_at;"
  ] | str join)

  { profile_id: $profile_id, engine_name: (dynamic-engine-name), elo_tune: (dynamic-elo-tune), queued: true }
}

export def queued-dynamic-runs [limit: int = 50] {
  let cfg = load-config
  let db_path = $cfg.database.path

  open $db_path | query db ([
    "SELECT q.position_zobrist, q.profile_id, q.priority, q.status, q.source, q.queued_at, p.canonical_fen, COALESCE(s.occurrences, 0) AS occurrences, m.engine_name, m.elo_tune FROM position_dynamic_queue q JOIN positions p ON p.canonical_hash = q.position_zobrist JOIN dynamic_model_profiles m ON m.id = q.profile_id LEFT JOIN position_color_stats s ON s.position_id = p.id WHERE q.status = 'pending' ORDER BY q.priority DESC, q.queued_at ASC LIMIT ", ($limit | into string)
  ] | str join)
}

export def dynamic-queue-stats [] {
  let cfg = load-config
  let db_path = $cfg.database.path

  open $db_path | query db "SELECT status, COUNT(*) AS count FROM position_dynamic_queue GROUP BY status ORDER BY status"
}

def dynamic-position-to-san [fen: string, uci: any] {
  if ($uci == null or ($uci | is-empty)) {
    null
  } else {
    $fen | shakmaty uci-to-san $uci
  }
}

def parse-dynamic-output [text: string] {
  let lines = ($text | lines)
  let bestmove = (
    $lines
    | where { |line| $line | str starts-with "bestmove " }
    | last?
    | default ""
  )
  let bestmove_uci = if ($bestmove | is-empty) {
    null
  } else {
    ($bestmove | split row " " | get 1? | default null)
  }

  let parsed = (
    $lines
    | where { |line| ($line | str starts-with "info ") and ($line | str contains " multipv ") and ($line | str contains " pv ") }
    | each { |line|
        let parts = ($line | split row " pv ")
        let left = ($parts | get 0)
        let pv = ($parts | get 1? | default "")
        let rank_res = ($left | parse --regex 'multipv (?<rank>\d+)')
        let rank = if ($rank_res | is-empty) { null } else { (($rank_res | get 0).rank | into int) }
        let cp_res = ($left | parse --regex 'score cp (?<score>-?\d+)')
        let mate_res = ($left | parse --regex 'score mate (?<score>-?\d+)')
        let score = if ($cp_res | is-empty) == false { ($cp_res | get 0).score | into int } else { null }
        let mate = if ($mate_res | is-empty) == false { ($mate_res | get 0).score | into int } else { null }

        if $rank == null {
          null
        } else {
          {
            rank: $rank,
            move_uci: (($pv | split row " " | get 0?) | default null),
            q_cp: $score,
            q_mate: $mate,
            pv: $pv,
          }
        }
      }
    | compact
    | reduce -f {} { |row, acc| $acc | upsert ($row.rank | into string) $row }
  )

  let top_moves = ($parsed | values | sort-by rank)
  let top_move = ($top_moves | first?)

  {
    top_moves: $top_moves,
    best_move_uci: (if $bestmove_uci != null { $bestmove_uci } else if $top_move != null { $top_move.move_uci } else { null }),
    value_cp: (if $top_move == null { null } else { $top_move.q_cp }),
    value_mate: (if $top_move == null { null } else { $top_move.q_mate }),
    analysis_json: $text,
  }
}

def save-dynamic-run [position_zobrist: string, profile_id: int, fen: string, parsed: record, depth: int, nodes: int] {
  let cfg = load-config
  let db_path = $cfg.database.path
  let created_at = (date now | format date "%Y-%m-%d %H:%M:%S")
  let side_to_move = ($fen | split row " " | get 1?)
  let best_move_san = (dynamic-position-to-san $fen $parsed.best_move_uci)
  let run_sql = ([
    "INSERT INTO position_dynamic_runs (position_zobrist, profile_id, position_fen, side_to_move, depth, nodes, value_cp, value_mate, best_move_uci, best_move_san, analysis_json, created_at) VALUES (",
    (sql-string $position_zobrist), ", ", (sql-int $profile_id), ", ", (sql-string $fen), ", ", (sql-string $side_to_move), ", ", ($depth | into string), ", ", ($nodes | into string), ", ", (sql-int $parsed.value_cp), ", ", (sql-int $parsed.value_mate), ", ", (sql-string $parsed.best_move_uci), ", ", (sql-string $best_move_san), ", ", (sql-string $parsed.analysis_json), ", ", (sql-string $created_at), ") ON CONFLICT(position_zobrist, profile_id) DO UPDATE SET position_fen = excluded.position_fen, side_to_move = excluded.side_to_move, depth = excluded.depth, nodes = excluded.nodes, value_cp = excluded.value_cp, value_mate = excluded.value_mate, best_move_uci = excluded.best_move_uci, best_move_san = excluded.best_move_san, analysis_json = excluded.analysis_json, created_at = excluded.created_at;"
  ] | str join)

  run-sql $db_path [$run_sql]

  let run_rows = (open $db_path | query db ([
    "SELECT id FROM position_dynamic_runs WHERE position_zobrist = ", (sql-string $position_zobrist), " AND profile_id = ", (sql-int $profile_id), " LIMIT 1;"
  ] | str join))

  if ($run_rows | is-empty) {
    error make { msg: "failed to resolve dynamic run id" }
  }

  let run_id = $run_rows.0.id

  let top_move_stmts = (
    $parsed.top_moves
    | enumerate
    | each { |it|
        let move = $it.item
        let rank = ($it.index + 1)
        let move_san = (dynamic-position-to-san $fen $move.move_uci)
        [
          "INSERT INTO position_dynamic_top_moves (run_id, move_rank, move_uci, move_san, prior, q_cp, q_mate, value_cp, pv, analysis_json, created_at) VALUES (",
          ($run_id | into string), ", ", ($rank | into string), ", ", (sql-string $move.move_uci), ", ", (sql-string $move_san), ", NULL, ", (sql-int $move.q_cp), ", ", (sql-int $move.q_mate), ", ", (sql-int $move.q_cp), ", ", (sql-string $move.pv), ", ", (sql-string ($move | to json)), ", ", (sql-string $created_at), ");"
        ] | str join
      }
  )

  let delete_stmt = (["DELETE FROM position_dynamic_top_moves WHERE run_id = ", ($run_id | into string), ";"] | str join)
  run-sql $db_path ([$delete_stmt] | append $top_move_stmts)

  { run_id: $run_id, best_move_uci: $parsed.best_move_uci, best_move_san: $best_move_san, top_moves: $parsed.top_moves }
}

export def dynamic-eval-queue [limit: int = 20] {
  let cfg = load-config
  let db_path = $cfg.database.path
  let binary = (dynamic-engine-binary)
  let profile_id = (ensure-dynamic-profile-id)
  let depth = (dynamic-depth)
  let elo_tune = (dynamic-elo-tune)
  let engine_name = (dynamic-engine-name)
  let _ = (refresh-dynamic-enrichment-queue $limit)
  let jobs = (queued-dynamic-runs $limit)

  if ($jobs | is-empty) {
    { evaluated: 0, message: "queue empty" }
  } else {
    let evaluated = (
      $jobs
      | each { |job|
          let position_zobrist = $job.position_zobrist
          let fen = $job.canonical_fen
          let started_at = (date now | format date "%Y-%m-%d %H:%M:%S")
          open $db_path | query db (["UPDATE position_dynamic_queue SET status = 'running', started_at = ", (sql-string $started_at), ", last_error = NULL WHERE position_zobrist = ", (sql-string $position_zobrist), " AND profile_id = ", (sql-int $profile_id), ";"] | str join) | ignore

          try {
            let eval_lines = [
              "uci",
              ($'setoption name MultiPV value 5'),
              ($'setoption name UCI_LimitStrength value true'),
              ($'setoption name UCI_Elo value ($elo_tune)'),
              "isready",
              ($'position fen ($fen)'),
              ($'go depth ($depth)'),
              "quit"
            ]
            let raw = ($eval_lines | str join "\n" | ^($binary))
            let parsed = (parse-dynamic-output $raw)
            let saved = (save-dynamic-run $position_zobrist $profile_id $fen $parsed $depth 0)
            let finished_at = (date now | format date "%Y-%m-%d %H:%M:%S")
            open $db_path | query db (["UPDATE position_dynamic_queue SET status = 'done', finished_at = ", (sql-string $finished_at), " WHERE position_zobrist = ", (sql-string $position_zobrist), " AND profile_id = ", (sql-int $profile_id), ";"] | str join) | ignore
            { position_zobrist: $position_zobrist, engine_name: $engine_name, elo_tune: $elo_tune, best_move_uci: $saved.best_move_uci, best_move_san: $saved.best_move_san }
          } catch { |err|
            let finished_at = (date now | format date "%Y-%m-%d %H:%M:%S")
            let err_text = if ($err | columns | any { |c| $c == "msg" }) { $err.msg } else { $err | to text }
            open $db_path | query db (["UPDATE position_dynamic_queue SET status = 'failed', finished_at = ", (sql-string $finished_at), ", last_error = ", (sql-string $err_text), " WHERE position_zobrist = ", (sql-string $position_zobrist), " AND profile_id = ", (sql-int $profile_id), ";"] | str join) | ignore
            { position_zobrist: $position_zobrist, engine_name: $engine_name, elo_tune: $elo_tune, error: $err_text }
          }
        }
    )

    { evaluated: ($evaluated | length), rows: $evaluated }
  }
}
