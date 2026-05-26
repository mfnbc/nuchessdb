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
               json_group_array(CASE WHEN m.color='white' THEN p.hugm_score ELSE -p.hugm_score END) as scores_json,
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

    let anomaly_count = ((open $db | query db "
        SELECT COUNT(*) as cnt FROM move_anomalies
        WHERE username = ? AND consumed = 0
    " --params [$username] | first | get cnt) | into int)

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
            let scores = try { $row.scores_json | from json | sort } catch { [] }
            let n = ($row.n | into int)
            let median = if ($scores | length) > 0 {
                let mid = ($scores | length) // 2
                if ($scores | length) mod 2 == 0 {
                    (($scores | get $mid | into float) + ($scores | get ($mid - 1) | into float)) / 2.0 | math round --precision 0
                } else {
                    $scores | get $mid | into float | math round --precision 0
                }
            } else { 0.0 }
            let avg = ($row.score_from_player | into float)
            let std_dev = if ($scores | length) > 1 {
                let cnt = ($scores | length) - 1
                let variance = ($scores | each {|s| let v = ($s | into float) - $avg; $v * $v } | math sum) / ($cnt | into float)
                $variance | math sqrt | math round --precision 0
            } else { 0.0 }
            let entry = if ($acc | get -o $name) == null { {} } else { $acc | get $name }
            let new_entry = ($entry | upsert $color_key {
                n: $row.n,
                avg_score_cp: ($avg | math round --precision 0),
                median_score_cp: $median,
                score_std_dev: $std_dev,
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

    # ── Anomalies (simple queries first, avoids Nu 0.111 parse ordering issues) ──
    let anomalies = (open $db | query db "
        SELECT ma.game_id, ma.ply, ROUND(MAX(ma.z_score),2) as z, ROUND(MAX(ma.severity),0) as sev,
               MAX(ma.signed_delta) as sd, MAX(ma.hurt_player) as hp,
               MAX(CASE WHEN ms.king_exposed = 1 THEN 1 ELSE 0 END) as king_involved
        FROM move_anomalies ma
        LEFT JOIN move_states ms ON ma.game_id = ms.game_id AND ma.ply = ms.ply
        WHERE ma.username = ? AND ma.consumed = 0
        GROUP BY ma.game_id, ma.ply ORDER BY sev DESC LIMIT 5
    " --params [$username])

    let anomaly_split = (sqlite3 $db "SELECT hurt_player, COUNT(*) as cnt FROM move_anomalies WHERE username = '" + $username + "' AND consumed = 0 GROUP BY hurt_player;" | detect columns)

    let anomaly_split_by_color = (sqlite3 $db "SELECT m.color, ma.hurt_player, COUNT(*) as cnt FROM move_anomalies ma JOIN moves m ON ma.game_id = m.game_id AND ma.ply = m.ply WHERE ma.username = '" + $username + "' AND ma.consumed = 0 GROUP BY m.color, ma.hurt_player;" | detect columns)

    let king_blunder_count = ((sqlite3 $db "SELECT COUNT(*) as cnt FROM move_anomalies ma JOIN move_states ms ON ma.game_id = ms.game_id AND ma.ply = ms.ply WHERE ma.username = '" + $username + "' AND ma.consumed = 0 AND ma.hurt_player = 1 AND ms.king_exposed = 1;" | detect columns | get cnt | first | default 0) | into int)

    # Opponent blunders in this player's games (opportunities to capitalize)
    let opponent_blunder_count = (open $db | query db "
        SELECT COUNT(*) as cnt
        FROM move_anomalies ma
        WHERE ma.game_id IN (SELECT game_id FROM games WHERE white = ? OR black = ?)
          AND ma.username != ? AND ma.consumed = 0 AND ma.hurt_player = 1
    " --params [$username, $username, $username] | first | get cnt)

    let capitalized = if ($anomaly_split | is-not-empty) {
        ($anomaly_split | where {|r| not $r.hurt_player } | first | get count)
    } else { 0 }
    let missed = if $opponent_blunder_count > $capitalized {
        $opponent_blunder_count - $capitalized
    } else { 0 }

    # ── Concept examples ──
    # ── Positional components ──
    let positional = $positional_raw | each {|r|
            let arr = try { $r.hugm_eval_arr | from json } catch { [] }
            let raw_king = (if ($arr | length) > 3 { $arr | get 3 | into int } else { 0 })
            { color: $r.color, phase: $r.phase,
              pawns: (if ($arr | length) > 1 { $arr | get 1 | into int } else { 0 }),
              activity: (if ($arr | length) > 2 { $arr | get 2 | into int } else { 0 }),
              own_king_safety_cp: (if $r.color == "black" { -1 * $raw_king } else { $raw_king }) }
        }
        | group-by {|r| $"($r.color):($r.phase)"}
        | items {|key, group|
            let n = ($group | length)
            let parts = ($key | split row ":")
            { color: $parts.0, phase: $parts.1,
              n: $n,
              pawns: (($group | get pawns | math sum) / ($n | into float) | math round --precision 1),
              activity: (($group | get activity | math sum) / ($n | into float) | math round --precision 1),
              own_king_safety_cp: (($group | get own_king_safety_cp | math sum) / ($n | into float) | math round --precision 1) }
        }

    # ── Mate analysis ──
    let mate_analysis = (open $db | query db "
        WITH mate_positions AS (
            SELECT m.game_id, m.ply, m.color,
                   CASE WHEN m.color='white' THEN g.white ELSE g.black END as player,
                   p.mate_in_1,
                   n.is_checkmate as next_is_checkmate
            FROM moves m
            JOIN positions p ON m.next_position_id = p.zobrist
            LEFT JOIN moves m2 ON m.game_id=m2.game_id AND m.ply+1=m2.ply
            LEFT JOIN positions n ON m2.next_position_id = n.zobrist
            JOIN games g ON m.game_id=g.game_id
            WHERE p.mate_in_1 > 0 AND (g.white = ? OR g.black = ?)
        )
        SELECT CASE WHEN player = ? THEN 'player' ELSE 'opponent' END as who,
               COUNT(*) as opportunities,
               SUM(CASE WHEN next_is_checkmate=1 THEN 1 ELSE 0 END) as found,
               COUNT(*) - SUM(CASE WHEN next_is_checkmate=1 THEN 1 ELSE 0 END) as missed
        FROM mate_positions
        GROUP BY CASE WHEN player = ? THEN 'player' ELSE 'opponent' END
    " --params [$username, $username, $username, $username])

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
        blunders_per_game: ((($anomaly_split | where {|r| $r.hurt_player } | default [{count: 0}] | first | get count) | into float) / (($game_count | into int | default 1) | into float) | math round --precision 2),
        sign_convention: "avg_score_cp always from player's perspective: positive=good for player (e.g. +200cp means player is up 2 pawns). King safety in positional_components: positive=White's king is safe (negative=Black's king is safe).",
        phase_profile: $phase_profile,
        positional_components: $positional,
        concepts: $concepts,
        anomalies: ($anomalies | each {|a| {
            game_id: ($a.game_id | into string), ply: $a.ply,
            z_score: $a.z, severity_cp: $a.sev,
            signed_delta: ($a.sd | default 0 | into int),
            hurt_player: ($a.hp | default 0 | into bool),
            king_involved: ($a.king_involved | default 0 | into bool)
        }}),
        anomaly_split: ($anomaly_split | each {|r| {
            hurt_player: ($r.hurt_player | into bool),
            count: ($r.cnt | into int)
        }}),
        king_blunder_count: $king_blunder_count,
        capitalization: { opponent_blunders: $opponent_blunder_count, you_capitalized: $capitalized, you_missed: $missed },
        anomaly_split_by_color: ($anomaly_split_by_color | each {|r| {
            color: ($r.color | into string),
            hurt_player: ($r.hurt_player | into bool),
            count: ($r.cnt | into int)
        }}),
        concept_examples: $concept_examples,
    }
    print ($profile | to json -r)
}
