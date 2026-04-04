use ./utils.nu *
use ./config.nu *

def critter-config [] {
  let cfg = load-config
  $cfg.enrichment.critter
}

def critter-binary [] {
  let ccfg = critter-config
  let configured = ($ccfg.binary | default "")
  if ($configured | is-empty) == false and ($configured | path exists) {
    $configured
  } else {
    let release = "../critter-eval/target/release/critter-eval"
    let debug = "../critter-eval/target/debug/critter-eval"
    if ($release | path exists) {
      $release
    } else if ($debug | path exists) {
      $debug
    } else if ($configured | is-empty) == false {
      $configured
    } else {
      error make {
        msg: "critter-eval binary is not configured in config/nuchessdb.nuon and was not found at ../critter-eval/target/{release,debug}/critter-eval"
      }
    }
  }
}

def critter-name [] {
  let ccfg = critter-config
  ($ccfg.name | default "critter-eval")
}

def critter-model [] {
  let ccfg = critter-config
  ($ccfg.model | default "")
}

def parse-critter-output [text: string] {
  let records = (
    $text
    | lines
    | where { |line| not ($line | str trim | is-empty) }
    | each { |line| $line | from json }
  )

  if ($records | is-empty) {
    error make { msg: "critter-eval returned no records" }
  }

  $records | first
}

def save-critter-eval [db, position_id: int, record: record] {
  let created_at = (date now | format date "%Y-%m-%d %H:%M:%S")
  let sql = ([
    "INSERT INTO position_critter_evals (position_id, critter_name, critter_model, normalized_fen, phase, final_score, engine_score, legal_is_legal, legal_is_check, legal_is_checkmate, legal_is_stalemate, legal_is_insufficient_material, legal_move_count, material_json, pawn_structure_json, piece_activity_json, king_safety_json, passed_pawns_json, development_json, scaling_value, scaling_factor, drawishness_value, drawishness_factor, override_value, override_factor, checks_sum_groups, checks_matches_final, checks_delta, analysis_json, created_at) VALUES (",
    ($position_id | into string), ", ", (sql-string (critter-name)), ", ", (sql-string (critter-model)), ", ", (sql-string $record.normalized_fen), ", ", (sql-int $record.phase), ", ", ($record.final_score | into string), ", ", (sql-int $record.engine_score), ", ", (bool-int $record.legal.is_legal), ", ", (bool-int $record.legal.is_check), ", ", (bool-int $record.legal.is_checkmate), ", ", (bool-int $record.legal.is_stalemate), ", ", (bool-int $record.legal.is_insufficient_material), ", ", ($record.legal.legal_move_count | into string), ", ", (sql-string ($record.groups.material | to json)), ", ", (sql-string ($record.groups.pawn_structure | to json)), ", ", (sql-string ($record.groups.piece_activity | to json)), ", ", (sql-string ($record.groups.king_safety | to json)), ", ", (sql-string ($record.groups.passed_pawns | to json)), ", ", (sql-string ($record.groups.development | to json)), ", ", (sql-int $record.groups.scaling.value), ", ", (sql-int $record.groups.scaling.factor), ", ", (sql-int $record.groups.drawishness.value), ", ", (sql-int $record.groups.drawishness.factor), ", ", (sql-int $record.groups.override.value), ", ", (sql-int $record.groups.override.factor), ", ", (sql-int $record.checks.sum_groups), ", ", (bool-int $record.checks.matches_final), ", ", (sql-int $record.checks.delta), ", ", (sql-string ($record | to json)), ", ", (sql-string $created_at), ") ON CONFLICT(position_id, critter_name, critter_model) DO UPDATE SET normalized_fen = excluded.normalized_fen, phase = excluded.phase, final_score = excluded.final_score, engine_score = excluded.engine_score, legal_is_legal = excluded.legal_is_legal, legal_is_check = excluded.legal_is_check, legal_is_checkmate = excluded.legal_is_checkmate, legal_is_stalemate = excluded.legal_is_stalemate, legal_is_insufficient_material = excluded.legal_is_insufficient_material, legal_move_count = excluded.legal_move_count, material_json = excluded.material_json, pawn_structure_json = excluded.pawn_structure_json, piece_activity_json = excluded.piece_activity_json, king_safety_json = excluded.king_safety_json, passed_pawns_json = excluded.passed_pawns_json, development_json = excluded.development_json, scaling_value = excluded.scaling_value, scaling_factor = excluded.scaling_factor, drawishness_value = excluded.drawishness_value, drawishness_factor = excluded.drawishness_factor, override_value = excluded.override_value, override_factor = excluded.override_factor, checks_sum_groups = excluded.checks_sum_groups, checks_matches_final = excluded.checks_matches_final, checks_delta = excluded.checks_delta, analysis_json = excluded.analysis_json, created_at = excluded.created_at;"
  ] | str join)

  $db | query db $sql | ignore
}

export def refresh-critter-enrichment-queue [limit: int = 100000] {
  let cfg = load-config
  let db_path = $cfg.database.path

  open $db_path | query db ([
    "INSERT INTO position_critter_eval_queue (position_id, priority, source, status, queued_at) SELECT p.id, COALESCE(s.occurrences, 0) AS priority, 'popular' AS source, 'pending' AS status, datetime('now') AS queued_at FROM positions p LEFT JOIN position_color_stats s ON s.position_id = p.id LEFT JOIN position_critter_evals e ON e.position_id = p.id AND e.critter_name = ", (sql-string (critter-name)), " AND e.critter_model = ", (sql-string (critter-model)), " WHERE e.position_id IS NULL ORDER BY COALESCE(s.occurrences, 0) DESC, p.id DESC LIMIT ", ($limit | into string), " ON CONFLICT(position_id) DO UPDATE SET priority = excluded.priority, source = excluded.source, status = 'pending', queued_at = excluded.queued_at;"
  ] | str join)
}

export def queued-critter-evals [limit: int = 50] {
  let cfg = load-config
  let db_path = $cfg.database.path

  open $db_path | query db ([
    "SELECT q.position_id, q.priority, q.status, q.source, q.queued_at, p.canonical_hash, p.canonical_fen, COALESCE(s.occurrences, 0) AS occurrences FROM position_critter_eval_queue q JOIN positions p ON p.id = q.position_id LEFT JOIN position_color_stats s ON s.position_id = p.id WHERE q.status = 'pending' ORDER BY q.priority DESC, q.queued_at ASC LIMIT ", ($limit | into string)
  ] | str join)
}

export def critter-queue-stats [] {
  let cfg = load-config
  let db_path = $cfg.database.path

  open $db_path | query db "SELECT status, COUNT(*) AS count FROM position_critter_eval_queue GROUP BY status ORDER BY status"
}

export def critter-eval-queue [limit: int = 20] {
  let cfg = load-config
  let db = (open $cfg.database.path)
  let binary = (critter-binary)

  let _ = (refresh-critter-enrichment-queue)
  let jobs = (queued-critter-evals $limit)

  if ($jobs | is-empty) {
    { evaluated: 0, message: "queue empty" }
  } else {
    let evaluated = (
      $jobs
      | each { |job|
          let position_id = $job.position_id
          let fen = $job.canonical_fen
          let started_at = (date now | format date "%Y-%m-%d %H:%M:%S")
          $db | query db (["UPDATE position_critter_eval_queue SET status = 'running', started_at = ", (sql-string $started_at), ", last_error = NULL WHERE position_id = ", ($position_id | into string), ";"] | str join) | ignore

          try {
            let raw = ($fen | ^($binary))
            let record = (parse-critter-output $raw)
            save-critter-eval $db $position_id $record
            let finished_at = (date now | format date "%Y-%m-%d %H:%M:%S")
            $db | query db (["UPDATE position_critter_eval_queue SET status = 'done', finished_at = ", (sql-string $finished_at), " WHERE position_id = ", ($position_id | into string), ";"] | str join) | ignore
            { position_id: $position_id, status: "done", final_score: $record.final_score, normalized_fen: $record.normalized_fen }
          } catch { |err|
            let finished_at = (date now | format date "%Y-%m-%d %H:%M:%S")
            let err_text = if ($err | columns | any { |c| $c == "msg" }) { $err.msg } else { $err | to text }
            $db | query db (["UPDATE position_critter_eval_queue SET status = 'failed', finished_at = ", (sql-string $finished_at), ", last_error = ", (sql-string $err_text), " WHERE position_id = ", ($position_id | into string), ";"] | str join) | ignore
            { position_id: $position_id, status: "failed", error: $err_text }
          }
        }
    )

    { evaluated: ($evaluated | length), rows: $evaluated }
  }
}
