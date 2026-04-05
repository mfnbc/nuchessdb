use ./utils.nu *
use ./config.nu *
use ./db.nu *

# Split a list into non-overlapping chunks of at most chunk_size items.
def chunks-of [chunk_size: int] {
  let rows = $in
  let total = ($rows | length)
  if $total == 0 { return [] }
  let num_chunks = (($total + $chunk_size - 1) // $chunk_size)
  seq 0 ($num_chunks - 1) | each { |i|
    $rows | skip ($i * $chunk_size) | first $chunk_size
  }
}

# Build a single VALUES row tuple string for bulk critter-eval INSERT.
# Returns a string like: (42,'name','model','fen',...)
# Schema mirrors critter-eval/src/position.rs PositionRecord
def critter-eval-values-row [
    position_id: int,
    eval_record: record<
        fen: string,
        normalized_fen: string,
        side_to_move: string,
        phase: int,
        final_score: int,
        engine_score: any,        # Option<i64> — null when no engine score provided
        legal: record<
            is_legal: bool,
            is_check: bool,
            is_checkmate: bool,
            is_stalemate: bool,
            is_insufficient_material: bool,
            legal_move_count: int
        >,
        groups: record<
            material:       record<mg: int, eg: int, blended: int, terms: record>,
            pawn_structure: record<mg: int, eg: int, blended: int, terms: record>,
            piece_activity: record<mg: int, eg: int, blended: int, terms: record>,
            king_safety:    record<mg: int, eg: int, blended: int, terms: record>,
            passed_pawns:   record<mg: int, eg: int, blended: int, terms: record>,
            development:    record<mg: int, eg: int, blended: int, terms: record>,
            scaling:     record<value: int, factor: int>,
            drawishness: record<value: int, factor: int>,
            override_:   record<value: int, factor: int>
        >,
        checks: record<
            sum_groups: int,
            matches_final: bool,
            delta: any            # Option<i64> — null when no engine score provided
        >
    >,
    cn: string,
    cm: string,
    created_at: string
] {
  [
    "(", ($position_id | into string), ",",
    (sql-string $cn), ",", (sql-string $cm), ",",
    (sql-string $eval_record.normalized_fen), ",",
    (sql-int $eval_record.phase), ",",
    ($eval_record.final_score | into string), ",",
    (sql-int $eval_record.engine_score), ",",
    (bool-int $eval_record.legal.is_legal), ",",
    (bool-int $eval_record.legal.is_check), ",",
    (bool-int $eval_record.legal.is_checkmate), ",",
    (bool-int $eval_record.legal.is_stalemate), ",",
    (bool-int $eval_record.legal.is_insufficient_material), ",",
    ($eval_record.legal.legal_move_count | into string), ",",
    (sql-string ($eval_record.groups.material | to json)), ",",
    (sql-string ($eval_record.groups.pawn_structure | to json)), ",",
    (sql-string ($eval_record.groups.piece_activity | to json)), ",",
    (sql-string ($eval_record.groups.king_safety | to json)), ",",
    (sql-string ($eval_record.groups.passed_pawns | to json)), ",",
    (sql-string ($eval_record.groups.development | to json)), ",",
    (sql-int $eval_record.groups.scaling.value), ",",
    (sql-int $eval_record.groups.scaling.factor), ",",
    (sql-int $eval_record.groups.drawishness.value), ",",
    (sql-int $eval_record.groups.drawishness.factor), ",",
    (sql-int $eval_record.groups.override_.value), ",",
    (sql-int $eval_record.groups.override_.factor), ",",
    (sql-int $eval_record.checks.sum_groups), ",",
    (bool-int $eval_record.checks.matches_final), ",",
    (sql-int $eval_record.checks.delta), ",",
    (sql-string ($eval_record | to json)), ",",
    (sql-string $created_at),
    ")"
  ] | str join
}

# Build a list of bulk INSERT SQL statements (chunked at 400 rows) for critter evals.
# evals: list of {position_id: int, eval_record: record}
def bulk-critter-eval-insert-sql [evals: list<record<position_id: int, eval_record: record>>, cn: string, cm: string, created_at: string] {
  let conflict_clause = (
    " ON CONFLICT(position_id, critter_name, critter_model) DO UPDATE SET" +
    " normalized_fen=excluded.normalized_fen, phase=excluded.phase," +
    " final_score=excluded.final_score, engine_score=excluded.engine_score," +
    " legal_is_legal=excluded.legal_is_legal, legal_is_check=excluded.legal_is_check," +
    " legal_is_checkmate=excluded.legal_is_checkmate, legal_is_stalemate=excluded.legal_is_stalemate," +
    " legal_is_insufficient_material=excluded.legal_is_insufficient_material," +
    " legal_move_count=excluded.legal_move_count," +
    " material_json=excluded.material_json, pawn_structure_json=excluded.pawn_structure_json," +
    " piece_activity_json=excluded.piece_activity_json, king_safety_json=excluded.king_safety_json," +
    " passed_pawns_json=excluded.passed_pawns_json, development_json=excluded.development_json," +
    " scaling_value=excluded.scaling_value, scaling_factor=excluded.scaling_factor," +
    " drawishness_value=excluded.drawishness_value, drawishness_factor=excluded.drawishness_factor," +
    " override_value=excluded.override_value, override_factor=excluded.override_factor," +
    " checks_sum_groups=excluded.checks_sum_groups, checks_matches_final=excluded.checks_matches_final," +
    " checks_delta=excluded.checks_delta, analysis_json=excluded.analysis_json," +
    " created_at=excluded.created_at"
  )
  let header = (
    "INSERT INTO position_critter_evals" +
    " (position_id, critter_name, critter_model, normalized_fen, phase, final_score, engine_score," +
    " legal_is_legal, legal_is_check, legal_is_checkmate, legal_is_stalemate," +
    " legal_is_insufficient_material, legal_move_count," +
    " material_json, pawn_structure_json, piece_activity_json, king_safety_json," +
    " passed_pawns_json, development_json," +
    " scaling_value, scaling_factor, drawishness_value, drawishness_factor," +
    " override_value, override_factor," +
    " checks_sum_groups, checks_matches_final, checks_delta, analysis_json, created_at) VALUES "
  )
  $evals | chunks-of 400 | each { |chunk|
    let values = ($chunk | each { |e| critter-eval-values-row $e.position_id $e.eval_record $cn $cm $created_at } | str join ",")
    $header + $values + $conflict_clause
  }
}

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

def critter-fixture-record [fen: string] {
  {
    fen: $fen
    normalized_fen: $fen
    side_to_move: 'white'
    phase: 0
    final_score: 0
    engine_score: null
    legal: {
      is_legal: true
      is_check: false
      is_checkmate: false
      is_stalemate: false
      is_insufficient_material: false
      legal_move_count: 1
    }
    groups: {
      material: { mg: 0, eg: 0, blended: 0, terms: {} }
      pawn_structure: { mg: 0, eg: 0, blended: 0, terms: {} }
      piece_activity: { mg: 0, eg: 0, blended: 0, terms: {} }
      king_safety: { mg: 0, eg: 0, blended: 0, terms: {} }
      passed_pawns: { mg: 0, eg: 0, blended: 0, terms: {} }
      development: { mg: 0, eg: 0, blended: 0, terms: {} }
      scaling: { value: 0, factor: 1 }
      drawishness: { value: 0, factor: 1 }
      override_: { value: 0, factor: 1 }
    }
    checks: { sum_groups: 0, matches_final: true, delta: null }
  }
}

export def refresh-critter-enrichment-queue [limit: int = 100000] {
  let cfg = load-config
  let db_path = $cfg.database.path

  open $db_path | query db ([
    "INSERT INTO position_critter_eval_queue (position_id, priority, source, status, queued_at) SELECT p.id, COALESCE(s.occurrences, 0) AS priority, 'popular' AS source, 'pending' AS status, datetime('now') AS queued_at FROM positions p LEFT JOIN position_color_stats s ON s.position_id = p.id LEFT JOIN position_critter_evals e ON e.position_id = p.id AND e.critter_name = ", (sql-string (critter-name)), " AND e.critter_model = ", (sql-string (critter-model)), " WHERE e.position_id IS NULL AND COALESCE(s.occurrences, 0) >= 3 ORDER BY COALESCE(s.occurrences, 0) DESC, p.id DESC LIMIT ", ($limit | into string), " ON CONFLICT(position_id) DO UPDATE SET priority = excluded.priority, source = excluded.source, status = 'pending', queued_at = excluded.queued_at;"
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
  let db_path = $cfg.database.path
  let binary = (critter-binary)
  let cn = (critter-name)
  let cm = (critter-model)
  let fixture_mode = ($env | get -o NUCHESSDB_TEST_CRITTER_MODE | default "")

  # WAL mode: reduces write contention, avoids full-db locks on each fsync
  open $db_path | query db "PRAGMA journal_mode=WAL;" | ignore

  let _ = (refresh-critter-enrichment-queue)
  let jobs = (queued-critter-evals $limit)

  if ($jobs | is-empty) {
    { evaluated: 0, message: "queue empty" }
  } else {
    # Bulk pre-mark all jobs as running in a single UPDATE (1 query db call)
    let started_at = (date now | format date "%Y-%m-%d %H:%M:%S")
    let ids_in = ($jobs | get position_id | each { into string } | str join ", ")
    open $db_path | query db (["UPDATE position_critter_eval_queue SET status = 'running', started_at = ", (sql-string $started_at), ", last_error = NULL WHERE position_id IN (", $ids_in, ");"] | str join) | ignore

    let finished_at = (date now | format date "%Y-%m-%d %H:%M:%S")

    # Parse results into lists — no DB calls inside this loop
    let results = if $fixture_mode == "fixture" {
      $jobs | each { |job|
        { position_id: $job.position_id, status: "done", error: null, record: (critter-fixture-record $job.canonical_fen) }
      }
    } else {
      let fens_input = ($jobs | get canonical_fen | str join "\n")
      let raw_output = (try { $fens_input | ^($binary) } catch { "" })
      let output_lines = ($raw_output | lines | where { |line| not ($line | str trim | is-empty) })

      $jobs
      | enumerate
      | each { |item|
          let job = $item.item
          let idx = $item.index
          let position_id = $job.position_id

          if $idx >= ($output_lines | length) {
            { position_id: $position_id, status: "failed", error: "no output from critter-eval for this position", record: null }
          } else {
            try {
              let record = ($output_lines | get $idx | from json)
              { position_id: $position_id, status: "done", error: null, record: $record }
            } catch { |err|
              let err_text = if ($err | columns | any { |c| $c == "msg" }) { $err.msg } else { $err | to text }
              { position_id: $position_id, status: "failed", error: $err_text, record: null }
            }
          }
        }
    }

    let done_results   = ($results | where status == "done")
    let failed_results = ($results | where status == "failed")

    # Bulk INSERT all successful evals (1 query db call per 400 evals)
    let eval_stmts = if ($done_results | is-empty) { [] } else {
      let evals = ($done_results | each { |r| { position_id: $r.position_id, eval_record: $r.record } })
      bulk-critter-eval-insert-sql $evals $cn $cm $finished_at
    }

    # Bulk UPDATE done statuses (1 query db call)
    let done_update = if ($done_results | is-empty) { [] } else {
      let done_ids = ($done_results | get position_id | each { into string } | str join ", ")
      [([
        "UPDATE position_critter_eval_queue SET status = 'done', finished_at = ",
        (sql-string $finished_at),
        " WHERE position_id IN (", $done_ids, ");"
      ] | str join)]
    }

    # Individual UPDATE per failed position (rare; 1 call each)
    let failed_updates = ($failed_results | each { |r|
      [
        "UPDATE position_critter_eval_queue SET status = 'failed', finished_at = ",
        (sql-string $finished_at), ", last_error = ", (sql-string $r.error),
        " WHERE position_id = ", ($r.position_id | into string), ";"
      ] | str join
    })

    # Execute all writes in a single run-sql call (BEGIN/COMMIT + for-loop)
    let all_stmts = ($eval_stmts | append $done_update | append $failed_updates)
    if not ($all_stmts | is-empty) {
      run-sql $db_path $all_stmts
    }

    # Build return rows (same shape as before)
    let rows = (
      $results
      | each { |r|
          if $r.status == "done" {
            { position_id: $r.position_id, status: "done", final_score: $r.record.final_score, normalized_fen: $r.record.normalized_fen }
          } else {
            { position_id: $r.position_id, status: "failed", error: $r.error }
          }
        }
    )

    { evaluated: ($done_results | length), rows: $rows }
  }
}

export def critter-enqueue-games [limit: int = 100000] {
  let cfg = load-config
  let db_path = $cfg.database.path

  open $db_path | query db ([
    "INSERT INTO position_critter_eval_queue (position_id, priority, source, status, queued_at) SELECT p.id, 0 AS priority, 'game-sweep' AS source, 'pending' AS status, datetime('now') AS queued_at FROM positions p INNER JOIN game_positions gp ON gp.position_after_id = p.id INNER JOIN games g ON g.id = gp.game_id LEFT JOIN position_critter_evals e ON e.position_id = p.id AND e.critter_name = ", (sql-string (critter-name)), " AND e.critter_model = ", (sql-string (critter-model)), " WHERE e.position_id IS NULL GROUP BY p.id ORDER BY MAX(g.played_at) DESC LIMIT ", ($limit | into string), " ON CONFLICT(position_id) DO UPDATE SET source = excluded.source, status = 'pending', queued_at = excluded.queued_at;"
  ] | str join)
}
