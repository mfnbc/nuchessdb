#!/usr/bin/env nu
# nuchessdb — chess database and coaching platform
#
# Module usage (structured data, pipe-friendly):
#   use nuchessdb.nu *
#   init
#   sync <chess.com-username>
#   derive-coach <username>
#   coach-profile <username>
#   coach-profile <username> | to json -r
#
# CLI usage (subprocess, rendered output only):
#   nu nuchessdb.nu sync <username>
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
        CREATE TABLE IF NOT EXISTS openings (
            fen   TEXT PRIMARY KEY,
            eco   TEXT NOT NULL,
            name  TEXT NOT NULL,
            moves TEXT
        )
    " | ignore
    open $db | query db "CREATE INDEX IF NOT EXISTS idx_openings_eco ON openings(eco)" | ignore

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

# Download ecoA–E.json from JeffML/eco.json and populate the openings table. No-op if already seeded.
def fetch-and-seed-eco [db: string] {
    let existing = (open $db | query db "SELECT COUNT(*) as cnt FROM openings").0.cnt | into int
    if $existing > 0 { return }
    print "Downloading ECO opening data from JeffML/eco.json..."
    let base = "https://raw.githubusercontent.com/JeffML/eco.json/master"
    let rows = ["ecoA" "ecoB" "ecoC" "ecoD" "ecoE"] | par-each { |f|
        try {
            http get $"($base)/($f).json"
            | items { |fen, data| {
                fen:   $fen
                eco:   ($data.eco?   | default "")
                name:  ($data.name?  | default "")
                moves: ($data.moves? | default "")
            }}
        } catch { [] }
    } | flatten
    if ($rows | is-empty) {
        print "Warning: ECO download failed — opening enrichment disabled."
        return
    }
    db-merge $db "openings" $rows ["fen" "eco" "name" "moves"]
    print $"Seeded ($rows | length) ECO opening positions."
}

# Update games.eco and games.opening to the deepest opening FEN match per game.
def enrich-openings [db: string] {
    let has_data = (open $db | query db "SELECT COUNT(*) as cnt FROM openings").0.cnt | into int
    if $has_data == 0 { return }
    open $db | query db "
        UPDATE games
        SET eco     = best.eco,
            opening = best.name
        FROM (
            SELECT m.game_id, o.eco, o.name
            FROM moves m
            JOIN positions p ON m.next_position_id = p.zobrist
            JOIN openings  o ON p.fen = o.fen
            WHERE m.ply = (
                SELECT MAX(m2.ply)
                FROM moves m2
                JOIN positions p2 ON m2.next_position_id = p2.zobrist
                JOIN openings  o2 ON p2.fen = o2.fen
                WHERE m2.game_id = m.game_id
            )
            GROUP BY m.game_id
        ) best
        WHERE games.game_id = best.game_id
    " | ignore
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

# Initialize the database schema and seed ECO opening data (safe to re-run).
export def "init" [--db: string = "./chess.db"] {
    init-db $db
    fetch-and-seed-eco $db
    enrich-openings $db
    print $"Database ready: ($db)"
}

# Download all chess.com games for a player and store them with HUGM evaluations.
export def "sync" [
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

# Show the N most recent games (default 5).
export def "recent" [
    n: int = 5
    --db: string = "./chess.db"
] {
    open $db | query db "
        SELECT game_id, played_at, white, black, result, opening
        FROM games ORDER BY played_at DESC LIMIT ?
    " --params [$n]
}

# Move-by-move evaluation breakdown for a game.
export def "review" [
    game_id: int
    --db: string = "./chess.db"
] {
    review-game $game_id $db
}

# Show how often each move was played from a position (identified by Zobrist hash).
export def "explore" [
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
export def "status" [--db: string = "./chess.db"] {
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

# Re-download ECO opening data and re-enrich all games. Use after eco.json updates upstream.
export def "seed-openings" [--db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "DELETE FROM openings" | ignore
    fetch-and-seed-eco $db
    enrich-openings $db
    print "Opening enrichment complete."
}

# Compute per-player Welford baselines, z-score anomalies, and state transitions.
# Safe to re-run: replaces only this player's derived data.
export def "derive-coach" [
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

# ── Profile KPIs ──────────────────────────────────────────────────────────────

# Win/loss/draw counts and rates by color.
# result is stored from the syncing player's perspective (chess.com style).
export def "profile-wdl" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
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
    " --params [$username, $username]
}

# Average eval score and material by color and phase (player-relative cp).
export def "profile-phase-stats" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
        SELECT m.color,
            CASE WHEN m.ply <= 12 THEN 'opening'
                 WHEN m.ply <= 30 THEN 'midgame'
                 WHEN m.ply <= 50 THEN 'late_mid'
                 ELSE 'endgame' END as phase,
            COUNT(*) as n,
            ROUND(AVG(CASE WHEN m.color='white' THEN p.hugm_score ELSE -p.hugm_score END), 0) as avg_score_cp,
            ROUND(AVG(ABS(p.hugm_score)), 0) as avg_abs_material
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        JOIN games g ON m.game_id = g.game_id
        WHERE (m.color = 'white' AND g.white = ?) OR (m.color = 'black' AND g.black = ?)
        GROUP BY m.color, phase
        ORDER BY m.color,
            CASE phase WHEN 'opening' THEN 1 WHEN 'midgame' THEN 2 WHEN 'late_mid' THEN 3 ELSE 4 END
    " --params [$username, $username]
}

# Concept baseline summary: occurrence count and average mean severity per concept.
export def "profile-concepts" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    let baselines = (open $db | query db "
        SELECT concept_name, phase_bucket, mean, std
        FROM player_baselines
        WHERE username = ? AND concept_name != 'hugm_delta'
        ORDER BY concept_name, phase_bucket
    " --params [$username])
    if ($baselines | is-empty) { return [] }
    $baselines
    | group-by concept_name
    | items { |name, rows| {
        concept:      $name
        occurrences:  ($rows | length)
        avg_severity: ($rows | get mean | math avg | math round --precision 0)
    }}
    | sort-by occurrences --reverse
}

# Top unreviewed (game, ply) moments by severity, with king-exposure flag.
export def "profile-worst-moments" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
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
        ORDER BY severity_cp DESC
    " --params [$username]
    | update game_id     { into string }
    | update severity_cp { into int }
    | upsert signed_delta  { default 0 | into int }
    | upsert hurt_player   { default 0 | into bool }
    | upsert king_involved { default 0 | into bool }
}

# Mate-in-1 conversion rate for player and opponent.
export def "profile-mate-analysis" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
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
    " --params [$username, $username, $username, $username]
}

# All anomaly examples grouped by concept, ordered by severity. Filter/limit in the pipeline.
export def "concept-examples" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
        SELECT ma.concept_name as concept, ma.game_id, ma.ply,
               ROUND(MAX(ma.z_score), 2) as z_score,
               ROUND(MAX(ma.severity), 0) as severity_cp
        FROM move_anomalies ma
        WHERE ma.username = ? AND ma.consumed = 0
          AND ma.concept_name != 'hugm_delta'
        GROUP BY ma.concept_name, ma.game_id, ma.ply
        ORDER BY ma.concept_name, severity_cp DESC
    " --params [$username]
    | update game_id { into string }
    | update z_score { math round --precision 2 }
}

# Show a player's coaching profile. Pipe to `to json -r` for LLM consumption.
export def "coach-profile" [
    username: string
    --db: string = "./chess.db"
    --hurt-threshold: int = 1000  # min severity to count as a blunder (scale ~135-4500, avg 1500)
] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }

    let game_count = (open $db | query db "
        SELECT COUNT(DISTINCT m.game_id) as cnt
        FROM moves m JOIN games g ON m.game_id = g.game_id
        WHERE g.white = ? OR g.black = ?
    " --params [$username, $username]).0.cnt | into int

    let hurt_count = (open $db | query db "
        SELECT COUNT(*) as cnt FROM move_anomalies
        WHERE username = ? AND consumed = 0 AND hurt_player = 1
    " --params [$username]).0.cnt | into int

    let blunder_count = (open $db | query db "
        SELECT COUNT(*) as cnt FROM move_anomalies
        WHERE username = ? AND consumed = 0 AND hurt_player = 1 AND severity >= ?
    " --params [$username, $hurt_threshold]).0.cnt | into int

    let anomaly_count = (open $db | query db "
        SELECT COUNT(*) as cnt FROM move_anomalies WHERE username = ? AND consumed = 0
    " --params [$username]).0.cnt | into int

    {
        player:                   $username
        games:                    $game_count
        unreviewed_anomalies:     $anomaly_count
        hurt_anomalies_per_game:  (if $game_count > 0 { ($hurt_count | into float) / $game_count | math round --precision 2 } else { 0.0 })
        blunders_per_game:        (if $game_count > 0 { ($blunder_count | into float) / $game_count | math round --precision 2 } else { 0.0 })
        hurt_threshold:           $hurt_threshold
        "profile-wdl":              (profile-wdl              $username --db $db)
        "profile-phase-stats":      (profile-phase-stats      $username --db $db)
        "position-eval-components": (position-eval-components $username --db $db)
        "profile-concepts":         (profile-concepts         $username --db $db)
        "profile-worst-moments":    (profile-worst-moments    $username --db $db | first 5)
        "profile-mate-analysis":    (profile-mate-analysis    $username --db $db)
        "concept-examples":         (concept-examples $username --db $db | sort-by z_score --reverse | first 10)
    }
}

# ── Tactical KPIs ─────────────────────────────────────────────────────────────

# Anomaly counts, hurt rates, and peak severity for each tactical concept.
export def "tactical-concepts" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
        SELECT concept_name,
               COUNT(*) as anomalies,
               SUM(hurt_player) as hurt_count,
               ROUND(AVG(CAST(hurt_player AS REAL)), 3) as hurt_rate,
               ROUND(AVG(z_score), 2) as avg_z,
               ROUND(MAX(severity), 0) as peak_severity_cp
        FROM move_anomalies
        WHERE username = ? AND concept_name IN ('fork', 'pin', 'hanging_piece', 'skewer', 'discovered_attack')
        GROUP BY concept_name
        ORDER BY hurt_count DESC
    " --params [$username]
}

# Tactical anomalies broken down by game phase.
export def "tactical-phase-breakdown" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
        SELECT ms.phase_bucket,
               CASE ms.phase_bucket WHEN 0 THEN 'deep_endgame' WHEN 1 THEN 'endgame'
                                    WHEN 2 THEN 'midgame'      ELSE 'opening' END as phase_label,
               ma.concept_name, COUNT(*) as cnt,
               ROUND(AVG(CAST(ma.hurt_player AS REAL)), 3) as hurt_rate,
               ROUND(AVG(ma.z_score), 2) as avg_z
        FROM move_anomalies ma
        JOIN move_states ms ON ms.game_id = ma.game_id AND ms.ply = ma.ply
        WHERE ma.username = ? AND ma.concept_name IN ('fork', 'pin', 'hanging_piece', 'skewer', 'discovered_attack')
        GROUP BY ms.phase_bucket, ma.concept_name
        ORDER BY ms.phase_bucket, hurt_rate DESC
    " --params [$username]
}

# Win rate with/without each tactical pattern for player and opponent.
# player flags = state_id of positions reached after the player moved.
# opponent flags = state_id of positions reached after the opponent moved.
export def "tactical-win-impact" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
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
    " --params [$username, $username, $username, $username, $username, $username]
    | win-rate-pivot
}

# Games with the most tactical hurt moves, ordered by severity.
export def "tactical-worst-games" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
        SELECT ma.game_id,
               SUM(CASE WHEN ma.hurt_player = 1 THEN 1 ELSE 0 END) as hurt_moves,
               COUNT(*) as total_anomalies,
               ROUND(MAX(ma.z_score), 2) as peak_z,
               ROUND(MAX(ma.severity), 0) as peak_severity_cp,
               GROUP_CONCAT(DISTINCT ma.concept_name) as concepts
        FROM move_anomalies ma
        WHERE ma.username = ? AND ma.concept_name IN ('fork', 'pin', 'hanging_piece', 'skewer', 'discovered_attack') AND ma.consumed = 0
        GROUP BY ma.game_id
        HAVING hurt_moves > 0
        ORDER BY hurt_moves DESC, peak_z DESC
    " --params [$username]
}

# Tactical report: all tactical KPIs bundled. Pipe to `to json -r` for LLM consumption.
export def "coach-profile-tactical" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    {
        player:                      $username
        "tactical-concepts":         (tactical-concepts        $username --db $db)
        "tactical-phase-breakdown":  (tactical-phase-breakdown $username --db $db)
        "tactical-win-impact":       (tactical-win-impact      $username --db $db)
        "tactical-worst-games":      (tactical-worst-games     $username --db $db)
    }
}

# ── Precision KPIs ─────────────────────────────────────────────────────────────

# Eval-swing baselines (mean and std of hugm_delta) per phase.
export def "precision-baselines" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
        SELECT phase_bucket,
               CASE phase_bucket WHEN 0 THEN 'deep_endgame' WHEN 1 THEN 'endgame'
                                 WHEN 2 THEN 'midgame'      ELSE 'opening' END as phase_label,
               mean, std
        FROM player_baselines
        WHERE username = ? AND concept_name = 'hugm_delta'
        ORDER BY phase_bucket
    " --params [$username]
}

# Distribution of anomaly severity tiers (borderline / notable / major / extreme).
export def "precision-severity" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
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
    " --params [$username]
}

# Blunder count, game count, and severity stats per game phase (severity > 150cp).
export def "precision-blunder-phases" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
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
    " --params [$username]
}

# State transitions with blunder risk above 15% and at least 3 occurrences.
export def "precision-risky-transitions" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
        SELECT state_from, state_to, total_count, blunder_count,
               ROUND(blunder_risk, 3) as blunder_risk
        FROM transition_events
        WHERE username = ? AND blunder_risk > 0.15 AND total_count >= 3
        ORDER BY blunder_risk DESC
    " --params [$username]
}

# Top unreviewed anomalies ordered by z_score.
export def "precision-top-anomalies" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
        SELECT game_id, ply, concept_name,
               ROUND(z_score, 2) as z_score,
               ROUND(severity, 0) as severity_cp,
               hurt_player
        FROM move_anomalies
        WHERE username = ? AND consumed = 0
        ORDER BY z_score DESC
    " --params [$username]
}

# Precision report: all precision KPIs bundled. Pipe to `to json -r` for LLM consumption.
export def "coach-profile-precision" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    {
        player:                        $username
        "precision-baselines":         (precision-baselines         $username --db $db)
        "precision-severity":          (precision-severity          $username --db $db)
        "precision-blunder-phases":    (precision-blunder-phases    $username --db $db)
        "precision-risky-transitions": (precision-risky-transitions $username --db $db)
        "precision-top-anomalies":     (precision-top-anomalies     $username --db $db)
    }
}

# ── Positional KPIs ────────────────────────────────────────────────────────────

# Average eval components (pawns, activity, king safety) by color and phase.
export def "position-eval-components" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
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
    " --params [$username, $username]
}

# Win rate when outpost / open-file / passed-pawn / king-exposed patterns are present vs absent.
export def "position-win-rates" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
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
    " --params [$username, $username, $username]
}

# Anomaly counts and hurt rates for positional concepts (outpost, open file, passed pawn, king exposed).
export def "position-anomalies" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
        SELECT concept_name, COUNT(*) as anomalies,
               ROUND(AVG(CAST(hurt_player AS REAL)), 3) as hurt_rate,
               ROUND(AVG(z_score), 2) as avg_z
        FROM move_anomalies
        WHERE username = ?
          AND concept_name IN ('outpost', 'open_file', 'passed_pawn', 'king_exposed')
        GROUP BY concept_name
        ORDER BY anomalies DESC
    " --params [$username]
}

# Positional report: all positional KPIs bundled. Pipe to `to json -r` for LLM consumption.
export def "coach-profile-position" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    {
        player:                      $username
        "position-eval-components":  (position-eval-components $username --db $db)
        "position-win-rates":        (position-win-rates       $username --db $db)
        "position-anomalies":        (position-anomalies       $username --db $db)
    }
}

# ── Opening KPIs ───────────────────────────────────────────────────────────────

# All openings played by color, ordered by games played.
export def "opening-repertoire" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
        SELECT CASE WHEN white = ? THEN 'white' ELSE 'black' END as color,
               eco, opening, COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct,
               ROUND(100.0 * SUM(CASE WHEN result IN ('agreed','repetition','stalemate','insufficient','timevsinsufficient','50move') THEN 1 ELSE 0 END) / COUNT(*), 1) as draw_pct
        FROM games WHERE white = ? OR black = ?
        GROUP BY eco, color
        ORDER BY games DESC
    " --params [$username, $username, $username]
}

# Win rate by ECO family (A=flank, B=semi-open, C=open, D=closed, E=Indian).
export def "opening-eco-families" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
        SELECT SUBSTR(eco, 1, 1) as eco_family,
               CASE SUBSTR(eco, 1, 1)
                 WHEN 'A' THEN 'flank'     WHEN 'B' THEN 'semi_open'
                 WHEN 'C' THEN 'open'      WHEN 'D' THEN 'closed'
                 WHEN 'E' THEN 'indian'    ELSE 'other' END as family_name,
               COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct
        FROM games WHERE white = ? OR black = ?
        GROUP BY eco_family ORDER BY games DESC
    " --params [$username, $username]
}

# Openings with the lowest win rate, filtered by minimum game count.
export def "opening-weakest" [
    username: string
    --db: string = "./chess.db"
    --min-games: int = 10
] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
        SELECT eco, opening,
               CASE WHEN white = ? THEN 'white' ELSE 'black' END as color,
               COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct
        FROM games WHERE white = ? OR black = ?
        GROUP BY eco, color HAVING games >= ?
        ORDER BY win_pct ASC
    " --params [$username, $username, $username, $min_games]
}

# Openings with the highest win rate, filtered by minimum game count.
export def "opening-strongest" [
    username: string
    --db: string = "./chess.db"
    --min-games: int = 10
] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
        SELECT eco, opening,
               CASE WHEN white = ? THEN 'white' ELSE 'black' END as color,
               COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct
        FROM games WHERE white = ? OR black = ?
        GROUP BY eco, color HAVING games >= ?
        ORDER BY win_pct DESC
    " --params [$username, $username, $username, $min_games]
}

# Openings where eval-swing anomalies cluster most, ordered by hurt rate.
export def "opening-anomalies" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "
        SELECT g.eco, g.opening,
               COUNT(*) as anomalies,
               COUNT(DISTINCT g.game_id) as games_affected,
               ROUND(AVG(ma.z_score), 2) as avg_z,
               ROUND(AVG(CAST(ma.hurt_player AS REAL)), 3) as hurt_rate
        FROM move_anomalies ma
        JOIN games g ON g.game_id = ma.game_id
        WHERE ma.username = ? AND ma.concept_name = 'hugm_delta'
        GROUP BY g.eco HAVING games_affected >= 3
        ORDER BY hurt_rate DESC
    " --params [$username]
}

# Opening report: all opening KPIs bundled. Pipe to `to json -r` for LLM consumption.
export def "coach-profile-opening" [
    username: string
    --db: string = "./chess.db"
    --min-games: int = 10
] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    {
        player:               $username
        "opening-repertoire":   (opening-repertoire   $username --db $db)
        "opening-eco-families": (opening-eco-families $username --db $db)
        "opening-weakest":      (opening-weakest      $username --db $db --min-games $min_games)
        "opening-strongest":    (opening-strongest    $username --db $db --min-games $min_games)
        "opening-anomalies":    (opening-anomalies    $username --db $db)
    }
}

# AI Socratic coaching for the key moments in a game.
# Requires nu-agent at ../nu-agent/nu-agent and the chess_coach contract.
export def "coach-review" [
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
export def "validate-gate" [
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
