# Schema, migrations, and database management commands.
# Internal exports (db-merge, init-db, fetch-and-seed-eco, enrich-openings) are
# used by sibling module files; they are not re-exported from mod.nu.

# Batch INSERT OR IGNORE. Chunks rows to stay under SQLite's variable limit (~900 params).
export def db-merge [
    db: string
    table: string
    records: list
    columns: list<string>
] {
    if ($records | is-empty) { return }
    let chunk_size = ([1, (900 // ($columns | length))] | math max)
    let col_sql    = ($columns | str join ", ")
    let row_ph     = "(" + (1..($columns | length) | each { "?" } | str join ", ") + ")"
    for chunk in ($records | chunks $chunk_size) {
        let all_ph = ($chunk | each { $row_ph } | str join ", ")
        let params = ($chunk | each { |r| $columns | each { |c| $r | get $c } } | flatten)
        open $db | query db ("INSERT OR IGNORE INTO " + $table + " (" + $col_sql + ") VALUES " + $all_ph) --params $params
    }
}

# Create all tables and apply pending column migrations. Safe to re-run.
export def init-db [db: string] {
    if not ($db | path exists) {
        [{_init: 1}] | into sqlite $db -t _meta
    }
    open $db | query db "PRAGMA journal_mode = WAL"   | ignore
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
        "ALTER TABLE positions ADD COLUMN state_id     INTEGER DEFAULT 0"
        "ALTER TABLE positions ADD COLUMN mate_in_1    INTEGER DEFAULT 0"
        "ALTER TABLE positions ADD COLUMN is_checkmate INTEGER DEFAULT 0"
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
    # Unique constraint makes re-derive idempotent: INSERT OR IGNORE preserves consumed flags.
    try {
        open $db | query db "
            CREATE UNIQUE INDEX IF NOT EXISTS idx_anomaly_unique
            ON move_anomalies(username, game_id, ply, concept_name)
        "
    } catch { }
}

# Download ecoA–E.json from JeffML/eco.json and populate the openings table. No-op if already seeded.
export def fetch-and-seed-eco [db: string] {
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
export def enrich-openings [db: string] {
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

# Initialise the database schema and seed ECO opening data (safe to re-run).
export def "chess-init" [--db: string = "./chess.db"] {
    init-db $db
    fetch-and-seed-eco $db
    enrich-openings $db
    print $"Database ready: ($db)"
}

# Database record counts and per-player game totals.
export def "chess-status" [--db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"No database at ($db)"} }
    {
        counts:  (open $db | query db "
            SELECT (SELECT COUNT(*) FROM games)     as games,
                   (SELECT COUNT(*) FROM positions) as positions,
                   (SELECT COUNT(*) FROM moves)     as moves
        ").0
        players: (open $db | query db "
            SELECT player, COUNT(*) as games FROM (
                SELECT white as player FROM games
                UNION ALL
                SELECT black as player FROM games
            ) GROUP BY player ORDER BY games DESC
        ")
    }
}

# Re-download ECO opening data and re-enrich all games. Use after eco.json updates upstream.
export def "chess-seed-openings" [--db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    open $db | query db "DELETE FROM openings" | ignore
    fetch-and-seed-eco $db
    enrich-openings $db
    print "Opening enrichment complete."
}
