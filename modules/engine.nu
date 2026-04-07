use ./utils.nu *
use ./config.nu *

def engine-config [] {
  let cfg = load-config
  $cfg.enrichment.engine
}

def engine-binary [] {
  let ecfg = engine-config
  if ($ecfg.binary | is-empty) {
    error make { msg: "engine binary is not configured in config/nuchessdb.nuon" }
  }
  $ecfg.binary
}

def engine-name [] {
  let ecfg = engine-config
  ($ecfg.name | default "stockfish")
}

def engine-model [] {
  let ecfg = engine-config
  ($ecfg.model | default "")
}

def engine-depth [] {
  let ecfg = engine-config
  ($ecfg.depth | default 12)
}

def engine-movetime [] {
  let ecfg = engine-config
  ($ecfg.movetime_ms | default 0)
}

def engine-best-move-san [fen: string, uci: any] {
  if ($uci == null or ($uci | is-empty)) {
    null
  } else {
    $fen | chessdb uci-to-san $uci
  }
}

def parse-engine-output [text: string] {
  let lines = ($text | lines)
  let info = {
    centipawn: null
    mate: null
    best_move_uci: null
    analysis_json: $text
  }

  $lines | reduce -f $info { |line, acc|
    if ($line | str starts-with "bestmove ") {
      let parts = ($line | split row " ")
      $acc | upsert best_move_uci ($parts | get 1? | default null)
    } else if ($line | str contains " score cp ") {
      let parsed = ($line | parse --regex 'score cp (?<cp>-?\d+)')
      if (($parsed | is-empty) == false) {
        $acc | upsert centipawn (($parsed | get 0).cp | into int)
      } else {
        $acc
      }
    } else if ($line | str contains " score mate ") {
      let parsed = ($line | parse --regex 'score mate (?<mate>-?\d+)')
      if (($parsed | is-empty) == false) {
        $acc | upsert mate (($parsed | get 0).mate | into int)
      } else {
        $acc
      }
    } else {
      $acc
    }
  }
}

def save-engine-eval [db, position_id: int, engine_name: string, engine_model: string, depth: int, nodes: int, centipawn: any, mate: any, best_move_uci: any, best_move_san: any, analysis_json: string] {
  let created_at = (date now | format date "%Y-%m-%d %H:%M:%S")
  let sql = ([
    "INSERT INTO position_engine_evals (position_id, engine_name, engine_model, depth, nodes, centipawn, mate, best_move_uci, best_move_san, analysis_json, created_at) VALUES (",
    ($position_id | into string), ", ", (sql-string $engine_name), ", ", (sql-string $engine_model), ", ", ($depth | into string), ", ", ($nodes | into string), ", ", (sql-int $centipawn), ", ", (sql-int $mate), ", ", (sql-string $best_move_uci), ", ", (sql-string $best_move_san), ", ", (sql-string $analysis_json), ", ", (sql-string $created_at), ") ON CONFLICT(position_id, engine_name, engine_model) DO UPDATE SET depth = excluded.depth, nodes = excluded.nodes, centipawn = excluded.centipawn, mate = excluded.mate, best_move_uci = excluded.best_move_uci, best_move_san = excluded.best_move_san, analysis_json = excluded.analysis_json, created_at = excluded.created_at;"
  ] | str join)

  $db | query db $sql | ignore
}

export def eval-queue [limit: int = 20] {
  let cfg = load-config
  let db = (open $cfg.database.path)
  let fixture_mode = ($env | get -o NUCHESSDB_TEST_ENGINE_MODE | default "")
  let binary = (if $fixture_mode == "fixture" { null } else { (engine-binary) })
  let jobs = ($db | query db ([
    "SELECT q.position_id, p.canonical_fen, q.priority FROM position_enrichment_queue q JOIN positions p ON p.id = q.position_id WHERE q.status = 'pending' ORDER BY q.priority DESC, q.queued_at ASC LIMIT ", ($limit | into string)
  ] | str join))

  if ($jobs | is-empty) {
    { evaluated: 0, message: "queue empty" }
  } else {
    let evaluated = (
        $jobs
        | each { |job|
            let position_id = $job.position_id
            let fen = $job.canonical_fen
          let depth = (engine-depth)
          let movetime = (engine-movetime)
          let engine_name = (engine-name)
          let engine_model = (engine-model)
          let started_at = (date now | format date "%Y-%m-%d %H:%M:%S")
          $db | query db (["UPDATE position_enrichment_queue SET status = 'running', started_at = ", (sql-string $started_at), ", last_error = NULL WHERE position_id = ", ($position_id | into string), ";"] | str join) | ignore

          try {
            let parsed = if $fixture_mode == "fixture" {
              {
                centipawn: 0
                mate: null
                best_move_uci: "e2e4"
                analysis_json: "fixture"
              }
            } else {
              let eval_lines = if $movetime > 0 {
                ["uci", "isready", ($'position fen ($fen)'), ($'go movetime ($movetime)'), "quit"]
              } else {
                ["uci", "isready", ($'position fen ($fen)'), ($'go depth ($depth)'), "quit"]
              }

              let raw = ($eval_lines | str join "\n" | ^($binary))
              parse-engine-output $raw
            }
            let best_move_san = (engine-best-move-san $fen $parsed.best_move_uci)
            save-engine-eval $db $position_id $engine_name $engine_model $depth 0 $parsed.centipawn $parsed.mate $parsed.best_move_uci $best_move_san $parsed.analysis_json

            let finished_at = (date now | format date "%Y-%m-%d %H:%M:%S")
            $db | query db (["UPDATE position_enrichment_queue SET status = 'done', finished_at = ", (sql-string $finished_at), " WHERE position_id = ", ($position_id | into string), ";"] | str join) | ignore
            { position_id: $position_id, engine_name: $engine_name, engine_model: $engine_model, centipawn: $parsed.centipawn, mate: $parsed.mate, best_move_uci: $parsed.best_move_uci, best_move_san: $best_move_san }
          } catch { |err|
            let finished_at = (date now | format date "%Y-%m-%d %H:%M:%S")
            let err_text = if ($err | columns | any { |c| $c == "msg" }) { $err.msg } else { $err | to text }
            $db | query db (["UPDATE position_enrichment_queue SET status = 'failed', finished_at = ", (sql-string $finished_at), ", last_error = ", (sql-string $err_text), " WHERE position_id = ", ($position_id | into string), ";"] | str join) | ignore
            { position_id: $position_id, engine_name: $engine_name, engine_model: $engine_model, error: $err_text }
          }
        }
    )

    { evaluated: ($evaluated | length), rows: $evaluated }
  }
}

export def engine-summary [limit: int = 20] {
  let cfg = load-config
  let db_path = $cfg.database.path

  open $db_path | query db ([
    "SELECT p.canonical_hash, p.canonical_fen, e.engine_name, e.engine_model, e.depth, e.nodes, e.centipawn, e.mate, e.best_move_uci, e.best_move_san, e.created_at FROM position_engine_evals e JOIN positions p ON p.id = e.position_id ORDER BY e.created_at DESC LIMIT ", ($limit | into string)
  ] | str join)
}
