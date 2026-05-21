#!/usr/bin/env nu
# derive-coach.nu — DERIVE phase: batch per-player coaching computations
#
# Queries moves from SQLite, pipes to Rust plugin (derive-coach-signals),
# inserts results into coaching tables using idiomatic into sqlite.
#
# Usage: nu derive-coach.nu <username> [--db <path>] [--min-games int]

def _db_path [] { "./chess.db" }

def main [username: string, --db: string, --min-games: int = 3] {
    let db = if ($db != null) { $db } else { (_db_path) }

    if not ($db | path exists) {
        print --stderr $"Database ($db) not found."
        return
    }

    let min_games = $min_games

    # Query all moves for this player
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

    # Run the Rust batch plugin
    let signals = try { ($rows | chessdb derive-coach-signals --min-games $min_games) } catch {|e|
        print --stderr $"Plugin error: ($e.msg)"
        return
    }

    # Drop stale coaching tables so into sqlite recreates with correct schema
    try { open $db | query db "DROP TABLE IF EXISTS player_baselines" } catch { }
    try { open $db | query db "DROP TABLE IF EXISTS move_anomalies" } catch { }
    try { open $db | query db "DROP TABLE IF EXISTS transition_events" } catch { }

    # Insert baselines
    if ($signals.baselines | length) > 0 {
        $signals.baselines
        | rename username phase_bucket concept_name mean std
        | into sqlite $db -t player_baselines
        | ignore
    }

    # Insert anomalies
    if ($signals.anomalies | length) > 0 {
        $signals.anomalies
        | rename username game_id ply state_id anomaly_type concept_name z_score severity signed_delta hurt_player
        | into sqlite $db -t move_anomalies
        | ignore
    }

    # Insert transitions
    if ($signals.transitions | length) > 0 {
        $signals.transitions
        | rename state_from state_to total_count blunder_count
        | into sqlite $db -t transition_events
        | ignore
    }

    # Ensure columns that into sqlite doesn't create (consumed by downstream queries)
    try { open $db | query db "ALTER TABLE player_baselines ADD COLUMN last_updated TEXT" } catch { }
    try { open $db | query db "ALTER TABLE move_anomalies ADD COLUMN consumed INTEGER DEFAULT 0" } catch { }
    try { open $db | query db "ALTER TABLE move_anomalies ADD COLUMN created_at TEXT" } catch { }
    try { open $db | query db "ALTER TABLE transition_events ADD COLUMN username TEXT" } catch { }

    print ({ baselines: ($signals.baselines | length), anomalies: ($signals.anomalies | length), transitions: ($signals.transitions | length) } | to json -r)
}
