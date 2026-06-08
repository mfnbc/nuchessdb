# Derive layer: compute coaching signals and validate anomaly gates.

use db.nu [db-merge]

# Compute per-player Welford baselines, z-score anomalies, and state transitions.
# Safe to re-run: replaces only this player's derived data.
export def "chess-derive" [
    username: string
    --db: string = "./chess.db"
    --min-games: int = 25
] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }

    let rows = (open $db | query db "
        SELECT m.game_id, m.ply, p.fen, p.hugm_score, p.hugm_eval_arr, p.state_id, m.color,
               CASE WHEN m.color = 'white' THEN g.white ELSE g.black END as player
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        JOIN games g ON m.game_id = g.game_id
        WHERE g.white = ? OR g.black = ?
        ORDER BY m.game_id, m.ply
    " --params [$username, $username])

    if ($rows | is-empty) {
        print $"No moves found for ($username). Run `chess-sync ($username)` first."
        return
    }

    print $"Computing coaching signals for ($username) across ($rows | length) moves..."
    let signals = try {
        $rows | chessdb derive-coach-signals --min-games $min_games
    } catch { |e|
        error make {msg: $"Plugin error: ($e.msg)"}
    }

    if ([$signals.baselines, $signals.anomalies, $signals.transitions] | all { is-empty }) {
        print "Plugin derived no signals — nothing to store."
        return
    }

    # Delete only this player's stale data — other players are unaffected.
    # Consumed anomalies (already reviewed) are also preserved.
    open $db | query db "DELETE FROM player_baselines  WHERE username = ?"                  --params [$username]
    open $db | query db "DELETE FROM transition_events WHERE username = ?"                  --params [$username]
    open $db | query db "DELETE FROM move_anomalies    WHERE username = ? AND consumed = 0" --params [$username]

    if ($signals.baselines | is-not-empty) {
        db-merge $db "player_baselines" (
            $signals.baselines
            | where player == $username
            | reject player
            | rename --column {concept: concept_name}
            | insert username $username
        ) ["username" "concept_name" "phase_bucket" "mean" "std"]
    }

    if ($signals.anomalies | is-not-empty) {
        db-merge $db "move_anomalies" (
            $signals.anomalies
            | where player == $username
            | reject player
            | upsert game_id      { into int }
            | upsert signed_delta { into int }
            | insert username $username
        ) ["username" "game_id" "ply" "state_id" "anomaly_type" "concept_name" "z_score" "severity" "signed_delta" "hurt_player"]
    }

    if ($signals.transitions | is-not-empty) {
        db-merge $db "transition_events" (
            $signals.transitions | insert username $username
        ) ["username" "state_from" "state_to" "total_count" "blunder_count" "blunder_risk"]
    }

    let nb = ($signals.baselines   | length)
    let na = ($signals.anomalies   | length)
    let nt = ($signals.transitions | length)
    print $"Done: ($nb) baselines, ($na) anomalies, ($nt) transitions."
    {baselines: $nb, anomalies: $na, transitions: $nt}
}

# List unreviewed anomalies for a game and mark them consumed. Returns {status, game_id, anomalies}.
export def "chess-validate" [
    username: string
    game_id: int
    --db: string = "./chess.db"
] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }

    let anomalies = (open $db | query db "
        SELECT alert_id, ply, anomaly_type, concept_name, z_score, severity
        FROM move_anomalies
        WHERE username = ? AND game_id = ? AND consumed = 0
        ORDER BY severity DESC
    " --params [$username, $game_id])

    if ($anomalies | is-empty) {
        return {status: "open", game_id: $game_id, anomalies: []}
    }

    for id in ($anomalies | get alert_id) {
        open $db | query db "UPDATE move_anomalies SET consumed = 1 WHERE alert_id = ?" --params [$id]
    }

    {status: "shut", game_id: $game_id, anomalies: ($anomalies | reject alert_id)}
}
