use ./config.nu *
use ./db.nu *

# Export the game with annotations interleaved as PGN comments.
export def export-annotated-pgn [game_id: int] {
    let cfg = load-config
    let db_path = $cfg.database.path

    let game = (open $db_path | query db $"SELECT raw_pgn FROM games WHERE id = ($game_id)").0.raw_pgn
    let annotations = (open $db_path | query db $"
        SELECT gp.ply, gp.move_san, a.content
        FROM game_positions gp
        JOIN annotations a ON a.game_position_id = gp.id
        WHERE gp.game_id = ($game_id)
        ORDER BY gp.ply ASC
    ")

    if ($annotations | is-empty) {
        return $game
    }

    # Simple PGN injection logic
    # In a real implementation, we would use a PGN parser or more robust regex.
    # For now, we'll return a table of moves + notes as a "TUI PGN".
    $annotations | table
}
