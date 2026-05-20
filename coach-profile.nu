#!/usr/bin/env nu

# coach-profile.nu — player collapse & concept profile
#
# Two modes:
#   Terminal (default): pretty bar-chart display
#   JSON (--json): structured output for nu-agent coach consumption
#
# Usage: nu coach-profile.nu <username> [--db <path>] [--json] [--examples N]

def _db_path [] { "./chess.db" }

def main [username: string, --db: string, --json, --examples: int = 3] {
    let db = if ($db != null) { $db } else { (_db_path) }

    if not ($db | path exists) {
        if $json { print ({ error: "database not found" } | to json -r) } else { print $"Database ($db) not found." }
        return
    }

    # ── Shared queries ──
    let phase_baselines = (open $db | query db "
        SELECT phase_bucket, mean, m2, count
        FROM player_baselines WHERE username = ? AND concept_name = 'hugm_delta'
        ORDER BY phase_bucket
    " --params [$username])

    let concept_baselines = (open $db | query db "
        SELECT concept_name, phase_bucket, mean, m2, count
        FROM player_baselines WHERE username = ? AND concept_name != 'hugm_delta'
        ORDER BY concept_name, phase_bucket
    " --params [$username])

    let anomaly_count = (open $db | query db "
        SELECT COUNT(*) as cnt FROM move_anomalies
        WHERE username = ? AND consumed = 0
    " --params [$username] | first | get cnt)

    # Positional component averages by color and phase
    let positional_raw = (open $db | query db "
        SELECT m.color, ms.phase_bucket, p.hugm_eval_arr
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        JOIN games g ON m.game_id = g.game_id
        JOIN move_states ms ON m.game_id = ms.game_id AND m.ply = ms.ply
        WHERE g.white = ? OR g.black = ?
    " --params [$username, $username])

    let positional = if ($positional_raw | length) > 100 {
        $positional_raw | each {|r|
            let arr = try { $r.hugm_eval_arr | from json } catch { [] }
            let mat = if ($arr | length) > 0 { $arr | get 0 | into int } else { 0 }
            let pwn = if ($arr | length) > 1 { $arr | get 1 | into int } else { 0 }
            let act = if ($arr | length) > 2 { $arr | get 2 | into int } else { 0 }
            let kng = if ($arr | length) > 3 { $arr | get 3 | into int } else { 0 }
            { color: $r.color, phase: ($r.phase_bucket | into int),
              material: $mat, pawns: $pwn, activity: $act, king: $kng }
        }
        | group-by {|r| $"($r.color):($r.phase)"}
        | items {|key, group|
            let n = ($group | length)
            let parts = ($key | split row ":")
            let phase_name = match ($parts.1 | into int) {
                0 => "endgame", 1 => "late_mid", 2 => "midgame", _ => "opening"
            }
            {
                color: $parts.0, phase: $phase_name, n: $n,
                pawns: (($group | get pawns | math sum) / ($n | into float) | math round --precision 1),
                activity: (($group | get activity | math sum) / ($n | into float) | math round --precision 1),
                king: (($group | get king | math sum) / ($n | into float) | math round --precision 1),
            }
        }
    } else { [] }

    let game_count = (open $db | query db "
        SELECT COUNT(DISTINCT m.game_id) as cnt
        FROM moves m JOIN games g ON m.game_id = g.game_id
        WHERE g.white = ? OR g.black = ?
    " --params [$username, $username] | first | get cnt)

    # ── Aggregate phase profile ──
    let phase_profile = if ($phase_baselines | is-not-empty) {
        $phase_baselines | reduce -f {} {|row, acc|
            let name = match ($row.phase_bucket | into int) {
                0 => "endgame", 1 => "late_mid", 2 => "midgame", _ => "opening"
            }
            let sd = if $row.count > 1 {
                let v = ($row.m2 | into float) / (($row.count - 1) | into float)
                if $v > 0.0 { $v | math sqrt | math round --precision 0 } else { 0.0 }
            } else { 0.0 }
            $acc | insert $name { mean_cp: ($row.mean | math round --precision 0), std_cp: $sd }
        }
    } else { {} }

    # ── Aggregate concepts ──
    let concept_aggregates = if ($concept_baselines | is-not-empty) {
        $concept_baselines
        | group-by concept_name
        | items {|name, rows|
            let total = ($rows | get count | math sum)
            let wsum = ($rows | each {|r| ($r.mean | into float) * ($r.count | into float) } | math sum)
            let avg = if $total > 0 { ($wsum / ($total | into float) | math round --precision 0) } else { 0.0 }
            { concept: $name, occurrences: $total, avg_severity: $avg, total_cost: ($avg * ($total | into float)) }
        }
        | sort-by total_cost --reverse
    } else { [] }

    # ── Anomalies ──
    let anomalies = if $anomaly_count > 0 {
        (open $db | query db "
            SELECT game_id, ply, ROUND(MAX(z_score),2) as z, ROUND(MAX(severity),0) as sev
            FROM move_anomalies WHERE username = ? AND consumed = 0
            GROUP BY game_id, ply ORDER BY sev DESC LIMIT 5
        " --params [$username])
    } else { [] }

    # ── Example positions for top concepts ──
    let concept_examples = if ($examples > 0) and ($concept_aggregates | length) > 0 {
        # Get the top-N concept names
        let top_concepts = ($concept_aggregates | first 3 | get concept)

        $top_concepts | reduce -f {} {|cname, acc|
            # Find positions for this specific concept
            let positions = (open $db | query db "
                SELECT ma.game_id, ma.ply, ma.z_score, ma.severity, p.fen, p.hugm_score
                FROM move_anomalies ma
                JOIN moves m ON ma.game_id = m.game_id AND ma.ply = m.ply
                JOIN positions p ON m.next_position_id = p.zobrist
                WHERE ma.username = ?1 AND ma.consumed = 0 AND ma.concept_name = ?2
                ORDER BY ABS(ma.severity) DESC LIMIT ?3
            " --params [$username, $cname, $examples])

            $acc | insert $cname ($positions | each {|p| {
                game_id: $p.game_id,
                ply: $p.ply,
                z_score: ($p.z_score | math round --precision 2),
                severity_cp: $p.severity,
                fen: $p.fen,
                hugm_score: $p.hugm_score,
            }})
        }
    } else { {} }

    # ── Output ──
    if $json {
        let profile = {
            player: $username
            games: $game_count
            unreviewed_anomalies: $anomaly_count
            phase_profile: $phase_profile
            positional_components: ($positional)
            concepts: ($concept_aggregates)
            anomalies: ($anomalies | each {|a| {
                game_id: ($a.game_id | into string), ply: $a.ply,
                z_score: $a.z, severity_cp: $a.sev
            }})
            concept_examples: $concept_examples
        }
        print ($profile | to json -r)
        return
    }

    # ── Terminal display ──
    print $"(ansi green)╔══════════════════════════════════════╗"
    print $"(ansi green)║  Coach Profile: ($username | fill -w 21 -a l)║"
    print $"(ansi green)╚══════════════════════════════════════╝(ansi reset)"
    print $"  Games in DB: ($game_count)"
    print $"  Unreviewed anomalies: ($anomaly_count)"
    print ""

    if ($phase_baselines | is-not-empty) {
        print $"(ansi green_bold)Eval swing by phase(ansi reset)"
        print ""
        mut tc = 0.0; mut tn = 0.0
        for row in $phase_baselines {
            let name = match ($row.phase_bucket | into int) {
                0 => "Endgame   ", 1 => "Late mid  ", 2 => "Midgame   ", _ => "Opening   "
            }
            let mean = ($row.mean | math round --precision 0)
            let blen = if ($mean / 20.0 | into int) > 30 { 30 } else { ($mean / 20.0 | into int) }
            let bar = if $blen > 0 { (0..<$blen | each { "█" } | str join) } else { "" }
            print $"  ($name) μ=($mean | fill -w 5 -a l)cp  ($bar)"
            $tc = $tc + ($row.mean | into float) * ($row.count | into float)
            $tn = $tn + ($row.count | into float)
        }
        if $tn > 0.0 { print ""; print $"  Average eval swing: (($tc / $tn | math round --precision 0))cp per move" }
    }

    if ($positional | is-not-empty) {
        let header = $"(ansi green_bold)Positional components — avg cp per move(ansi reset)"
        print ""; print $header; print ""
        let hdr_color = ("color" | fill -w 10)
        let hdr_phase = ("phase" | fill -w 10)
        let hdr_n = ("n" | fill -w 6)
        print $"  ($hdr_color) ($hdr_phase) ($hdr_n)  pawns  activity   king"
        print $"  ---------- ---------- ------  -----  --------  -----"
        for row in $positional {
            let color = ($row.color | fill -w 10)
            let phase = ($row.phase | fill -w 10)
            print $"  ($color) ($phase) ($row.n | fill -w 6)  ($row.pawns | fill -w 6)  ($row.activity | fill -w 9)  ($row.king | fill -w 6)"
        }
    }

    if ($concept_baselines | is-not-empty) {
        print ""; print $"(ansi green_bold)Concepts you encounter(ansi reset)"; print ""
        for row in $concept_aggregates {
            let label = match $row.concept {
                "collapse" => "Collapse (exchange)     "
                "collapse_accuracy" => "  ↳ chain accuracy %     "
                "collapse_miss_cp" => "  ↳ avg cp left on table "
                "pin" => "Pin (pinned piece)       "
                "skewer" => "Skewer (x-ray attack)   "
                "discovered_attack" => "Discovered attack      "
                "hanging_piece" => "Hanging piece          "
                "material_imbalance" => "Material imbalance    "
                "king_in_check" => "King in check          "
                _ => $"($row.concept | fill -w 24 -a l)"
            }
            let blen = if ($row.occurrences | into int) > 40 { 40 } else { ($row.occurrences | into int) }
            let bar = if $blen > 0 { (0..<$blen | each { "░" } | str join) } else { "" }
            let cost = if $row.avg_severity > 0 {
                match $row.concept {
                    "collapse_accuracy" => $"avg ($row.avg_severity)%"
                    "collapse_miss_cp" => $"avg ($row.avg_severity)cp missed"
                    _ => $"~($row.avg_severity)cp each"
                }
            } else { "tracking" }
            print $"  ($label) ($row.occurrences | fill -w 4 -a l)×   ($cost | fill -w 14 -a l)($bar)"
        }
    } else {
        print ""; print $"(ansi yellow)No concept-level data yet.(ansi reset)"
        print $"  Run: nu nuchessdb.nu dictionary-update ($username)"
    }

    if ($anomalies | length) > 0 {
        print ""; print $"(ansi green_bold)Recent anomalies(ansi reset)"
        for row in ($anomalies | first 5) {
            print $"  Ply ($row.ply | fill -w 3 -a l) z=($row.z | fill -w 5 -a l) ($row.sev)cp  game ($row.game_id)"
        }
    }
    print ""
}
