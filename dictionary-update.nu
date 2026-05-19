#!/usr/bin/env nu
# dictionary-update.nu — Code Dictionary Update loop
#
# Incrementally updates Welford states (mean, m2, count) for Tier 1000
# blunder sensors: fork, pin, skewer, discovered_attack, hanging_piece.
# Reads existing baselines from player_baselines, evaluates new positions
# via HUGM, merges Welford states, and writes updated states back.
#
# Usage: nu dictionary-update.nu <username> [--db <path>] [--limit <int>]

def _db_path [] { "./chess.db" }

# Tier 1000 blunder sensor concept names (Survival + Threat tiers)
const TIER_1000_CONCEPTS = ["fork", "fork_capitalized", "fork_victimized", "pin", "skewer", "discovered_attack", "hanging_piece", "material_imbalance", "king_in_check"]

def main [username: string, --db: string, --limit: int = 100] {
    let db = if ($db != null) { $db } else { (_db_path) }

    if not ($db | path exists) {
        print "Database not found."
        return
    }

    # 1. Load existing Welford states for this player (Tier 1000 concepts only)
    let existing = (open $db | query db "
        SELECT concept_name, phase_bucket, mean, m2, count
        FROM player_baselines
        WHERE username = ? AND concept_name IN ('fork','fork_capitalized','fork_victimized','pin','skewer','discovered_attack','hanging_piece','material_imbalance','king_in_check')
    " --params [$username])

    let existing_map = if ($existing | is-empty) {
        {}
    } else {
        $existing | reduce -f {} {|row, acc|
            let key = $"($row.concept_name):($row.phase_bucket)"
            $acc | insert $key { mean: ($row.mean | into float), m2: ($row.m2 | into float), count: ($row.count | into int) }
        }
    }

    print $"Loaded ($existing | length) existing Welford baselines for ($username)"

    # 2. Find new positions not yet evaluated for this player
    #    We track which positions have been processed via a simple marker table
    open $db | query db "
        CREATE TABLE IF NOT EXISTS dict_update_marker (
            username TEXT NOT NULL,
            game_id INTEGER NOT NULL,
            ply INTEGER NOT NULL,
            PRIMARY KEY (username, game_id, ply)
        );
    " | ignore

    let new_moves = (open $db | query db "
        SELECT m.game_id, m.ply, p.fen,
               CASE WHEN m.color = 'white' THEN g.white ELSE g.black END as player,
               m.color as player_color,
               n.uci as next_uci, n.san as next_san, n.color as next_color,
               nn.san as next2_san
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        JOIN games g ON m.game_id = g.game_id
        LEFT JOIN moves n ON m.game_id = n.game_id AND m.ply + 1 = n.ply
        LEFT JOIN moves nn ON m.game_id = nn.game_id AND m.ply + 2 = nn.ply
        WHERE (g.white = ? OR g.black = ?)
          AND NOT EXISTS (
              SELECT 1 FROM dict_update_marker dum
              WHERE dum.username = ? AND dum.game_id = m.game_id AND dum.ply = m.ply
          )
        ORDER BY m.game_id, m.ply
        LIMIT ?
    " --params [$username, $username, $username, $limit])

    if ($new_moves | is-empty) {
        print "No new positions to process."
        return
    }

    print $"Processing ($new_moves | length) new positions..."

    # 3. For each position, run HUGM and extract Tier 1000 concept deltas
    let deltas = (
        $new_moves
        | each {|row|
            let eval = try {
                $row.fen | chessdb hugm-eval
            } catch { null }
            if ($eval == null) { return [] }

            let report = $eval.sensor_report
            let phase = if ($eval.phase != null) { $eval.phase } else { 20 }
            let phase_bucket = (
                if $phase <= 8 { 0 }
                else if $phase <= 16 { 1 }
                else if $phase <= 24 { 2 }
                else { 3 }
            )

            # Extract next-move destination from UCI (e2e4 → e4)
            let next_dest = if ($row.next_uci | is-not-empty) {
                ($row.next_uci | str substring 2..4)
            } else { "" }

            mut concepts = []

            # Forks — from ThreatGraph with SEE consequence
            for f in ($report.evaluated_forks | default []) {
                $concepts = ($concepts | append { name: "fork", severity: 240 })
                if ($f.hangs | is-not-empty) and ($next_dest | is-not-empty) {
                    if $next_dest == $f.hangs.square {
                        if $row.next_color == $f.attacker.color {
                            $concepts = ($concepts | append { name: "fork_capitalized", severity: 240 })
                        } else {
                            $concepts = ($concepts | append { name: "fork_victimized", severity: 240 })
                        }
                    }
                }
            }

            for p in $report.tactical.pins {
                $concepts = ($concepts | append { name: "pin", severity: 160 })
            }
            for s in $report.tactical.skewers {
                $concepts = ($concepts | append { name: "skewer", severity: 150 })
            }
            for d in $report.tactical.discovered {
                $concepts = ($concepts | append { name: "discovered_attack", severity: 180 })
            }
            for h in $report.tactical.hanging {
                $concepts = ($concepts | append { name: "hanging_piece", severity: 200 })
            }

            $concepts | each {|c| {
                concept_name: $c.name,
                phase_bucket: $phase_bucket,
                severity: $c.severity,
                game_id: $row.game_id,
                ply: $row.ply,
            }}
        }
        | flatten
    )

    if ($deltas | is-empty) {
        print "No Tier 1000 concepts detected in new positions."
        # Still mark positions as processed
        mark-processed $db $username $new_moves
        return
    }

    # 4. Aggregate deltas per concept per phase_bucket
    let aggregates = (
        $deltas
        | group-by {|d| $"($d.concept_name):($d.phase_bucket)"}
        | items {|key, group|
            let values = ($group | get severity)
            let n = ($values | length)
            let sum = ($values | math sum)
            let mean = ($sum / ($n | into float))
            let m2 = ($values | each {|v| ($v - $mean) * ($v - $mean)} | math sum)
            {
                key: $key,
                n: $n,
                mean: $mean,
                m2: $m2,
            }
        }
    )

    # 5. Merge with existing Welford states
    let merged = (
        $aggregates | each {|agg|
            let existing_state = ($existing_map | get -o $agg.key)
            if ($existing_state != null) {
                # Parallel Welford merge
                let ca = ($existing_state.count | into float)
                let cb = ($agg.n | into float)
                let count = ($ca + $cb | into float)
                let delta = ($agg.mean - $existing_state.mean)
                let mean = ($existing_state.mean + $delta * $cb / $count)
                let m2 = ($existing_state.m2 + $agg.m2 + $delta * $delta * $ca * $cb / $count)
                {
                    key: $agg.key,
                    mean: $mean,
                    m2: $m2,
                    count: ($count | into int),
                }
            } else {
                {
                    key: $agg.key,
                    mean: $agg.mean,
                    m2: $agg.m2,
                    count: $agg.n,
                }
            }
        }
    )

    # 6. Write updated Welford states back to DB
    if ($merged | length) > 0 {
        let now = (date now | format date "%Y-%m-%dT%H:%M:%SZ")
        let rows = ($merged | each {|m|
            let parts = ($m.key | split row ":")
            {
                username: $username,
                concept_name: $parts.0,
                phase_bucket: ($parts.1 | into int),
                mean: $m.mean,
                m2: $m.m2,
                count: $m.count,
                last_updated: $now,
            }
        })

        # Replace existing rows by deleting and re-inserting
        for row in $rows {
            try {
                open $db | query db "
                    DELETE FROM player_baselines
                    WHERE username = ? AND concept_name = ? AND phase_bucket = ?
                " --params [$row.username, $row.concept_name, $row.phase_bucket]
            } catch { }
        }

        $rows | into sqlite $db -t player_baselines | ignore
        print $"Updated ($rows | length) Welford baselines for ($username)"
    }

    # 7. Mark positions as processed
    mark-processed $db $username $new_moves

    print "Dictionary update complete."
}

def mark-processed [db: string, username: string, moves: list] {
    let markers = ($moves | each {|m| {
        username: $username,
        game_id: $m.game_id,
        ply: $m.ply,
    }} | uniq)
    if ($markers | length) > 0 {
        $markers | into sqlite $db -t dict_update_marker | ignore
    }
}
