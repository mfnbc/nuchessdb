#!/usr/bin/env nu
# validate-gate.nu — Socratic Coach Validate Gate
#
# Anomaly intercept → shutdown downstream → 3-line JSON block.
#
# Checks move_anomalies for unprocessed alerts. If anomalies are found,
# intercepts them, outputs a 3-line JSON summary, and signals shutdown
# (exit code 1). If clean, passes through (exit code 0).
#
# Usage: nu validate-gate.nu <username> <game_id> [--db <path>]

def _db_path [] { "./chess.db" }

def main [username: string, game_id: int, --db: string] {
    let db = if ($db != null) { $db } else { (_db_path) }

    if not ($db | path exists) {
        print ({ gate: "ERROR", status: "no_database", anomalies: 0, shutdown: true } | to json -r)
        exit 1
    }

    # 1. Intercept: check for unprocessed anomalies
    let anomalies = (open $db | query db "
        SELECT alert_id, ply, anomaly_type, concept_name, z_score, severity, state_id
        FROM move_anomalies
        WHERE username = ? AND game_id = ? AND consumed = 0
        ORDER BY severity DESC
    " --params [$username, $game_id])

    # 2. Decision: gate open or closed?
    if ($anomalies | is-empty) {
        # Clean — pass through
        print ({ gate: "OPEN", status: "clean", anomalies: 0, shutdown: false } | to json -r)
        exit 0
    }

    # 3. Anomaly intercept — shutdown downstream
    let top = ($anomalies | first 3)
    let summary = (
        $top | each {|a|
            let z = if ($a.z_score != null) { ($a.z_score | into string --decimals 2) } else { "n/a" }
            let s = if ($a.severity != null) { ($a.severity | into int) } else { 0 }
            $"ply=($a.ply) type=($a.anomaly_type) concept=($a.concept_name) z=($z) severity=($s)cp"
        }
    )

    # 3-line JSON block — three NDJSON lines
    let top_label = ($top | first | each {|a|
        let z = if ($a.z_score != null) { ($a.z_score | into string --decimals 2) } else { "n/a" }
        $"($a.anomaly_type):($a.concept_name) z=($z)"
    } | str join ", ")

    print ({ gate: "SHUT" } | to json -r)
    print ({ anomalies: ($anomalies | length), top: $top_label } | to json -r)
    print ({ shutdown: true } | to json -r)

    # Mark anomalies as consumed (they've been intercepted)
    for a in $anomalies {
        try {
            open $db | query db "
                UPDATE move_anomalies SET consumed = 1 WHERE alert_id = ?
            " --params [$a.alert_id]
        } catch { }
    }

    exit 1
}
