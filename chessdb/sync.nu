# Ingest layer: sync from chess.com, browse games, move-by-move review.

use db.nu [db-merge, init-db, fetch-and-seed-eco, enrich-openings]

# Process a list of game records and merge them into the database.
def import-records [games: list, username: string, db: string] {
    init-db $db
    let corpus = ($games | to json | chessdb process-corpus --username $username)

    if ($corpus.games | is-not-empty) {
        db-merge $db "games" $corpus.games [
            "game_id" "source" "source_game_id" "white" "black"
            "white_elo" "black_elo" "result" "played_at" "time_control" "eco" "opening"
        ]
    }
    if ($corpus.positions | is-not-empty) {
        db-merge $db "positions" $corpus.positions [
            "zobrist" "fen" "hugm_score" "hugm_eval_arr" "board_pieces"
            "state_id" "mate_in_1" "is_checkmate"
        ]
    }
    if ($corpus.moves | is-not-empty) {
        db-merge $db "moves" $corpus.moves [
            "game_id" "position_id" "next_position_id" "ply" "move_number" "color" "san" "uci"
        ]
    }

    # Decode state_id bit-field into move_states rows for fast coaching queries.
    if ($corpus.moves | is-not-empty) {
        try {
            open $db | query db "
                INSERT OR IGNORE INTO move_states
                    (game_id, ply, state_id, phase_bucket, has_fork, has_pin, has_hanging, king_exposed)
                SELECT m.game_id, m.ply,
                    COALESCE(p.state_id, 0),
                    (COALESCE(p.state_id, 0) & 3),
                    ((COALESCE(p.state_id, 0) >> 7) & 1),
                    ((COALESCE(p.state_id, 0) >> 8) & 1),
                    ((COALESCE(p.state_id, 0) >> 9) & 1),
                    ((COALESCE(p.state_id, 0) >> 5) & 1)
                FROM moves m JOIN positions p ON m.next_position_id = p.zobrist
            " | ignore
        } catch { }
    }

    let g = ($corpus.games     | length)
    let p = ($corpus.positions | length)
    let m = ($corpus.moves     | length)
    print $"Imported: ($g) games, ($p) positions, ($m) moves."
}

# Move-by-move evaluation breakdown for one game.
def review-game [game_id: int, db: string] {
    let raw = (open $db | query db "
        SELECT m.ply, m.move_number, m.color, m.san, p.hugm_score, p.hugm_eval_arr
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        WHERE m.game_id = ?
        ORDER BY m.ply ASC
    " --params [$game_id])

    $raw | enumerate | each { |item|
        let row      = $item.item
        let prev_arr = if $item.index == 0 { [0 0 0 0 0 0 0 0 0 0 0] } else {
            try { ($raw | get ($item.index - 1)).hugm_eval_arr | from json } catch { [0 0 0 0 0 0 0 0 0 0 0] }
        }
        let arr  = try { $row.hugm_eval_arr | from json } catch { $prev_arr }
        let sign = match $row.color { "black" => -1, _ => 1 }
        let d    = ($arr | zip $prev_arr | each { |p| ($p.0 - $p.1) * $sign })
        {
            "#":         $row.move_number
            color:       $row.color
            move:        $row.san
            score:       ($row.hugm_score * $sign)
            Δ_material:  ($d | get 0)
            Δ_structure: ($d | get 1)
            Δ_activity:  ($d | get 2)
            Δ_king:      ($d | get 3)
            Δ_passed:    ($d | get 4)
            Δ_dev:       ($d | get 5)
            Δ_space:     ($d | get 6)
            Δ_strategic: ($d | get 7)
        }
    }
}

# Download all chess.com games for a player and store them with HUGM evaluations.
export def "chess-sync" [
    username: string              # chess.com username
    --db: string = "./chess.db"
    --limit: int                  # fetch only the last N monthly archives
] {
    let archives = (http get $"https://api.chess.com/pub/player/($username)/games/archives").archives
    let targets  = if ($limit | is-empty) { $archives } else { $archives | last $limit }
    print $"Fetching ($targets | length) archives for ($username)..."

    let games = (
        $targets | par-each { |url|
            try { (http get $url).games } catch {
                sleep 5sec
                try { (http get $url).games } catch { null }
            }
        } | compact | flatten
    )

    print $"Processing ($games | length) games..."
    import-records $games $username $db
    enrich-openings $db
}

# The N most recent games (default 5).
export def "chess-recent" [
    n: int = 5
    --db: string = "./chess.db"
] {
    open $db | query db "
        SELECT game_id, played_at, white, black, result, opening
        FROM games ORDER BY played_at DESC LIMIT ?
    " --params [$n]
}

# Move-by-move evaluation breakdown for a game.
export def "chess-review" [
    game_id: int
    --db: string = "./chess.db"
] {
    review-game $game_id $db
}

# Move frequencies and average ELO for a position (identified by Zobrist hash).
export def "chess-explore" [
    zobrist: string
    --db: string = "./chess.db"
] {
    open $db | query db "
        SELECT m.san,
               COUNT(*) as times_played,
               ROUND(AVG((g.white_elo + g.black_elo) / 2.0)) as avg_elo
        FROM moves m JOIN games g ON m.game_id = g.game_id
        WHERE m.position_id = ?
        GROUP BY m.san ORDER BY times_played DESC
    " --params [$zobrist]
}
