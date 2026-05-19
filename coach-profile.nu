#!/usr/bin/env nu

# coach-profile.nu — COACH phase: player concept profile
#
# Reads player_baselines and move_anomalies to show what a player
# consistently misses — ranked by frequency × severity.
#
# Two layers:
#   1. Phase-level eval swing profile (hugm_delta per phase_bucket)
#   2. Concept-level patterns (fork, pin, hanging_piece, etc.)
#
# Usage: nu coach-profile.nu <username> [--db <path>]

def _db_path [] { "./chess.db" }

def main [username: string, --db: string] {
    let db = if ($db != null) { $db } else { (_db_path) }

    if not ($db | path exists) {
        print $"Database ($db) not found."
        return
    }

    # ── 1. Phase-level eval swing profile ──
    let phase_baselines = (open $db | query db "
        SELECT phase_bucket, mean, m2, count
        FROM player_baselines
        WHERE username = ? AND concept_name = 'hugm_delta'
        ORDER BY phase_bucket
    " --params [$username])

    # ── 2. Concept-level patterns ──
    let concept_baselines = (open $db | query db "
        SELECT concept_name, phase_bucket, mean, m2, count
        FROM player_baselines
        WHERE username = ? AND concept_name != 'hugm_delta'
        ORDER BY concept_name, phase_bucket
    " --params [$username])

    # ── 3. Recent anomaly count ──
    let anomaly_count = (open $db | query db "
        SELECT COUNT(*) as cnt FROM move_anomalies
        WHERE username = ? AND consumed = 0
    " --params [$username] | first | get cnt)

    # ── 4. Game count ──
    let game_count = (open $db | query db "
        SELECT COUNT(DISTINCT m.game_id) as cnt
        FROM moves m
        JOIN games g ON m.game_id = g.game_id
        WHERE g.white = ? OR g.black = ?
    " --params [$username, $username] | first | get cnt)

    print $"(ansi green)╔══════════════════════════════════════╗"
    print $"(ansi green)║  Coach Profile: ($username | fill -w 21 -a l)║"
    print $"(ansi green)╚══════════════════════════════════════╝(ansi reset)"
    print $"  Games in DB: ($game_count)"
    print $"  Unreviewed anomalies: ($anomaly_count)"
    print ""

    # ── Phase summary ──
    if ($phase_baselines | is-not-empty) {
        print $"(ansi green_bold)Eval swing by phase(ansi reset)"
        print ""

        mut total_cost = 0.0
        mut total_count = 0.0

        for row in $phase_baselines {
            let phase_name = match ($row.phase_bucket | into int) {
                0 => "Endgame   "
                1 => "Late mid  "
                2 => "Midgame   "
                _ => "Opening   "
            }
            let sd = if $row.count > 1 {
                let v = ($row.m2 | into float) / (($row.count - 1) | into float)
                if $v > 0.0 { $v | math sqrt | math round --precision 0 } else { 0.0 }
            } else { 0.0 }
            let mean = ($row.mean | math round --precision 0)
            let bar_len = if $mean > 0 { (($mean / 20.0) | into int | if $in > 30 { 30 } else { $in }) } else { 0 }
            let bar = if $bar_len > 0 { (0..$bar_len | each { "█" } | str join) } else { "" }
            print $"  ($phase_name) μ=($mean | fill -w 5 -a l)cp  ($bar)"
            $total_cost = $total_cost + ($row.mean | into float) * ($row.count | into float)
            $total_count = $total_count + ($row.count | into float)
        }

        if $total_count > 0.0 {
            let avg = ($total_cost / $total_count | math round --precision 0)
            print ""
            print $"  Average eval swing: ($avg)cp per move"
        }
    }

    # ── Concept patterns ──
    if ($concept_baselines | is-not-empty) {
        print ""
        print $"(ansi green_bold)Concepts you encounter(ansi reset)"
        print ""

        # Aggregate across phase buckets
        let aggregated = ($concept_baselines
            | group-by concept_name
            | items {|name, rows|
                let total_count = ($rows | get count | math sum)
                let weighted_sum = ($rows | each {|r| ($r.mean | into float) * ($r.count | into float) } | math sum)
                let avg_severity = if $total_count > 0 { ($weighted_sum / ($total_count | into float) | math round --precision 0) } else { 0.0 }
                let total_cost = $avg_severity * ($total_count | into float)
                {
                    concept: $name
                    occurrences: $total_count
                    avg_severity: $avg_severity
                    total_cost: $total_cost
                }
            }
            | sort-by total_cost --reverse
        )

        for row in $aggregated {
            let concept_label = match $row.concept {
                "fork" => "Fork (double attack)     "
                "pin" => "Pin (pinned piece)       "
                "skewer" => "Skewer (x-ray attack)   "
                "discovered_attack" => "Discovered attack      "
                "hanging_piece" => "Hanging piece          "
                "material_imbalance" => "Material imbalance    "
                "king_in_check" => "King in check          "
                _ => $"($row.concept | fill -w 24 -a l)"
            }
            let bar_len = if $row.occurrences > 0 { (($row.occurrences | into int) | if $in > 40 { 40 } else { $in }) } else { 0 }
            let bar = if $bar_len > 0 { (0..$bar_len | each { "░" } | str join) } else { "" }
            let cost_str = if $row.avg_severity > 0 { $"~($row.avg_severity)cp each" } else { "tracking" }
            print $"  ($concept_label) ($row.occurrences | fill -w 4 -a l)×   ($cost_str | fill -w 14 -a l)($bar)"
        }
    } else {
        print ""
        print $"(ansi yellow)No concept-level data yet.(ansi reset)"
        print $"  Run: nu nuchessdb.nu dictionary-update ($username)"
        print $"  This evaluates each of your positions for forks, pins,"
        print $"  hanging pieces, and other tactical patterns."
    }

    # ── Anomaly summary ──
    if $anomaly_count > 0 {
        print ""
        print $"(ansi green_bold)Recent anomalies(ansi reset)"
        let recent = (open $db | query db "
            SELECT game_id, ply, ROUND(MAX(z_score), 2) as z, ROUND(MAX(severity), 0) as sev
            FROM move_anomalies
            WHERE username = ? AND consumed = 0
            GROUP BY game_id, ply
            ORDER BY sev DESC LIMIT 5
        " --params [$username])

        for row in $recent {
            print $"  Ply ($row.ply | fill -w 3 -a l) z=($row.z | fill -w 5 -a l) ($row.sev)cp  game ($row.game_id)"
        }
        let last = ($recent | first)
        print $"  Run: nu nuchessdb.nu coach-review ($last.game_id) white"
    }

    print ""
}
