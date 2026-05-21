#!/usr/bin/env nu

# derive-coach.nu — DERIVE phase: batch per-player baselines, anomalies, transitions
#
# Queries all moves for a player, runs the Rust derive-coach-signals plugin
# (Welford baselines + z-score anomaly detection + state-transition tracking),
# and inserts results into the coaching tables: player_baselines, move_anomalies,
# transition_events.
#
# This is the async DERIVE phase of the INGEST → DERIVE → COACH pipeline.
#
# Usage: nu derive-coach.nu <username> [--db <path>] [--min-games <int>]

def _db_path [] { "./chess.db" }

def main [username: string, --db: string, --min-games: int = 10] {
    let db = if ($db != null) { $db } else { (_db_path) }

    if not ($db | path exists) {
        print --stderr $"Database ($db) not found."
        return
    }

    # Query all moves for this player with FEN, score, and pre-computed state_id
    let rows = (open $db | query db "
        SELECT m.game_id, m.ply, p.fen, p.hugm_score, m.color,
               CASE WHEN m.color = 'white' THEN g.white ELSE g.black END as player
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        JOIN games g ON m.game_id = g.game_id
        WHERE g.white = ? OR g.black = ?
        ORDER BY m.game_id, m.ply
    " --params [$username, $username])

    if ($rows | is-empty) {
        print --stderr $"No moves found for ($username)"
        return
    }

    print --stderr $"Deriving coach signals for ($username) from ($rows | length) moves..."

    # Run the Rust batch plugin: Welford + z-score + state transitions
    let signals = try { ($rows | chessdb derive-coach-signals --min-games $min_games) } catch {|e|
        print --stderr $"Plugin error: ($e.msg)"
        return
    }

    # Insert baselines — explicit INSERT to avoid into sqlite schema mismatch
    let baseline_list = try { $signals.baselines } catch { [] }
    if ($baseline_list | length) > 0 {
        try { open $db | query db "DELETE FROM player_baselines" } catch { }
        for r in ($baseline_list | uniq-by username concept_name phase_bucket) {
            try {
                open $db | query db "
                    INSERT INTO player_baselines (username, concept_name, phase_bucket, mean, m2, count, last_updated)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                " --params [
                    ($r.username | into string),
                    ($r.concept_name | into string),
                    ($r.phase_bucket | into int),
                    ($r.mean | into float),
                    (0.0),
                    1,
                    (date now | format date "%Y-%m-%dT%H:%M:%SZ")
                ] | ignore
            } catch {|e| print --stderr $"Insert baseline failed: ($e.msg)" }
        }
    }

    # Insert anomalies — explicit INSERT for schema stability
    let anomaly_list = try { $signals.anomalies } catch { [] }
    for r in $anomaly_list {
        try {
            open $db | query db "
                INSERT INTO move_anomalies
                    (username, game_id, ply, state_id, anomaly_type, concept_name, z_score, severity, signed_delta, hurt_player, consumed, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            " --params [
                ($r.player | into string),
                ($r.game_id | into int),
                ($r.ply | into int),
                ($r.state_id | into int),
                ($r.anomaly_type | into string),
                ($r.concept_name | into string),
                ($r.z_score | into float),
                ($r.severity | into float),
                ($r.signed_delta | into int),
                ($r.hurt_player | into int),
                false,
                (date now | format date "%Y-%m-%dT%H:%M:%SZ")
            ] | ignore
        } catch {|e| print --stderr $"Insert anomaly failed: ($e.msg)" }
    }

    # Insert transitions with per-player deduplication
    if ($signals.transitions | length) > 0 {
        $signals.transitions
        | insert username { $username }
        | insert last_updated { (date now | format date "%Y-%m-%dT%H:%M:%SZ") }
        | select username state_from state_to total_count blunder_count last_updated
        | uniq-by username state_from state_to
        | into sqlite $db -t transition_events
        | ignore
    }

    print ({ baselines: ($signals.baselines | length), anomalies: ($signals.anomalies | length), transitions: ($signals.transitions | length) } | to json -r)
}
