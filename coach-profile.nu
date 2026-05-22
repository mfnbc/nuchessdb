#!/usr/bin/env nu

# coach-profile.nu — player collapse & concept profile
# Outputs a structured JSON record for LLM consumption or pipeline use.
# Pipe to | table or | explore for display, or pass through nu-agent for coaching.
#
# Usage: nu coach-profile.nu <username> [--db <path>] [--examples N]

def _db_path [] { "./chess.db" }

def main [username: string, --db: string, --examples: int = 3] {
    let db = if ($db != null) { $db } else { (_db_path) }

    if not ($db | path exists) {
        print ({ error: "database not found" } | to json -r)
        return
    }

    # ── Queries ──
    let phase_baselines = (open $db | query db "
        SELECT m.color,
               CASE WHEN m.ply <= 12 THEN 'opening'
                    WHEN m.ply <= 30 THEN 'midgame'
                    WHEN m.ply <= 50 THEN 'late_mid'
                    ELSE 'endgame' END as phase,
               COUNT(*) as n,
               AVG(CASE WHEN m.color='white' THEN p.hugm_score ELSE -p.hugm_score END) as score_from_player,
               AVG(ABS(p.hugm_score)) as abs_material
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        JOIN games g ON m.game_id = g.game_id
        WHERE (g.white = ? OR g.black = ?)
          AND (m.color = 'white' AND g.white = ? OR m.color = 'black' AND g.black = ?)
        GROUP BY m.color, phase ORDER BY m.color, CASE phase WHEN 'opening' THEN 1 WHEN 'midgame' THEN 2 WHEN 'late_mid' THEN 3 ELSE 4 END
    " --params [$username, $username, $username, $username])

    let concept_baselines = (open $db | query db "
        SELECT concept_name, phase_bucket, mean, std
        FROM player_baselines WHERE username = ? AND concept_name != 'hugm_delta'
        ORDER BY concept_name, phase_bucket
    " --params [$username])

    let anomaly_count = (open $db | query db "
        SELECT COUNT(*) as cnt FROM move_anomalies
        WHERE username = ? AND consumed = 0
    " --params [$username] | first | get cnt)

    let positional_raw = (open $db | query db "
        SELECT m.color,
               CASE WHEN m.ply <= 12 THEN 'opening'
                    WHEN m.ply <= 30 THEN 'midgame'
                    WHEN m.ply <= 50 THEN 'late_mid'
                    ELSE 'endgame' END as phase,
               p.hugm_eval_arr
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        JOIN games g ON m.game_id = g.game_id
        WHERE g.white = ? OR g.black = ?
    " --params [$username, $username])

    let game_count = (open $db | query db "
        SELECT COUNT(DISTINCT m.game_id) as cnt
        FROM moves m JOIN games g ON m.game_id = g.game_id
        WHERE g.white = ? OR g.black = ?
    " --params [$username, $username] | first | get cnt)

    # ── Phase profile: material by color and phase (from player's perspective) ──
    let phase_profile = if ($phase_baselines | is-not-empty) {
        $phase_baselines | reduce -f {} {|row, acc|
            let name = $row.phase
            let color_key = $"as_($row.color)"
            let entry = if ($acc | get -o $name) == null { {} } else { $acc | get $name }
            let new_entry = ($entry | upsert $color_key {
                n: $row.n,
                avg_score_cp: ($row.score_from_player | math round --precision 0),
                avg_abs_material_cp: ($row.abs_material | math round --precision 0)
            })
            $acc | upsert $name $new_entry
        }
    } else { {} }

    # ── Concepts ──
    let concepts = if ($concept_baselines | is-not-empty) {
        $concept_baselines
        | group-by concept_name
        | items {|name, rows|
            let total = ($rows | length)
            let avg = ($rows | get mean | math avg | math round --precision 0)
            { concept: $name, occurrences: $total, avg_severity: $avg }
        }
        | sort-by occurrences --reverse
    } else { [] }

    # ── Positional components ──
    let positional = if ($positional_raw | length) > 100 {
        $positional_raw | each {|r|
            let arr = try { $r.hugm_eval_arr | from json } catch { [] }
            { color: $r.color, phase: $r.phase,
              pawns: (if ($arr | length) > 1 { $arr | get 1 | into int } else { 0 }),
              activity: (if ($arr | length) > 2 { $arr | get 2 | into int } else { 0 }),
              king: (if ($arr | length) > 3 { $arr | get 3 | into int } else { 0 }) }
        }
        | group-by {|r| $"($r.color):($r.phase)"}
        | items {|key, group|
            let n = ($group | length)
            let parts = ($key | split row ":")
            { color: $parts.0, phase: $parts.1,
              n: $n,
              pawns: (($group | get pawns | math sum) / ($n | into float) | math round --precision 1),
              activity: (($group | get activity | math sum) / ($n | into float) | math round --precision 1),
              king: (($group | get king | math sum) / ($n | into float) | math round --precision 1) }
        }
    } else { [] }

    # ── Anomalies ──
    let anomalies = if $anomaly_count > 0 {
        (open $db | query db "
            SELECT game_id, ply, ROUND(MAX(z_score),2) as z, ROUND(MAX(severity),0) as sev
            FROM move_anomalies WHERE username = ? AND consumed = 0
            GROUP BY game_id, ply ORDER BY sev DESC LIMIT 5
        " --params [$username])
    } else { [] }

    # ── Concept examples ──
    let concept_examples = if ($examples > 0) and ($concepts | length) > 0 {
        let top_names = ($concepts | first 3 | get concept)
        $top_names | reduce -f {} {|cname, acc|
            let positions = (open $db | query db "
                SELECT ma.game_id, ma.ply, MAX(ma.z_score) as z, MAX(ma.severity) as sev, p.fen, p.hugm_score
                FROM move_anomalies ma
                JOIN moves m ON ma.game_id = m.game_id AND ma.ply = m.ply
                JOIN positions p ON m.next_position_id = p.zobrist
                WHERE ma.username = ? AND ma.consumed = 0 AND ma.concept_name = ?
                GROUP BY ma.game_id, ma.ply
                ORDER BY sev DESC LIMIT ?
            " --params [$username, $cname, $examples])
            $acc | insert $cname ($positions | each {|p| {
                game_id: ($p.game_id | into string), ply: $p.ply,
                z_score: ($p.z | math round --precision 2),
                severity_cp: $p.sev, fen: $p.fen, hugm_score: $p.hugm_score
            }})
        }
    } else { {} }

    # ── Output: single structured JSON record ──
    let profile = {
        player: $username,
        games: $game_count,
        unreviewed_anomalies: $anomaly_count,
        sign_convention: "avg_score_cp always from player's perspective: positive=good for player (e.g. +200cp means player is up 2 pawns). King safety in positional_components: positive=White's king is safe (negative=Black's king is safe).",
        phase_profile: $phase_profile,
        positional_components: $positional,
        concepts: $concepts,
        anomalies: ($anomalies | each {|a| {
            game_id: ($a.game_id | into string), ply: $a.ply,
            z_score: $a.z, severity_cp: $a.sev
        }}),
        concept_examples: $concept_examples,
    }
    print ($profile | to json -r)
}
