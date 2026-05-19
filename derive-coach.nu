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
        print $"Database ($db) not found."
        return
    }

    # Query all moves for this player with FEN, score, and pre-computed state_id
    let rows = (open $db | query db "
        SELECT m.game_id, m.ply, p.fen, p.hugm_score, p.state_id,
               CASE WHEN m.color = 'white' THEN g.white ELSE g.black END as player
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        JOIN games g ON m.game_id = g.game_id
        WHERE g.white = ? OR g.black = ?
        ORDER BY m.game_id, m.ply
    " --params [$username, $username])

    if ($rows | is-empty) {
        print $"No moves found for ($username)"
        return
    }

    print $"Deriving coach signals for ($username) from ($rows | length) moves..."

    # Run the Rust batch plugin: Welford + z-score + state transitions
    let signals = ($rows | chessdb derive-coach-signals --min-games $min_games)

    # Insert baselines — Welford states (mean, m2, count) per concept per phase
    if ($signals.baselines | length) > 0 {
        $signals.baselines
        | rename username phase_bucket concept_name mean std
        | insert m2 {|r| $r.std * $r.std}
        | insert count { 1 }
        | insert last_updated { (date now | format date "%Y-%m-%dT%H:%M:%SZ") }
        | select username concept_name phase_bucket mean m2 count last_updated
        | uniq-by username concept_name phase_bucket
        | into sqlite $db -t player_baselines
        | ignore
    }

    # Insert anomalies
    if ($signals.anomalies | length) > 0 {
        $signals.anomalies
        | rename username game_id ply state_id anomaly_type concept_name z_score severity
        | insert consumed { false }
        | insert created_at { (date now | format date "%Y-%m-%dT%H:%M:%SZ") }
        | select username game_id ply state_id anomaly_type concept_name z_score severity created_at consumed
        | into sqlite $db -t move_anomalies
        | ignore
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

    print $"Derived: ($signals.baselines | length) baselines, ($signals.anomalies | length) anomalies, ($signals.transitions | length) transitions"
}
