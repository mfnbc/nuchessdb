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
    let row_ph    = "(" + ($columns | each { "?" } | str join ", ") + ")"
    for chunk in ($records | chunks $chunk_size) {
        let all_ph = ($chunk | each { $row_ph } | str join ", ")
        let params = ($chunk | each { |r| $columns | each { |c| $r | get $c } } | flatten)
        open $db | query db ("INSERT OR IGNORE INTO " + $table + " (" + $col_sql + ") VALUES " + $all_ph) --params $params
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

    $raw | reduce -f {prev_arr: [0 0 0 0 0 0 0 0 0 0 0], rows: []} { |row, acc|
        let arr   = try { $row.hugm_eval_arr | from json } catch { $acc.prev_arr }
        let sign  = if $row.color == "black" { -1 } else { 1 }
        let d     = ($arr | zip $acc.prev_arr | each { |p| ($p.0 - $p.1) * $sign })
        let out = {
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
        {prev_arr: $arr, rows: ($acc.rows | append $out)}
    } | get rows
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
    print $"Fetching ($targets | length) archive(s) for ($username)..."

    let games = (
        $targets | par-each { |url|
            let result = try { (http get $url).games } catch { null }
            if $result != null { $result } else {
                sleep 5sec
                try { (http get $url).games } catch { [] }
            }
        } | flatten
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

    # Delete only this player's stale data — other players are unaffected.
    # Consumed anomalies (already reviewed) are also preserved.
    open $db | query db "DELETE FROM player_baselines  WHERE username = ?"              --params [$username]
    open $db | query db "DELETE FROM transition_events WHERE username = ?"              --params [$username]
    open $db | query db "DELETE FROM move_anomalies    WHERE username = ? AND consumed = 0" --params [$username]

    # Baselines: explicit field mapping avoids fragile positional rename.
    # The plugin returns {player, phase_bucket, concept, mean, std}.
    if ($signals.baselines | is-not-empty) {
        let rows = ($signals.baselines | each { |b| {
            username:     $username
            concept_name: $b.concept
            phase_bucket: $b.phase_bucket
            mean:         $b.mean
            std:          $b.std
            count:        0
        }})
        db-merge $db "player_baselines" $rows ["username" "concept_name" "phase_bucket" "mean" "std" "count"]
    }

    # Anomalies: INSERT OR IGNORE so previously consumed rows survive a re-derive.
    # The plugin returns {player, game_id, ply, state_id, anomaly_type, concept_name,
    #                     z_score, severity, signed_delta, hurt_player}.
    if ($signals.anomalies | is-not-empty) {
        let rows = ($signals.anomalies | each { |a| {
            username:     $username
            game_id:      ($a.game_id | into int)
            ply:          $a.ply
            state_id:     $a.state_id
            anomaly_type: $a.anomaly_type
            concept_name: $a.concept_name
            z_score:      $a.z_score
            severity:     $a.severity
            signed_delta: ($a.signed_delta | into int)
            hurt_player:  $a.hurt_player
        }})
        db-merge $db "move_anomalies" $rows ["username" "game_id" "ply" "state_id" "anomaly_type" "concept_name" "z_score" "severity" "signed_delta" "hurt_player"]
    }

    # Transitions: plugin returns {state_from, state_to, total_count, blunder_count, blunder_risk}.
    # We add username so queries can be scoped per player.
    if ($signals.transitions | is-not-empty) {
        let rows = ($signals.transitions | each { |t| {
            username:      $username
            state_from:    $t.state_from
            state_to:      $t.state_to
            total_count:   $t.total_count
            blunder_count: $t.blunder_count
            blunder_risk:  $t.blunder_risk
        }})
        db-merge $db "transition_events" $rows ["username" "state_from" "state_to" "total_count" "blunder_count" "blunder_risk"]
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
    " --params [$username, $username] | first | get cnt | into int)

    let wl_by_color = (open $db | query db "
        SELECT color, COUNT(*) as games,
               SUM(is_win) as wins, SUM(is_draw) as draws, SUM(is_loss) as losses,
               ROUND(100.0 * SUM(is_win) / COUNT(*), 1) as win_pct,
               ROUND(100.0 * SUM(is_draw) / COUNT(*), 1) as draw_pct
        FROM (
            SELECT 'white' as color,
                   CASE WHEN result = '1-0'     THEN 1 ELSE 0 END as is_win,
                   CASE WHEN result = '1/2-1/2' THEN 1 ELSE 0 END as is_draw,
                   CASE WHEN result = '0-1'     THEN 1 ELSE 0 END as is_loss
            FROM games WHERE white = ?
            UNION ALL
            SELECT 'black' as color,
                   CASE WHEN result = '0-1'     THEN 1 ELSE 0 END,
                   CASE WHEN result = '1/2-1/2' THEN 1 ELSE 0 END,
                   CASE WHEN result = '1-0'     THEN 1 ELSE 0 END
            FROM games WHERE black = ?
        ) GROUP BY color
    " --params [$username, $username])

    let phase_baselines = (open $db | query db "
        SELECT m.color,
            CASE WHEN m.ply <= 12 THEN 'opening'
                 WHEN m.ply <= 30 THEN 'midgame'
                 WHEN m.ply <= 50 THEN 'late_mid'
                 ELSE 'endgame' END as phase,
            COUNT(*) as n,
            AVG(CASE WHEN m.color='white' THEN p.hugm_score ELSE -p.hugm_score END) as score_from_player,
            json_group_array(CASE WHEN m.color='white' THEN p.hugm_score ELSE -p.hugm_score END) as scores_json,
            AVG(ABS(p.hugm_score)) as abs_material
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
    " --params [$username] | first | get cnt | into int)

    let anomaly_split = (open $db | query db "
        SELECT hurt_player, COUNT(*) as cnt
        FROM move_anomalies WHERE username = ? AND consumed = 0
        GROUP BY hurt_player
    " --params [$username])

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

    let positional_raw = (open $db | query db "
        SELECT m.color,
            CASE WHEN m.ply <= 12 THEN 'opening'
                 WHEN m.ply <= 30 THEN 'midgame'
                 WHEN m.ply <= 50 THEN 'late_mid'
                 ELSE 'endgame' END as phase,
            p.hugm_eval_arr
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        JOIN games g ON m.game_id = g.game_id
        WHERE (m.color = 'white' AND g.white = ?) OR (m.color = 'black' AND g.black = ?)
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
            let scores  = try { $row.scores_json | from json | sort } catch { [] }
            let n       = ($row.n | into int)
            let avg     = ($row.score_from_player | into float)
            let median  = if ($scores | length) > 0 {
                let mid = ($scores | length) // 2
                if (($scores | length) mod 2) == 0 {
                    (($scores | get $mid | into float) + ($scores | get ($mid - 1) | into float)) / 2.0
                } else {
                    $scores | get $mid | into float
                }
            } else { 0.0 }
            let std_dev = if $n > 1 {
                (($scores | each { |s| let d = ($s | into float) - $avg; $d * $d } | math sum) / ($n - 1 | into float) | math sqrt)
            } else { 0.0 }
            let entry = ($acc | get -o $row.phase | default {})
            $acc | upsert $row.phase ($entry | upsert $"as_($row.color)" {
                n:                $n
                avg_score_cp:     ($avg     | math round --precision 0)
                median_score_cp:  ($median  | math round --precision 0)
                score_std_dev:    ($std_dev | math round --precision 0)
                avg_abs_material: ($row.abs_material | math round --precision 0)
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

    let positional = (
        $positional_raw | each { |r|
            let arr      = try { $r.hugm_eval_arr | from json } catch { [] }
            let raw_king = if ($arr | length) > 3 { $arr | get 3 | into int } else { 0 }
            {
                color:           $r.color
                phase:           $r.phase
                pawns:           (if ($arr | length) > 1 { $arr | get 1 | into int } else { 0 })
                activity:        (if ($arr | length) > 2 { $arr | get 2 | into int } else { 0 })
                own_king_safety: (if $r.color == "black" { -1 * $raw_king } else { $raw_king })
            }
        }
        | group-by { |r| $"($r.color):($r.phase)" }
        | items { |key, group|
            let n = ($group | length)
            let p = ($key | split row ":")
            {
                color: ($p | get 0), phase: ($p | get 1), n: $n
                pawns:           (($group | get pawns           | math sum) / ($n | into float) | math round --precision 1)
                activity:        (($group | get activity        | math sum) / ($n | into float) | math round --precision 1)
                own_king_safety: (($group | get own_king_safety | math sum) / ($n | into float) | math round --precision 1)
            }
        }
    )

    let hurt_count      = ($anomaly_split | where { |r| $r.hurt_player == 1 } | get cnt | math sum | default 0 | into int)
    let blunders_per_game = if $game_count > 0 {
        ($hurt_count | into float) / ($game_count | into float) | math round --precision 2
    } else { 0.0 }

    let concept_examples = if $examples > 0 and ($concepts | length) > 0 {
        $concepts | first 3 | get concept | reduce -f {} { |cname, acc|
            let ex = (open $db | query db "
                SELECT ma.game_id, ma.ply, MAX(ma.z_score) as z_score,
                       MAX(ma.severity) as severity_cp
                FROM move_anomalies ma
                WHERE ma.username = ? AND ma.consumed = 0 AND ma.concept_name = ?
                GROUP BY ma.game_id, ma.ply ORDER BY severity_cp DESC LIMIT ?
            " --params [$username, $cname, $examples])
            $acc | insert $cname ($ex | each { |p| {
                game_id:     ($p.game_id | into string)
                ply:         $p.ply
                z_score:     ($p.z_score | math round --precision 2)
                severity_cp: $p.severity_cp
            }})
        }
    } else { {} }

    let profile = {
        player:               $username
        games:                $game_count
        results_by_color:     $wl_by_color
        unreviewed_anomalies: $anomaly_count
        blunders_per_game:    $blunders_per_game
        sign_convention:      "avg_score_cp is from the player's perspective: positive = player is ahead."
        phase_profile:        $phase_profile
        positional_components: $positional
        concepts:             $concepts
        anomalies:            ($anomalies | each { |a| {
            game_id:      ($a.game_id | into string)
            ply:          $a.ply
            z_score:      $a.z_score
            severity_cp:  ($a.severity_cp  | into int)
            signed_delta: ($a.signed_delta | default 0 | into int)
            hurt_player:  ($a.hurt_player  | default 0 | into bool)
            king_involved: ($a.king_involved | default 0 | into bool)
        }})
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

# AI Socratic coaching for the key moments in a game.
# Requires nu-agent at ../nu-agent/nu-agent and the chess_coach contract.
def "main coach-review" [
    game_id: int
    --perspective: string = "white"
    --db: string = "./chess.db"
] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }

    let game        = (open $db | query db "SELECT white, black, white_elo, black_elo, result FROM games WHERE game_id = ?" --params [$game_id] | first)
    let player_name = if $perspective == "white" { $game.white } else { $game.black }
    let player_elo  = if $perspective == "white" { $game.white_elo } else { $game.black_elo }

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
        " --params [$game_id, ($ply | into int)] | first)

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
    print "nuchessdb — chess database and coaching platform

USAGE:  nu nuchessdb.nu <command> [options]
        All commands accept --db <path>  (default: ./chess.db)

  init                            Initialize database schema
  sync <username>                 Download all chess.com games for a player
    --limit <n>                     Only fetch the last n monthly archives
  recent [n]                      Last n games (default 5)
  review <game_id>                Move-by-move evaluation breakdown
  explore <zobrist>               Move frequencies for a position
  status                          Record counts and players in the database

  derive-coach <username>         Compute coaching baselines and anomalies
    --min-games <n>                 Min samples before trusting a baseline (default 25)
  coach-profile <username>        Coaching profile: concepts, phase stats, anomalies
    --examples <n>                  Position examples per concept (default 3)
    --json                          Output raw JSON for LLM consumption
  coach-review <game_id>          AI Socratic coaching for key moments
    --perspective white|black       Which side to coach (default white)
  validate-gate <username> <game_id>  Show and consume unreviewed anomalies"
}
