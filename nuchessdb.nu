#!/usr/bin/env nu
# nuchessdb — chess database and coaching platform
#
# Quick start:
#   nu nuchessdb.nu init
#   nu nuchessdb.nu sync <chess.com-username>
#   nu nuchessdb.nu derive-coach <username>
#   nu nuchessdb.nu coach-profile <username>
#
# All commands accept --db <path> to override the default ./chess.db.

# ── Internal helpers ──────────────────────────────────────────────────────────

# Batch INSERT OR IGNORE — pure Nushell, no external tools.
# Chunks rows to stay under SQLite's variable limit (~900 params per statement).
def db-merge [
    db: string
    table: string
    records: list
    columns: list<string>
] {
    if ($records | is-empty) { return }
    let chunk_size = ([1, (900 // ($columns | length))] | math max)
    let col_sql   = ($columns | str join ", ")
    let row_ph    = "(" + (1..($columns | length) | each { "?" } | str join ", ") + ")"
    for chunk in ($records | chunks $chunk_size) {
        let all_ph = ($chunk | each { $row_ph } | str join ", ")
        let params = ($chunk | each { |r| $columns | each { |c| $r | get $c } } | flatten)
        open $db | query db ("INSERT OR IGNORE INTO " + $table + " (" + $col_sql + ") VALUES " + $all_ph) --params $params
    }
}

def win-rate-pivot [] {
    let rows = $in
    $rows | get concept | uniq | each { |c|
        let r = ($rows | where concept == $c)
        let cell = { |who flag|
            let m = ($r | where who == $who | where present == $flag).0?
            { games: ($m.games? | default 0), win_pct: $m.win_pct? }
        }
        {
            concept:                $c
            player_has_pattern:     (do $cell "player"   1)
            player_lacks_pattern:   (do $cell "player"   0)
            opponent_has_pattern:   (do $cell "opponent" 1)
            opponent_lacks_pattern: (do $cell "opponent" 0)
        }
    }
}

# Create all tables and apply any pending column migrations. Safe to re-run.
def init-db [db: string] {
    if not ($db | path exists) {
        [{_init: 1}] | into sqlite $db -t _meta
    }
    open $db | query db "PRAGMA journal_mode = WAL"  | ignore
    open $db | query db "PRAGMA synchronous = NORMAL" | ignore

    open $db | query db "
        CREATE TABLE IF NOT EXISTS games (
            game_id        INTEGER PRIMARY KEY,
            source         TEXT,
            source_game_id TEXT,
            white          TEXT,
            black          TEXT,
            white_elo      INTEGER,
            black_elo      INTEGER,
            result         TEXT,
            played_at      DATETIME,
            time_control   TEXT,
            eco            TEXT,
            opening        TEXT
        )
    " | ignore

    open $db | query db "
        CREATE TABLE IF NOT EXISTS positions (
            zobrist       TEXT PRIMARY KEY,
            fen           TEXT UNIQUE,
            hugm_score    INTEGER,
            hugm_eval_arr TEXT,
            board_pieces  TEXT,
            state_id      INTEGER,
            mate_in_1     INTEGER DEFAULT 0,
            is_checkmate  INTEGER DEFAULT 0,
            updated_at    DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    " | ignore
    for col_sql in [
        "ALTER TABLE positions ADD COLUMN state_id    INTEGER     DEFAULT 0"
        "ALTER TABLE positions ADD COLUMN mate_in_1   INTEGER     DEFAULT 0"
        "ALTER TABLE positions ADD COLUMN is_checkmate INTEGER    DEFAULT 0"
    ] { try { open $db | query db $col_sql } catch { } }

    open $db | query db "
        CREATE TABLE IF NOT EXISTS moves (
            game_id          INTEGER,
            position_id      TEXT,
            next_position_id TEXT,
            ply              INTEGER,
            move_number      INTEGER,
            color            TEXT,
            san              TEXT,
            uci              TEXT,
            PRIMARY KEY (game_id, ply),
            FOREIGN KEY (game_id)          REFERENCES games(game_id),
            FOREIGN KEY (position_id)      REFERENCES positions(zobrist),
            FOREIGN KEY (next_position_id) REFERENCES positions(zobrist)
        )
    " | ignore
    open $db | query db "CREATE INDEX IF NOT EXISTS idx_moves_pos ON moves(position_id)" | ignore

    open $db | query db "
        CREATE TABLE IF NOT EXISTS move_states (
            game_id      INTEGER NOT NULL,
            ply          INTEGER NOT NULL,
            state_id     INTEGER NOT NULL,
            phase_bucket INTEGER NOT NULL,
            has_fork     BOOLEAN NOT NULL DEFAULT 0,
            has_pin      BOOLEAN NOT NULL DEFAULT 0,
            has_hanging  BOOLEAN NOT NULL DEFAULT 0,
            king_exposed BOOLEAN NOT NULL DEFAULT 0,
            PRIMARY KEY (game_id, ply)
        )
    " | ignore

    open $db | query db "
        CREATE TABLE IF NOT EXISTS player_baselines (
            username     TEXT    NOT NULL,
            concept_name TEXT    NOT NULL,
            phase_bucket INTEGER NOT NULL,
            mean         REAL    NOT NULL DEFAULT 0,
            std          REAL    NOT NULL DEFAULT 0,
            count        INTEGER NOT NULL DEFAULT 0,
            last_updated TEXT,
            PRIMARY KEY (username, concept_name, phase_bucket)
        )
    " | ignore
    # Migration: older databases used 'm2' instead of 'std'
    try { open $db | query db "ALTER TABLE player_baselines ADD COLUMN std REAL NOT NULL DEFAULT 0" } catch { }

    open $db | query db "
        CREATE TABLE IF NOT EXISTS transition_events (
            username      TEXT    NOT NULL,
            state_from    INTEGER NOT NULL,
            state_to      INTEGER NOT NULL,
            total_count   INTEGER NOT NULL DEFAULT 0,
            blunder_count INTEGER NOT NULL DEFAULT 0,
            blunder_risk  REAL    NOT NULL DEFAULT 0,
            last_updated  TEXT,
            PRIMARY KEY (username, state_from, state_to)
        )
    " | ignore

    open $db | query db "
        CREATE TABLE IF NOT EXISTS move_anomalies (
            alert_id     INTEGER PRIMARY KEY AUTOINCREMENT,
            username     TEXT    NOT NULL,
            game_id      INTEGER NOT NULL,
            ply          INTEGER NOT NULL,
            state_id     INTEGER NOT NULL,
            anomaly_type TEXT    NOT NULL,
            concept_name TEXT,
            z_score      REAL,
            severity     REAL    NOT NULL DEFAULT 0,
            signed_delta INTEGER,
            hurt_player  BOOLEAN NOT NULL DEFAULT 0,
            created_at   TEXT    DEFAULT (datetime('now')),
            consumed     BOOLEAN NOT NULL DEFAULT 0
        )
    " | ignore
    # Unique constraint makes re-derive idempotent: INSERT OR IGNORE preserves consumed flags
    try {
        open $db | query db "
            CREATE UNIQUE INDEX IF NOT EXISTS idx_anomaly_unique
            ON move_anomalies(username, game_id, ply, concept_name)
        "
    } catch { }
}

# Process a list of game records and merge them into the database.
def import-records [games: list, username: string, db: string] {
    init-db $db
    let corpus = ($games | to json | chessdb process-corpus --username $username)

    if ($corpus.games | is-not-empty) {
        db-merge $db "games" $corpus.games ["game_id" "source" "source_game_id" "white" "black" "white_elo" "black_elo" "result" "played_at" "time_control" "eco" "opening"]
    }
    if ($corpus.positions | is-not-empty) {
        db-merge $db "positions" $corpus.positions ["zobrist" "fen" "hugm_score" "hugm_eval_arr" "board_pieces" "state_id" "mate_in_1" "is_checkmate"]
    }
    if ($corpus.moves | is-not-empty) {
        db-merge $db "moves" $corpus.moves ["game_id" "position_id" "next_position_id" "ply" "move_number" "color" "san" "uci"]
    }

    # Decode state_id bit-field into move_states rows for fast coaching queries
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

# Move-by-move evaluation breakdown for one game. Returns a table.
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

# ── Subcommands ───────────────────────────────────────────────────────────────

# Initialize the database schema (safe to re-run on an existing database).
def "main init" [--db: string = "./chess.db"] {
    init-db $db
    print $"Database ready: ($db)"
}

# Download all chess.com games for a player and store them with HUGM evaluations.
def "main sync" [
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
}

# Show the N most recent games (default 5).
def "main recent" [
    n: int = 5
    --db: string = "./chess.db"
] {
    open $db | query db "
        SELECT game_id, played_at, white, black, result, opening
        FROM games ORDER BY played_at DESC LIMIT ?
    " --params [$n]
}

# Move-by-move evaluation breakdown for a game.
def "main review" [
    game_id: int
    --db: string = "./chess.db"
] {
    review-game $game_id $db
}

# Show how often each move was played from a position (identified by Zobrist hash).
def "main explore" [
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

# Record counts and per-player game totals.
def "main status" [--db: string = "./chess.db"] {
    if not ($db | path exists) { print $"No database at ($db)"; return }

    open $db | query db "
        SELECT (SELECT COUNT(*) FROM games)     as games,
               (SELECT COUNT(*) FROM positions) as positions,
               (SELECT COUNT(*) FROM moves)     as moves
    " | print ($in | table)

    print "\nGames per player:"
    open $db | query db "
        SELECT player, COUNT(*) as games FROM (
            SELECT white as player FROM games
            UNION ALL
            SELECT black as player FROM games
        ) GROUP BY player ORDER BY games DESC
    "
}

# Compute per-player Welford baselines, z-score anomalies, and state transitions.
# Safe to re-run: replaces only this player's derived data.
def "main derive-coach" [
    username: string
    --db: string = "./chess.db"
    --min-games: int = 25
] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }

    let rows = (open $db | query db "
        SELECT m.game_id, m.ply, p.fen, p.hugm_score, p.state_id, m.color,
               CASE WHEN m.color = 'white' THEN g.white ELSE g.black END as player
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        JOIN games g ON m.game_id = g.game_id
        WHERE g.white = ? OR g.black = ?
        ORDER BY m.game_id, m.ply
    " --params [$username, $username])

    if ($rows | is-empty) {
        print $"No moves found for ($username). Run `sync ($username)` first."
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
    open $db | query db "DELETE FROM player_baselines  WHERE username = ?"              --params [$username]
    open $db | query db "DELETE FROM transition_events WHERE username = ?"              --params [$username]
    open $db | query db "DELETE FROM move_anomalies    WHERE username = ? AND consumed = 0" --params [$username]

    # Plugin returns {player, phase_bucket, concept, mean, std} — rename concept→concept_name,
    # drop player, inject username.
    if ($signals.baselines | is-not-empty) {
        db-merge $db "player_baselines" (
            $signals.baselines
            | reject player
            | rename --column {concept: concept_name}
            | insert username $username
        ) ["username" "concept_name" "phase_bucket" "mean" "std"]
    }

    # Plugin returns {player, game_id, ply, state_id, anomaly_type, concept_name,
    #                 z_score, severity, signed_delta, hurt_player}.
    # INSERT OR IGNORE so previously consumed rows survive a re-derive.
    if ($signals.anomalies | is-not-empty) {
        db-merge $db "move_anomalies" (
            $signals.anomalies
            | reject player
            | upsert game_id { into int }
            | upsert signed_delta { into int }
            | insert username $username
        ) ["username" "game_id" "ply" "state_id" "anomaly_type" "concept_name" "z_score" "severity" "signed_delta" "hurt_player"]
    }

    # Plugin returns {state_from, state_to, total_count, blunder_count, blunder_risk}.
    # We add username so queries can be scoped per player.
    if ($signals.transitions | is-not-empty) {
        db-merge $db "transition_events" (
            $signals.transitions | insert username $username
        ) ["username" "state_from" "state_to" "total_count" "blunder_count" "blunder_risk"]
    }

    let nb = ($signals.baselines   | length)
    let na = ($signals.anomalies   | length)
    let nt = ($signals.transitions | length)
    print $"Done: ($nb) baselines, ($na) anomalies, ($nt) transitions."
}

# Show a player's coaching profile: phase performance, concept patterns, worst anomalies.
# Pipe-friendly: returns the profile record. Use --json for LLM-ready output.
def "main coach-profile" [
    username: string
    --db: string = "./chess.db"
    --examples: int = 3   # concept position examples to include
    --json                # output raw JSON instead of a human-readable summary
] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }

    let game_count = (open $db | query db "
        SELECT COUNT(DISTINCT m.game_id) as cnt
        FROM moves m JOIN games g ON m.game_id = g.game_id
        WHERE g.white = ? OR g.black = ?
    " --params [$username, $username]).0.cnt | into int

    # result is stored from the syncing player's perspective (chess.com style):
    # 'win' = player won; draws = agreed/repetition/stalemate/insufficient/timevsinsufficient/50move;
    # everything else (resigned/checkmated/timeout/abandoned) = player lost.
    let wl_by_color = (open $db | query db "
        SELECT color, COUNT(*) as games,
               SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) as wins,
               SUM(CASE WHEN result IN ('agreed','repetition','stalemate','insufficient','timevsinsufficient','50move') THEN 1 ELSE 0 END) as draws,
               SUM(CASE WHEN result NOT IN ('win','agreed','repetition','stalemate','insufficient','timevsinsufficient','50move') THEN 1 ELSE 0 END) as losses,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct,
               ROUND(100.0 * SUM(CASE WHEN result IN ('agreed','repetition','stalemate','insufficient','timevsinsufficient','50move') THEN 1 ELSE 0 END) / COUNT(*), 1) as draw_pct
        FROM (
            SELECT 'white' as color, result FROM games WHERE white = ?
            UNION ALL
            SELECT 'black' as color, result FROM games WHERE black = ?
        ) GROUP BY color
    " --params [$username, $username])

    let phase_baselines = (open $db | query db "
        SELECT m.color,
            CASE WHEN m.ply <= 12 THEN 'opening'
                 WHEN m.ply <= 30 THEN 'midgame'
                 WHEN m.ply <= 50 THEN 'late_mid'
                 ELSE 'endgame' END as phase,
            COUNT(*) as n,
            ROUND(AVG(CASE WHEN m.color='white' THEN p.hugm_score ELSE -p.hugm_score END), 0) as score_from_player,
            ROUND(AVG(ABS(p.hugm_score)), 0) as abs_material
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        JOIN games g ON m.game_id = g.game_id
        WHERE (m.color = 'white' AND g.white = ?) OR (m.color = 'black' AND g.black = ?)
        GROUP BY m.color, phase
        ORDER BY m.color,
            CASE phase WHEN 'opening' THEN 1 WHEN 'midgame' THEN 2 WHEN 'late_mid' THEN 3 ELSE 4 END
    " --params [$username, $username])

    let concept_baselines = (open $db | query db "
        SELECT concept_name, phase_bucket, mean, std
        FROM player_baselines
        WHERE username = ? AND concept_name != 'hugm_delta'
        ORDER BY concept_name, phase_bucket
    " --params [$username])

    let anomaly_count = (open $db | query db "
        SELECT COUNT(*) as cnt FROM move_anomalies WHERE username = ? AND consumed = 0
    " --params [$username]).0.cnt | into int

    let hurt_count = (open $db | query db "
        SELECT COUNT(*) as cnt FROM move_anomalies
        WHERE username = ? AND consumed = 0 AND hurt_player = 1
    " --params [$username]).0.cnt | into int

    let anomalies = (open $db | query db "
        SELECT ma.game_id, ma.ply,
               ROUND(MAX(ma.z_score), 2) as z_score,
               ROUND(MAX(ma.severity), 0) as severity_cp,
               MAX(ma.signed_delta) as signed_delta,
               MAX(ma.hurt_player) as hurt_player,
               MAX(CASE WHEN ms.king_exposed = 1 THEN 1 ELSE 0 END) as king_involved
        FROM move_anomalies ma
        LEFT JOIN move_states ms ON ma.game_id = ms.game_id AND ma.ply = ms.ply
        WHERE ma.username = ? AND ma.consumed = 0
        GROUP BY ma.game_id, ma.ply
        ORDER BY severity_cp DESC LIMIT 5
    " --params [$username])

    let positional = (open $db | query db "
        SELECT m.color,
            CASE WHEN m.ply <= 12 THEN 'opening'
                 WHEN m.ply <= 30 THEN 'midgame'
                 WHEN m.ply <= 50 THEN 'late_mid'
                 ELSE 'endgame' END as phase,
            COUNT(*) as n,
            ROUND(AVG(CAST(json_extract(p.hugm_eval_arr, '\$[1]') AS REAL)), 1) as pawns,
            ROUND(AVG(CAST(json_extract(p.hugm_eval_arr, '\$[2]') AS REAL)), 1) as activity,
            ROUND(AVG(CAST(
                CASE WHEN m.color = 'white' THEN  json_extract(p.hugm_eval_arr, '\$[3]')
                     ELSE                        -json_extract(p.hugm_eval_arr, '\$[3]') END
            AS REAL)), 1) as own_king_safety
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        JOIN games g ON m.game_id = g.game_id
        WHERE (m.color = 'white' AND g.white = ?) OR (m.color = 'black' AND g.black = ?)
        GROUP BY m.color, phase
        ORDER BY m.color, phase
    " --params [$username, $username])

    let mate_analysis = (open $db | query db "
        WITH mate_positions AS (
            SELECT m.color,
                   CASE WHEN m.color='white' THEN g.white ELSE g.black END as player,
                   p.mate_in_1,
                   n.is_checkmate as next_is_checkmate
            FROM moves m
            JOIN positions p ON m.next_position_id = p.zobrist
            LEFT JOIN moves m2 ON m.game_id = m2.game_id AND m.ply + 1 = m2.ply
            LEFT JOIN positions n ON m2.next_position_id = n.zobrist
            JOIN games g ON m.game_id = g.game_id
            WHERE p.mate_in_1 > 0 AND (g.white = ? OR g.black = ?)
        )
        SELECT CASE WHEN player = ? THEN 'player' ELSE 'opponent' END as who,
               COUNT(*) as opportunities,
               SUM(CASE WHEN next_is_checkmate = 1 THEN 1 ELSE 0 END) as found,
               COUNT(*) - SUM(CASE WHEN next_is_checkmate = 1 THEN 1 ELSE 0 END) as missed
        FROM mate_positions
        GROUP BY CASE WHEN player = ? THEN 'player' ELSE 'opponent' END
    " --params [$username, $username, $username, $username])

    # ── Derived values ────────────────────────────────────────────────────────

    let phase_profile = if ($phase_baselines | is-not-empty) {
        $phase_baselines | reduce -f {} { |row, acc|
            let entry = ($acc | get -o $row.phase | default {})
            $acc | upsert $row.phase ($entry | upsert $"as_($row.color)" {
                n:                ($row.n | into int)
                avg_score_cp:     ($row.score_from_player | into int)
                avg_abs_material: ($row.abs_material | into int)
            })
        }
    } else { {} }

    let concepts = if ($concept_baselines | is-not-empty) {
        $concept_baselines
        | group-by concept_name
        | items { |name, rows| {
            concept:      $name
            occurrences:  ($rows | length)
            avg_severity: ($rows | get mean | math avg | math round --precision 0)
        }}
        | sort-by occurrences --reverse
    } else { [] }

    let blunders_per_game = if $game_count > 0 {
        ($hurt_count | into float) / $game_count | math round --precision 2
    } else { 0.0 }

    let concept_examples = if $examples > 0 and ($concepts | length) > 0 {
        $concepts | first 3 | get concept
        | each { |cname| [$cname, (
            open $db | query db "
                SELECT ma.game_id, ma.ply, MAX(ma.z_score) as z_score,
                       MAX(ma.severity) as severity_cp
                FROM move_anomalies ma
                WHERE ma.username = ? AND ma.consumed = 0 AND ma.concept_name = ?
                GROUP BY ma.game_id, ma.ply ORDER BY severity_cp DESC LIMIT ?
            " --params [$username, $cname, $examples]
            | update game_id { into string }
            | update z_score { math round --precision 2 }
        )]}
        | into record
    } else { {} }

    let profile = {
        player:               $username
        games:                $game_count
        results_by_color:     $wl_by_color
        unreviewed_anomalies: $anomaly_count
        blunders_per_game:    $blunders_per_game
        phase_profile:        $phase_profile
        positional_components: $positional
        concepts:             $concepts
        anomalies:            ($anomalies
            | update game_id     { into string }
            | update severity_cp { into int }
            | upsert signed_delta  { default 0 | into int }
            | upsert hurt_player   { default 0 | into bool }
            | upsert king_involved { default 0 | into bool })
        mate_analysis:        $mate_analysis
        concept_examples:     $concept_examples
    }

    if $json {
        print ($profile | to json -r)
    } else {
        print $"── ($username)  |  games: ($game_count)  |  anomalies: ($anomaly_count)  |  blunders/game: ($blunders_per_game) ──"
        if ($wl_by_color | is-not-empty) {
            print "\nResults by color:"
            print ($wl_by_color | table)
        }
        if ($concepts | is-not-empty) {
            print "\nTop concepts:"
            print ($concepts | first 5 | table)
        }
        if ($phase_baselines | is-not-empty) {
            print "\nPhase performance (centipawns from your perspective):"
            print ($phase_baselines | select color phase n score_from_player abs_material | table)
        }
        if ($anomalies | is-not-empty) {
            print "\nWorst unreviewed anomalies:"
            print ($anomalies | table)
        }
        if ($mate_analysis | is-not-empty) {
            print "\nMate-in-1 opportunities:"
            print ($mate_analysis | table)
        }
        $profile
    }
}

# Tactical sub-profile: fork/pin/hanging anomaly breakdown and win-rate correlation.
# Phase trends, win-rates with/without each pattern. Use --json for LLM-ready output.
def "main coach-profile-tactical" [
    username: string
    --db: string = "./chess.db"
    --json            # output raw JSON instead of a human-readable summary
] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }

    let concept_summary = (open $db | query db "
        SELECT concept_name,
               COUNT(*) as anomalies,
               SUM(hurt_player) as hurt_count,
               ROUND(AVG(CAST(hurt_player AS REAL)), 3) as hurt_rate,
               ROUND(AVG(z_score), 2) as avg_z,
               ROUND(MAX(severity), 0) as peak_severity_cp
        FROM move_anomalies
        WHERE username = ? AND concept_name NOT IN ('hugm_delta')
        GROUP BY concept_name
        ORDER BY hurt_count DESC
    " --params [$username])

    let phase_breakdown = (open $db | query db "
        SELECT ms.phase_bucket,
               CASE ms.phase_bucket WHEN 0 THEN 'deep_endgame' WHEN 1 THEN 'endgame'
                                    WHEN 2 THEN 'midgame'      ELSE 'opening' END as phase_label,
               ma.concept_name, COUNT(*) as cnt,
               ROUND(AVG(CAST(ma.hurt_player AS REAL)), 3) as hurt_rate,
               ROUND(AVG(ma.z_score), 2) as avg_z
        FROM move_anomalies ma
        JOIN move_states ms ON ms.game_id = ma.game_id AND ms.ply = ma.ply
        WHERE ma.username = ? AND ma.concept_name NOT IN ('hugm_delta')
        GROUP BY ms.phase_bucket, ma.concept_name
        ORDER BY ms.phase_bucket, hurt_rate DESC
    " --params [$username])

    # Split by whose move produced the flag: player's moves vs opponent's moves.
    # player flags = state_id of positions reached after the player moved.
    # opponent flags = state_id of positions reached after the opponent moved.
    let win_rates_raw = (open $db | query db "
        WITH player_flags AS (
            SELECT ms.game_id,
                   MAX((ms.state_id >> 7) & 1) as had_fork,
                   MAX((ms.state_id >> 8) & 1) as had_pin,
                   MAX((ms.state_id >> 9) & 1) as had_hanging
            FROM move_states ms
            JOIN moves m ON m.game_id = ms.game_id AND m.ply = ms.ply
            JOIN games g ON g.game_id = ms.game_id
            WHERE (g.white = ? AND m.color = 'white') OR (g.black = ? AND m.color = 'black')
            GROUP BY ms.game_id
        ),
        opp_flags AS (
            SELECT ms.game_id,
                   MAX((ms.state_id >> 7) & 1) as had_fork,
                   MAX((ms.state_id >> 8) & 1) as had_pin,
                   MAX((ms.state_id >> 9) & 1) as had_hanging
            FROM move_states ms
            JOIN moves m ON m.game_id = ms.game_id AND m.ply = ms.ply
            JOIN games g ON g.game_id = ms.game_id
            WHERE (g.white = ? AND m.color = 'black') OR (g.black = ? AND m.color = 'white')
            GROUP BY ms.game_id
        ),
        player_games AS (
            SELECT game_id, result FROM games WHERE white = ? OR black = ?
        )
        SELECT concept, who, present, COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct
        FROM (
            SELECT 'fork'          as concept, 'player'   as who, pf.had_fork    as present, pg.result FROM player_flags pf JOIN player_games pg ON pg.game_id = pf.game_id
            UNION ALL
            SELECT 'pin',                       'player',          pf.had_pin,                 pg.result FROM player_flags pf JOIN player_games pg ON pg.game_id = pf.game_id
            UNION ALL
            SELECT 'hanging_piece',             'player',          pf.had_hanging,             pg.result FROM player_flags pf JOIN player_games pg ON pg.game_id = pf.game_id
            UNION ALL
            SELECT 'fork',                      'opponent',        of.had_fork,                pg.result FROM opp_flags of JOIN player_games pg ON pg.game_id = of.game_id
            UNION ALL
            SELECT 'pin',                       'opponent',        of.had_pin,                 pg.result FROM opp_flags of JOIN player_games pg ON pg.game_id = of.game_id
            UNION ALL
            SELECT 'hanging_piece',             'opponent',        of.had_hanging,             pg.result FROM opp_flags of JOIN player_games pg ON pg.game_id = of.game_id
        )
        GROUP BY concept, who, present
        ORDER BY concept, who, present
    " --params [$username, $username, $username, $username, $username, $username])

    let win_rates = ($win_rates_raw | win-rate-pivot)

    let worst_games = (open $db | query db "
        SELECT ma.game_id,
               SUM(CASE WHEN ma.hurt_player = 1 THEN 1 ELSE 0 END) as hurt_moves,
               COUNT(*) as total_anomalies,
               ROUND(MAX(ma.z_score), 2) as peak_z,
               ROUND(MAX(ma.severity), 0) as peak_severity_cp,
               GROUP_CONCAT(DISTINCT ma.concept_name) as concepts
        FROM move_anomalies ma
        WHERE ma.username = ? AND ma.concept_name NOT IN ('hugm_delta') AND ma.consumed = 0
        GROUP BY ma.game_id
        HAVING hurt_moves > 0
        ORDER BY hurt_moves DESC, peak_z DESC LIMIT 5
    " --params [$username])

    let result = {
        player:               $username
        concept_summary:      $concept_summary
        phase_breakdown:      $phase_breakdown
        pattern_win_impact:   $win_rates
        worst_tactical_games: $worst_games
    }

    if $json {
        print ($result | to json -r)
    } else {
        print $"── ($username) — tactical profile ──"
        if ($concept_summary | is-not-empty) {
            print "\nConcept summary:"
            print ($concept_summary | table)
        }
        if ($phase_breakdown | is-not-empty) {
            print "\nPhase breakdown:"
            print ($phase_breakdown | table)
        }
        if ($win_rates | is-not-empty) {
            print "\nPattern win impact:"
            print ($win_rates | table)
        }
        if ($worst_games | is-not-empty) {
            print "\nWorst tactical games:"
            print ($worst_games | table)
        }
        $result
    }
}

# Precision sub-profile: eval-swing baselines, blunder trends, and risky transitions.
# Blunder distribution by phase, top anomalies by z_score. Use --json for LLM-ready output.
def "main coach-profile-precision" [
    username: string
    --db: string = "./chess.db"
    --json            # output raw JSON instead of a human-readable summary
] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }

    let swing_baselines = (open $db | query db "
        SELECT phase_bucket,
               CASE phase_bucket WHEN 0 THEN 'deep_endgame' WHEN 1 THEN 'endgame'
                                 WHEN 2 THEN 'midgame'      ELSE 'opening' END as phase_label,
               mean, std
        FROM player_baselines
        WHERE username = ? AND concept_name = 'hugm_delta'
        ORDER BY phase_bucket
    " --params [$username])

    let severity_dist = (open $db | query db "
        SELECT
            CASE
                WHEN z_score < 3.0 THEN 'borderline (z 2-3)'
                WHEN z_score < 4.0 THEN 'notable (z 3-4)'
                WHEN z_score < 5.0 THEN 'major (z 4-5)'
                ELSE 'extreme (z 5+)'
            END as tier,
            COUNT(*) as cnt,
            ROUND(AVG(CAST(hurt_player AS REAL)), 3) as hurt_rate,
            ROUND(AVG(severity), 0) as avg_severity_cp
        FROM move_anomalies
        WHERE username = ? AND concept_name = 'hugm_delta'
        GROUP BY tier
        ORDER BY MIN(z_score)
    " --params [$username])

    let blunder_by_phase = (open $db | query db "
        SELECT ms.phase_bucket,
               CASE ms.phase_bucket WHEN 0 THEN 'deep_endgame' WHEN 1 THEN 'endgame'
                                    WHEN 2 THEN 'midgame'      ELSE 'opening' END as phase_label,
               COUNT(*) as hurt_moves,
               COUNT(DISTINCT ma.game_id) as games_with_blunder,
               ROUND(AVG(ma.severity), 0) as avg_severity_cp,
               ROUND(MAX(ma.severity), 0) as max_severity_cp
        FROM move_anomalies ma
        JOIN move_states ms ON ms.game_id = ma.game_id AND ms.ply = ma.ply
        WHERE ma.username = ? AND ma.hurt_player = 1 AND ma.severity > 150
        GROUP BY ms.phase_bucket
        ORDER BY ms.phase_bucket
    " --params [$username])

    let risky_transitions = (open $db | query db "
        SELECT state_from, state_to, total_count, blunder_count,
               ROUND(blunder_risk, 3) as blunder_risk
        FROM transition_events
        WHERE username = ? AND blunder_risk > 0.15 AND total_count >= 3
        ORDER BY blunder_risk DESC LIMIT 5
    " --params [$username])

    let top_anomalies = (open $db | query db "
        SELECT game_id, ply, concept_name,
               ROUND(z_score, 2) as z_score,
               ROUND(severity, 0) as severity_cp,
               hurt_player
        FROM move_anomalies
        WHERE username = ? AND consumed = 0
        ORDER BY z_score DESC LIMIT 10
    " --params [$username])

    let result = {
        player:             $username
        swing_baselines:    $swing_baselines
        severity_dist:      $severity_dist
        blunder_by_phase:   $blunder_by_phase
        risky_transitions:  $risky_transitions
        top_anomalies:      $top_anomalies
    }

    if $json {
        print ($result | to json -r)
    } else {
        print $"── ($username) — precision profile ──"
        if ($swing_baselines | is-not-empty) {
            print "\nEval-swing baselines (hugm_delta per phase):"
            print ($swing_baselines | table)
        }
        if ($severity_dist | is-not-empty) {
            print "\nBlunder severity distribution:"
            print ($severity_dist | table)
        }
        if ($blunder_by_phase | is-not-empty) {
            print "\nBlunders by phase:"
            print ($blunder_by_phase | table)
        }
        if ($risky_transitions | is-not-empty) {
            print "\nRisky transitions (blunder_risk > 15%):"
            print ($risky_transitions | table)
        }
        if ($top_anomalies | is-not-empty) {
            print "\nTop anomalies by z_score:"
            print ($top_anomalies | table)
        }
        $result
    }
}

# Positional sub-profile: eval component trends (pawns/activity/king-safety).
# Win-rate when positional patterns are present, positional concept anomalies. Use --json for LLM-ready output.
def "main coach-profile-position" [
    username: string
    --db: string = "./chess.db"
    --json            # output raw JSON instead of a human-readable summary
] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }

    let eval_components = (open $db | query db "
        SELECT m.color,
            CASE WHEN m.ply <= 12 THEN 'opening'
                 WHEN m.ply <= 30 THEN 'midgame'
                 WHEN m.ply <= 50 THEN 'late_mid'
                 ELSE 'endgame' END as phase_label,
            COUNT(*) as n,
            ROUND(AVG(CAST(json_extract(p.hugm_eval_arr, '\$[1]') AS REAL)), 1) as avg_pawns_cp,
            ROUND(AVG(CAST(json_extract(p.hugm_eval_arr, '\$[2]') AS REAL)), 1) as avg_activity_cp,
            ROUND(AVG(CAST(
                CASE WHEN m.color = 'white' THEN  json_extract(p.hugm_eval_arr, '\$[3]')
                     ELSE                        -json_extract(p.hugm_eval_arr, '\$[3]') END
            AS REAL)), 1) as avg_king_safety_cp
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        JOIN games g ON m.game_id = g.game_id
        WHERE (m.color = 'white' AND g.white = ?) OR (m.color = 'black' AND g.black = ?)
        GROUP BY m.color, phase_label
        ORDER BY m.color, phase_label
    " --params [$username, $username])

    let positional_win_rates = (open $db | query db "
        WITH player_games AS (
            SELECT g.game_id, g.result,
                   CASE WHEN g.white = ? THEN 'white' ELSE 'black' END as player_color
            FROM games g WHERE g.white = ? OR g.black = ?
        ),
        game_flags AS (
            SELECT ms.game_id,
                   MAX((ms.state_id >> 10) & 1) as had_outpost,
                   MAX((ms.state_id >> 11) & 1) as had_open_file,
                   MAX((ms.state_id >> 12) & 1) as had_passed_pawn,
                   MAX(CASE WHEN m.color = pg.player_color THEN (ms.state_id >> 5) & 1 ELSE 0 END) as had_king_exposed
            FROM move_states ms
            JOIN moves m ON m.game_id = ms.game_id AND m.ply = ms.ply
            JOIN player_games pg ON pg.game_id = ms.game_id
            GROUP BY ms.game_id
        )
        SELECT concept, present, COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct
        FROM (
            SELECT 'outpost'      as concept, gf.had_outpost      as present, pg.result
              FROM game_flags gf JOIN player_games pg ON pg.game_id = gf.game_id
            UNION ALL
            SELECT 'open_file',              gf.had_open_file,      pg.result
              FROM game_flags gf JOIN player_games pg ON pg.game_id = gf.game_id
            UNION ALL
            SELECT 'passed_pawn',            gf.had_passed_pawn,    pg.result
              FROM game_flags gf JOIN player_games pg ON pg.game_id = gf.game_id
            UNION ALL
            SELECT 'king_exposed',           gf.had_king_exposed,   pg.result
              FROM game_flags gf JOIN player_games pg ON pg.game_id = gf.game_id
        )
        GROUP BY concept, present
        ORDER BY concept, present
    " --params [$username, $username, $username])

    let positional_anomalies = (open $db | query db "
        SELECT concept_name, COUNT(*) as anomalies,
               ROUND(AVG(CAST(hurt_player AS REAL)), 3) as hurt_rate,
               ROUND(AVG(z_score), 2) as avg_z
        FROM move_anomalies
        WHERE username = ?
          AND concept_name IN ('outpost','open_file','passed_pawn','king_exposed',
                               'skewer','discovered_attack')
        GROUP BY concept_name
        ORDER BY anomalies DESC
    " --params [$username])

    let result = {
        player:                $username
        eval_components:       $eval_components
        positional_win_rates:  $positional_win_rates
        positional_anomalies:  $positional_anomalies
    }

    if $json {
        print ($result | to json -r)
    } else {
        print $"── ($username) — positional profile ──"
        if ($eval_components | is-not-empty) {
            print "\nEval components by color and phase (centipawns):"
            print ($eval_components | table)
        }
        if ($positional_win_rates | is-not-empty) {
            print "\nWin rate with/without positional patterns:"
            print ($positional_win_rates | table)
        }
        if ($positional_anomalies | is-not-empty) {
            print "\nPositional concept anomalies:"
            print ($positional_anomalies | table)
        }
        $result
    }
}

# Opening sub-profile: ECO repertoire, family win rates, weakest/strongest openings.
# Which openings correlate with the most anomalies. Use --json for LLM-ready output.
def "main coach-profile-opening" [
    username: string
    --db: string = "./chess.db"
    --min-games: int = 10   # min games per opening to include in weakness/strength lists
    --json                  # output raw JSON instead of a human-readable summary
] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }

    let as_white = (open $db | query db "
        SELECT eco, opening, COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct,
               ROUND(100.0 * SUM(CASE WHEN result IN ('agreed','repetition','stalemate','insufficient','timevsinsufficient','50move') THEN 1 ELSE 0 END) / COUNT(*), 1) as draw_pct
        FROM games WHERE white = ?
        GROUP BY eco
        ORDER BY games DESC LIMIT 15
    " --params [$username])

    let as_black = (open $db | query db "
        SELECT eco, opening, COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct,
               ROUND(100.0 * SUM(CASE WHEN result IN ('agreed','repetition','stalemate','insufficient','timevsinsufficient','50move') THEN 1 ELSE 0 END) / COUNT(*), 1) as draw_pct
        FROM games WHERE black = ?
        GROUP BY eco
        ORDER BY games DESC LIMIT 15
    " --params [$username])

    let eco_families = (open $db | query db "
        SELECT SUBSTR(eco, 1, 1) as eco_family,
               CASE SUBSTR(eco, 1, 1)
                 WHEN 'A' THEN 'flank'     WHEN 'B' THEN 'semi_open'
                 WHEN 'C' THEN 'open'      WHEN 'D' THEN 'closed'
                 WHEN 'E' THEN 'indian'    ELSE 'other' END as family_name,
               COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct
        FROM games WHERE white = ? OR black = ?
        GROUP BY eco_family ORDER BY games DESC
    " --params [$username, $username])

    let weakest = (open $db | query db "
        SELECT eco, opening,
               CASE WHEN white = ? THEN 'white' ELSE 'black' END as color,
               COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct
        FROM games WHERE white = ? OR black = ?
        GROUP BY eco, color HAVING games >= ?
        ORDER BY win_pct ASC LIMIT 8
    " --params [$username, $username, $username, $min_games])

    let strongest = (open $db | query db "
        SELECT eco, opening,
               CASE WHEN white = ? THEN 'white' ELSE 'black' END as color,
               COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct
        FROM games WHERE white = ? OR black = ?
        GROUP BY eco, color HAVING games >= ?
        ORDER BY win_pct DESC LIMIT 8
    " --params [$username, $username, $username, $min_games])

    let anomaly_by_opening = (open $db | query db "
        SELECT g.eco, g.opening,
               COUNT(*) as anomalies,
               COUNT(DISTINCT g.game_id) as games_affected,
               ROUND(AVG(ma.z_score), 2) as avg_z,
               ROUND(AVG(CAST(ma.hurt_player AS REAL)), 3) as hurt_rate
        FROM move_anomalies ma
        JOIN games g ON g.game_id = ma.game_id
        WHERE ma.username = ? AND ma.concept_name = 'hugm_delta'
        GROUP BY g.eco HAVING games_affected >= 3
        ORDER BY hurt_rate DESC LIMIT 10
    " --params [$username])

    let result = {
        player:               $username
        top_as_white:         $as_white
        top_as_black:         $as_black
        eco_families:         $eco_families
        weakest_openings:     $weakest
        strongest_openings:   $strongest
        anomaly_by_opening:   $anomaly_by_opening
    }

    if $json {
        print ($result | to json -r)
    } else {
        print $"── ($username) — opening profile ──"
        if ($as_white | is-not-empty) {
            print "\nTop openings as white:"
            print ($as_white | table)
        }
        if ($as_black | is-not-empty) {
            print "\nTop openings as black:"
            print ($as_black | table)
        }
        if ($eco_families | is-not-empty) {
            print "\nECO family performance:"
            print ($eco_families | table)
        }
        if ($weakest | is-not-empty) {
            print $"\nWeakest openings (>= ($min_games) games):"
            print ($weakest | table)
        }
        if ($strongest | is-not-empty) {
            print $"\nStrongest openings (>= ($min_games) games):"
            print ($strongest | table)
        }
        if ($anomaly_by_opening | is-not-empty) {
            print "\nMost anomalous openings:"
            print ($anomaly_by_opening | table)
        }
        $result
    }
}

# AI Socratic coaching for the key moments in a game.
# Requires nu-agent at ../nu-agent/nu-agent and the chess_coach contract.
def "main coach-review" [
    game_id: int
    --perspective: string = "white"
    --db: string = "./chess.db"
] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }

    let game        = (open $db | query db "SELECT white, black, white_elo, black_elo, result FROM games WHERE game_id = ?" --params [$game_id]).0
    let info        = match $perspective {
        "white" => {name: $game.white, elo: $game.white_elo}
        _       => {name: $game.black, elo: $game.black_elo}
    }
    let player_name = $info.name
    let player_elo  = $info.elo

    let anomalies = (open $db | query db "
        SELECT ply, anomaly_type, concept_name, z_score, severity
        FROM move_anomalies
        WHERE username = ? AND game_id = ? AND consumed = 0
        ORDER BY severity DESC LIMIT 3
    " --params [$player_name, $game_id])

    let plies = if ($anomalies | is-not-empty) {
        $anomalies | get ply | uniq
    } else {
        let moves = (review-game $game_id $db)
        let drops = (
            $moves
            | where color == $perspective
            | insert total_delta { |r|
                ($r.Δ_material + $r.Δ_structure + $r.Δ_activity + $r.Δ_king + $r.Δ_passed + $r.Δ_dev + $r.Δ_space + $r.Δ_strategic)
            }
            | where total_delta < -20
            | sort-by total_delta
            | first 3
        )
        if ($drops | is-empty) { print "Clean game — no significant eval drops found."; return }
        $drops | get ply
    }

    let agent    = "../nu-agent/nu-agent"
    let contract = "../nu-agent/contracts/chess_coach.toml"

    for ply in $plies {
        let fen_rec  = (open $db | query db "
            SELECT p.fen FROM moves m JOIN positions p ON m.position_id = p.zobrist
            WHERE m.game_id = ? AND m.ply = ?
        " --params [$game_id, ($ply | into int)]).0

        let eval     = ($fen_rec.fen | chessdb hugm-eval --verbose true --player-elo $player_elo)
        let report   = $eval.sensor_report
        let concepts = if ($report.gated_issues | is-not-empty) {
            $report.gated_issues | each { |gi| {
                name: $gi.name, severity: $gi.severity, elo_min: $gi.elo_min,
                side: $gi.side, phrase: $gi.phrase, score: $gi.score,
            }}
        } else { [] }

        if ($concepts | is-not-empty) {
            let input = { fen: $fen_rec.fen, player_elo: $player_elo, concepts: $concepts, scores: $report.aggregated }
            let raw   = (nu $agent --prompt ($input | to json -r) --contract $contract | str trim)
            let clean = ($raw | str replace -r '^```(json)?\s*\n?' '' | str replace -r '\n?```\s*$' '')
            print $"\n── Ply ($ply) ──────────────────────────────"
            print (try { $clean | from json } catch { $clean })
        } else {
            print $"\n── Ply ($ply): no ELO-gated concepts detected ──"
        }
    }
}

# Show unreviewed anomalies for a game and mark them as consumed.
def "main validate-gate" [
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
        print "Gate: OPEN — no unreviewed anomalies for this game."
        return
    }

    print $"Gate: SHUT — ($anomalies | length) anomaly(s) in game ($game_id):"
    print ($anomalies | table)

    for id in ($anomalies | get alert_id) {
        open $db | query db "UPDATE move_anomalies SET consumed = 1 WHERE alert_id = ?" --params [$id]
    }
    print "Marked as reviewed."
}

# ── Entry point ───────────────────────────────────────────────────────────────

def main [] {
    print "nuchessdb — chess database and coaching platform\n"
    print "USAGE:  nu nuchessdb.nu <command> [options]"
    print "        All commands accept --db <path>  (default: ./chess.db)\n"
    scope commands
    | where name =~ "^main "
    | sort-by name
    | each { |cmd|
        let short = ($cmd.name | str replace "main " "")
        let first = ($cmd.description | lines).0? | default ""
        let desc  = if ($first | is-empty) { "" } else { $"  ($first)" }
        print $"  ($short | fill -a l -w 35)($desc)"
    }
    | ignore
}
