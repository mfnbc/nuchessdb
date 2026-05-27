#!/usr/bin/env nu
# dictionary-update.nu — incremental Tier-1000 concept tracking
#
# Runs HUGM evaluation on positions not yet processed for a player, extracts
# tactical concepts (forks, pins, hanging pieces, etc.) and updates the
# per-player Welford baselines in player_baselines using a parallel merge.
#
# This complements derive-coach (which does a full batch recompute) by
# handling incremental updates from new positions without re-scanning everything.
#
# Usage: nu dictionary-update.nu <username> [--db <path>] [--limit <n>]

const TIER_1000_CONCEPTS = [
    "collapse" "collapse_accuracy" "collapse_miss_cp"
    "pin" "skewer" "discovered_attack" "hanging_piece"
    "material_imbalance" "king_in_check"
]

def _db_path [] { "./chess.db" }

def main [
    username: string
    --db: string
    --limit: int = 100
] {
    let db = if ($db | is-empty) { (_db_path) } else { $db }

    if not ($db | path exists) {
        error make {msg: $"Database not found: ($db)"}
    }

    # Load existing Welford state for this player's Tier-1000 concepts.
    # We store (mean, std, count) and reconstruct M2 = std^2 * (count - 1) for merging.
    let concept_in_clause = ($TIER_1000_CONCEPTS | each { |c| $"'($c)'" } | str join ", ")
    let existing = (open $db | query db $"
        SELECT concept_name, phase_bucket, mean, std, count
        FROM player_baselines
        WHERE username = ? AND concept_name IN \(($concept_in_clause)\)
    " --params [$username])

    let existing_map = if ($existing | is-empty) { {} } else {
        $existing | reduce -f {} { |row, acc|
            let key = $"($row.concept_name):($row.phase_bucket)"
            let n   = ($row.count | into float)
            # Reconstruct M2 from stored std: M2 = variance * (n-1) = std^2 * (n-1)
            let m2  = if $n > 1 { ($row.std | into float) * ($row.std | into float) * ($n - 1) } else { 0.0 }
            $acc | insert $key { mean: ($row.mean | into float), m2: $m2, count: $n }
        }
    }

    print $"Loaded ($existing | length) existing baselines for ($username)."

    # Track which positions have already been processed to avoid double-counting.
    open $db | query db "
        CREATE TABLE IF NOT EXISTS dict_update_marker (
            username TEXT    NOT NULL,
            game_id  INTEGER NOT NULL,
            ply      INTEGER NOT NULL,
            PRIMARY KEY (username, game_id, ply)
        )
    " | ignore

    let new_moves = (open $db | query db "
        SELECT m.game_id, m.ply, p.fen, m.color,
               n.uci   as next_uci,
               nn.uci  as next2_uci,
               nnn.uci as next3_uci
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        JOIN games g ON m.game_id = g.game_id
        LEFT JOIN moves n   ON m.game_id = n.game_id   AND m.ply + 1 = n.ply
        LEFT JOIN moves nn  ON m.game_id = nn.game_id  AND m.ply + 2 = nn.ply
        LEFT JOIN moves nnn ON m.game_id = nnn.game_id AND m.ply + 3 = nnn.ply
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

    # Extract Tier-1000 concept observations from each position.
    let deltas = (
        $new_moves | each { |row|
            let eval = try { $row.fen | chessdb hugm-eval } catch { null }
            if $eval == null { return [] }

            let report      = $eval.sensor_report
            let phase       = ($eval.phase? | default 20)
            let phase_bucket = if $phase <= 8 { 0 } else if $phase <= 16 { 1 } else if $phase <= 24 { 2 } else { 3 }

            let dest  = { |uci| if ($uci | is-empty) { "" } else { $uci | str substring 2..4 } }
            let next  = (do $dest $row.next_uci)
            let next2 = (do $dest $row.next2_uci)
            let next3 = (do $dest $row.next3_uci)

            mut observations = []

            # Forks: track whether the player initiated and completed the exchange chain
            for f in ($report.evaluated_forks | default []) {
                $observations = ($observations | append {name: "fork", severity: 240})

                if ($f.hangs | is-not-empty) and ($f.chain | length) > 0 {
                    let see_cp     = ($f.see_cp | into float)
                    let chain      = $f.chain
                    let init_sq    = ($chain | first).square
                    let initiated  = ($next | is-not-empty) and $next == $init_sq
                    let step_count = ($chain | length) - 1
                    let actual     = [$next, $next2, $next3]

                    mut steps_done = 0
                    for i in 1..($chain | length) {
                        let sq = (($chain | get $i) | get square)
                        if ($actual | get ($i - 1) | is-not-empty) and ($actual | get ($i - 1)) == $sq {
                            $steps_done += 1
                        } else { break }
                    }

                    if $see_cp > 0.0 {
                        # Winning exchange: optimal is to enter and complete it
                        if $initiated {
                            let acc = (($steps_done | into float) / ($step_count | into float) * 100.0 | math round --precision 0 | into int)
                            $observations = ($observations | append {name: "collapse_accuracy",  severity: $acc})
                            if $steps_done < $step_count {
                                $observations = ($observations | append {name: "collapse_miss_cp", severity: ($see_cp | math round --precision 0 | into int)})
                            }
                        } else {
                            $observations = ($observations | append {name: "collapse_miss_cp", severity: ($see_cp | math round --precision 0 | into int)})
                        }
                    } else if $see_cp < 0.0 {
                        # Losing exchange: optimal is to avoid it
                        if $initiated {
                            $observations = ($observations | append {name: "collapse_accuracy",  severity: 0})
                            $observations = ($observations | append {name: "collapse_miss_cp",   severity: ($see_cp | math abs | math round --precision 0 | into int)})
                        } else {
                            $observations = ($observations | append {name: "collapse_accuracy", severity: 100})
                        }
                    }
                }
            }

            $observations = ($observations | append ($report.tactical.pins       | each { {name: "pin",               severity: 160} }))
            $observations = ($observations | append ($report.tactical.skewers    | each { {name: "skewer",            severity: 150} }))
            $observations = ($observations | append ($report.tactical.discovered | each { {name: "discovered_attack", severity: 180} }))
            $observations = ($observations | append ($report.tactical.hanging    | each { {name: "hanging_piece",     severity: 200} }))

            $observations | each { |c| {
                concept_name: $c.name
                phase_bucket: $phase_bucket
                severity:     $c.severity
                game_id:      $row.game_id
                ply:          $row.ply
            }}
        } | flatten
    )

    # Mark positions as processed regardless of whether we found any concepts
    let markers = ($new_moves | each { |m| {username: $username, game_id: $m.game_id, ply: $m.ply} })
    if ($markers | is-not-empty) {
        $markers | into sqlite $db -t dict_update_marker | ignore
    }

    if ($deltas | is-empty) {
        print "No Tier-1000 concepts detected in new positions."
        return
    }

    # Aggregate new observations per (concept, phase_bucket)
    let new_stats = (
        $deltas
        | group-by { |d| $"($d.concept_name):($d.phase_bucket)" }
        | items { |key, group|
            let vals = ($group | get severity)
            let n    = ($vals | length | into float)
            let mean = ($vals | math avg)
            let m2   = ($vals | each { |v| let d = ($v - $mean); $d * $d } | math sum)
            {key: $key, n: $n, mean: $mean, m2: $m2}
        }
    )

    # Merge new stats with existing Welford state (parallel Welford merge formula)
    let merged = ($new_stats | each { |new|
        let old = ($existing_map | get -o $new.key)
        if $old != null {
            let na    = $old.count
            let nb    = $new.n
            let total = $na + $nb
            let delta = $new.mean - $old.mean
            let mean  = $old.mean + $delta * $nb / $total
            let m2    = $old.m2 + $new.m2 + $delta * $delta * $na * $nb / $total
            {key: $new.key, mean: $mean, m2: $m2, count: ($total | into int)}
        } else {
            {key: $new.key, mean: $new.mean, m2: $new.m2, count: ($new.n | into int)}
        }
    })

    # Write updated baselines back, converting M2 → std for storage
    if ($merged | is-not-empty) {
        let now  = (date now | format date "%Y-%m-%dT%H:%M:%SZ")
        let rows = ($merged | each { |m|
            let parts = ($m.key | split row ":")
            let n     = ($m.count | into float)
            let std   = if $n > 1 { ($m.m2 / ($n - 1) | math sqrt) } else { 0.0 }
            {
                username:     $username
                concept_name: ($parts | get 0)
                phase_bucket: ($parts | get 1 | into int)
                mean:         $m.mean
                std:          $std
                count:        $m.count
                last_updated: $now
            }
        })

        # Upsert: delete existing rows for this player+concept+phase, then re-insert
        for row in $rows {
            try {
                open $db | query db "
                    DELETE FROM player_baselines
                    WHERE username = ? AND concept_name = ? AND phase_bucket = ?
                " --params [$row.username, $row.concept_name, $row.phase_bucket]
            } catch { }
        }
        $rows | into sqlite $db -t player_baselines | ignore
        print $"Updated ($rows | length) baselines for ($username)."
    }

    print "Dictionary update complete."
}
