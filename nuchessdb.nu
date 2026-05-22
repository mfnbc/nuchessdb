#!/usr/bin/env nu

# nuchessdb.nu - Nushell entrypoint for the Unified Chess Data Analytics Platform
# This script exposes small helper functions for ingestion, analysis and export.

# --- Configuration & Paths ---
def _db_path [] { "./chess.db" }

# --- 1. Relational Analytics Schema ---
def init-schema [] {
    let db = (_db_path)
    
    # In Nushell, the easiest way to initialize a valid SQLite file is to insert a dummy table
    if not ($db | path exists) {
        [{init: 1}] | into sqlite $db -t _init_db
    }
    
    # Nushell's `query db` only supports single statements per string
    open $db | query db "PRAGMA journal_mode = WAL;" | ignore
    open $db | query db "PRAGMA synchronous = NORMAL;" | ignore

    open $db | query db "
        CREATE TABLE IF NOT EXISTS games (
            game_id INTEGER PRIMARY KEY,
            source TEXT,
            source_game_id TEXT,
            white TEXT,
            black TEXT,
            white_elo INTEGER,
            black_elo INTEGER,
            result TEXT,
            played_at DATETIME,
            time_control TEXT,
            eco TEXT,
            opening TEXT
        );
    " | ignore

    open $db | query db "
        CREATE TABLE IF NOT EXISTS positions (
            zobrist TEXT PRIMARY KEY,
            fen TEXT UNIQUE,
            hugm_score INTEGER,
            hugm_eval_arr TEXT,
            nnue_score INTEGER,
            board_pieces TEXT,
            state_id INTEGER,
            eval_depth INTEGER,
            is_theoretical BOOLEAN DEFAULT 0,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
    " | ignore
    # Add state_id column if table already exists without it (migration)
    try { open $db | query db "ALTER TABLE positions ADD COLUMN state_id INTEGER" } catch { }

    open $db | query db "
        CREATE TABLE IF NOT EXISTS moves (
            game_id INTEGER,
            position_id TEXT,
            next_position_id TEXT,
            ply INTEGER,
            move_number INTEGER,
            color TEXT,
            san TEXT,
            uci TEXT,
            clock_seconds INTEGER,
            PRIMARY KEY (game_id, ply),
            FOREIGN KEY(game_id) REFERENCES games(game_id),
            FOREIGN KEY(position_id) REFERENCES positions(zobrist),
            FOREIGN KEY(next_position_id) REFERENCES positions(zobrist)
        );
    " | ignore

    open $db | query db "CREATE INDEX IF NOT EXISTS idx_moves_pos ON moves(position_id);" | ignore

    # Derived coaching tables (separate from core analytics)
    open $db | query db "
        CREATE TABLE IF NOT EXISTS player_baselines (
            username TEXT NOT NULL,
            concept_name TEXT NOT NULL,
            phase_bucket INTEGER NOT NULL,
            mean REAL NOT NULL DEFAULT 0,
            m2 REAL NOT NULL DEFAULT 0,
            count INTEGER NOT NULL DEFAULT 0,
            last_updated TEXT,
            PRIMARY KEY (username, concept_name, phase_bucket)
        );
    " | ignore

    open $db | query db "
        CREATE TABLE IF NOT EXISTS move_states (
            game_id INTEGER NOT NULL,
            ply INTEGER NOT NULL,
            state_id INTEGER NOT NULL,
            phase_bucket INTEGER NOT NULL,
            has_fork BOOLEAN NOT NULL DEFAULT 0,
            has_pin BOOLEAN NOT NULL DEFAULT 0,
            has_hanging BOOLEAN NOT NULL DEFAULT 0,
            king_exposed BOOLEAN NOT NULL DEFAULT 0,
            PRIMARY KEY (game_id, ply)
        );
    " | ignore

    open $db | query db "
        CREATE TABLE IF NOT EXISTS transition_events (
            username TEXT NOT NULL,
            state_from INTEGER NOT NULL,
            state_to INTEGER NOT NULL,
            total_count INTEGER NOT NULL DEFAULT 0,
            blunder_count INTEGER NOT NULL DEFAULT 0,
            last_updated TEXT,
            PRIMARY KEY (username, state_from, state_to)
        );
    " | ignore

    open $db | query db "
        CREATE TABLE IF NOT EXISTS move_anomalies (
            alert_id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL,
            game_id INTEGER NOT NULL,
            ply INTEGER NOT NULL,
            state_id INTEGER NOT NULL,
            anomaly_type TEXT NOT NULL,
            concept_name TEXT,
            z_score REAL,
            transition_risk REAL,
            severity REAL NOT NULL DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now')),
            consumed BOOLEAN NOT NULL DEFAULT 0
        );
    " | ignore
}

# --- 1b. Simple PGN importer (nu-first) ---
# Stream-decompress a .pgn.zst file and pass the PGN text to the Rust plugin `chessdb pgn-to-batch`.
# Minimal MVP: this streams the entire file to the plugin. Use small --max options or pre-slice for big runs.
def import-pgn-file [path: string] {
    if (which zstd | empty?) { print "zstd required on PATH"; return }

    print ("[Import] streaming PGN from " + $path)

    # Stream-decompress and collect into a single string, then pass to the plugin.
    # Note: for very large archives this will be memory-heavy; for MVP we use small samples.
    let tmp = (/tmp/nuchessdb_import.pgn)
    zstd -dc ($path) | save -f $tmp
    let pgn_text = (open --raw $tmp)

    # Call the plugin that parses PGN into batch records (games, positions, unique_positions)
    let batch = ($pgn_text | chessdb pgn-to-batch)

    # Return the plugin result for downstream nu pipelines
    $batch
}

# --- 2. Ingestion Pipeline ---
# Cleanest path: chess.com JSON -> Streamed SQLite ingestion.
def sync-chesscom [username: string, --limit: int] {
    let url = $"https://api.chess.com/pub/player/($username)/games/archives"
    let archives = (http get $url).archives
    let target_archives = if ($limit == null) { $archives } else { $archives | last $limit }

    let count = ($target_archives | length | into string)
    print $"Downloading ($count) archives..."
    let all_games = (
        $target_archives 
        | par-each { |url| 
            let attempt1 = (try { (http get $url).games } catch { null })
            if ($attempt1 != null) {
                $attempt1
            } else {
                sleep 5sec
                let attempt2 = (try { (http get $url).games } catch { null })
                if ($attempt2 != null) {
                    $attempt2
                } else {
                    sleep 5sec
                    try { (http get $url).games } catch { [] }
                }
            }
        } 
        | flatten
    )
    
    import-records $all_games "chesscom" $username
}

# Lichess per-user sync (fetches NDJSON and collapses into a JSON list for import)
def sync-lichess [username: string, --max: int] {
    let max = if ($max == null) { 2 } else { $max }
    print $"Downloading up to ($max) games for ($username)..."

    # Lichess returns NDJSON; fetch raw text and parse line-by-line into JSON objects
    let lichess_url = $"https://lichess.org/api/games/user/($username)?max=($max)&rated=true&perfType=classical,rapid,blitz,bullet,correspondence"
    let raw = (http get $lichess_url)

    let games = ($raw 
        | lines 
        | where length > 0 
        | each { try { ($it | from json) } catch { "" } } 
        | where { $it != "" }
    )

    import-records $games "lichess" $username
}

# --- 2. Batch Ingestion Pipeline (ELT) ---
def import-records [games: list, platform: string, username: string] {
    init-schema | ignore
    let db = (_db_path)
    let temp_db = "./temp_sync.db"

    let ngames = ($games | length | into string)
    print $"Processing ($ngames) games..."
        
        # 1. Rust does all the math in one pass (We will build this Rust command next)
        # Produce corpus JSON via the Rust plugin; labeling for NNUE training should be done separately
        let corpus = ($games | to json | chessdb process-corpus --username $username)
        
        # 2. Nushell pipes the flat arrays into a temporary database instantly
        rm -f $temp_db
        "" | save -f $temp_db
        
        # Guard against completely empty datasets failing table creation
        if ($corpus.games | is-not-empty) { $corpus.games | into sqlite $temp_db -t temp_games }
        if ($corpus.positions | is-not-empty) { $corpus.positions | into sqlite $temp_db -t temp_positions }
        if ($corpus.moves | is-not-empty) { $corpus.moves | into sqlite $temp_db -t temp_moves }

        # 3. Idempotent Merge (INSERT OR IGNORE via sqlite3)
        print $"Merging into ($db)..."
        
        if ($corpus.games | is-not-empty) {
            let attach = $"ATTACH '($temp_db)' AS src;"
            sqlite3 $db $attach "INSERT OR IGNORE INTO games(game_id,source,source_game_id,white,black,white_elo,black_elo,result,played_at,time_control,eco,opening) SELECT game_id,source,source_game_id,white,black,white_elo,black_elo,result,played_at,time_control,eco,opening FROM src.temp_games; DETACH src;" | ignore
        }
        if ($corpus.positions | is-not-empty) {
            let attach = $"ATTACH '($temp_db)' AS src;"
            sqlite3 $db $attach "INSERT OR IGNORE INTO positions(zobrist,fen,hugm_score,hugm_eval_arr,board_pieces,state_id,mate_in_1,is_checkmate) SELECT zobrist,fen,hugm_score,hugm_eval_arr,board_pieces,state_id,mate_in_1,is_checkmate FROM src.temp_positions; DETACH src;" | ignore
        }
        if ($corpus.moves | is-not-empty) {
            let attach = $"ATTACH '($temp_db)' AS src;"
            sqlite3 $db $attach "INSERT OR IGNORE INTO moves(game_id,position_id,next_position_id,ply,move_number,color,san,uci) SELECT game_id,position_id,next_position_id,ply,move_number,color,san,uci FROM src.temp_moves; DETACH src;" | ignore
        }
        
        rm -f $temp_db
        print "✓ Batch merge complete."

        # 4. Populate move_states from merged data
        if ($corpus.moves | is-not-empty) {
            try {
                open $db | query db "
                    INSERT OR IGNORE INTO move_states (game_id, ply, state_id, phase_bucket, has_fork, has_pin, has_hanging, king_exposed)
                    SELECT m.game_id, m.ply, COALESCE(p.state_id, 0),
                           (COALESCE(p.state_id, 0) & 3),
                           ((COALESCE(p.state_id, 0) >> 7) & 1),
                           ((COALESCE(p.state_id, 0) >> 8) & 1),
                           ((COALESCE(p.state_id, 0) >> 9) & 1),
                           ((COALESCE(p.state_id, 0) >> 5) & 1)
                    FROM moves m
                    JOIN positions p ON m.next_position_id = p.zobrist
                " | ignore
            } catch { }
        }
}

# (analyze-position removed — dead code; use 'nuchessdb.nu review <id>' or 'chessdb hugm-eval' directly)

def report-moves [zobrist: string] {
    let db = (_db_path)
    open $db | query db "
        SELECT m.san, COUNT(*) as frequency, AVG((g.white_elo + g.black_elo) / 2.0) as avg_elo
        FROM moves m
        JOIN games g ON m.game_id = g.game_id
        WHERE m.position_id = ?
        GROUP BY m.san
        ORDER BY frequency DESC
    " --params [$zobrist]
}

def review-game [game_id: int] {
    let db = (_db_path)
    # Join moves to the *next* position to see the evaluation of the board AFTER the move was played
    let raw = (open $db | query db "
        SELECT 
            m.ply, 
            m.move_number, 
            m.color, 
            m.san, 
            -- derive board_pieces from the FEN (strip slashes and digits)
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(substr(p.fen,1,instr(p.fen,' ')-1), '/', ''), '1',''), '2',''), '3',''), '4',''), '5',''), '6',''), '7',''), '8','') as board_pieces,
            p.hugm_score,
            p.hugm_eval_arr
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        WHERE m.game_id = ?
        ORDER BY m.ply ASC
    " --params [$game_id])
    
    # Process array dynamically to calculate deltas and map readable columns
    # Use reduce instead of each to carry state cleanly
    let initial_state = { arr: [0 0 0 0 0 0 0 0 0 0 0], rows: [] }
    
    let processed = ($raw | reduce -f $initial_state { |row, acc|
        let current_arr = ($row.hugm_eval_arr | from json)
        let last_arr = $acc.arr
        
        # In engine evaluations, a positive score is good for White and a negative score is good for Black.
        # To make the deltas intuitive ("a positive delta means the move was good for the player who made it"),
        # we flip the sign of the difference if Black just moved.
        let multiplier = if $row.color == "black" { -1 } else { 1 }
        
        # Calculate deltas for each metric
        let deltas = ($current_arr | zip $last_arr | each { |pair| ($pair.0 - $pair.1) * $multiplier })
        
        # Also map the absolute score to player-relative perspective (so + means winning for the player whose turn it is)
        let relative_score = $row.hugm_score * $multiplier

        let out_row = {
            ply: $row.ply
            move_number: $row.move_number
            move: $row.san
            color: $row.color
            pieces: $row.board_pieces
            score: $relative_score
            Δ_material: $deltas.0
            Δ_structure: $deltas.1
            Δ_activity: $deltas.2
            Δ_king: $deltas.3
            Δ_passed: $deltas.4
            Δ_dev: $deltas.5
            Δ_space: $deltas.6
            Δ_strategic: $deltas.7
        }
        
        { arr: $current_arr, rows: ($acc.rows | append $out_row) }
    })
    
    $processed.rows
}

# --- 3b. Coach Review ---
def coach-review-game [game_id: int, --perspective: string = "white"] {
    let db = (_db_path)

    # 1. Game metadata
    let game = (open $db | query db "
        SELECT white, black, white_elo, black_elo, result
        FROM games WHERE game_id = ?
    " --params [$game_id] | first)

    let player_elo = if $perspective == "white" { $game.white_elo } else { $game.black_elo }
    let player_name = if $perspective == "white" { $game.white } else { $game.black }

    # 2. Check for recorded anomalies first
    let anomalies = (open $db | query db "
        SELECT ply, anomaly_type, concept_name, z_score, severity, signed_delta, hurt_player, state_id
        FROM move_anomalies
        WHERE username = ? AND game_id = ? AND consumed = 0
        ORDER BY severity DESC LIMIT 3
    " --params [$player_name, $game_id])

    # Get unique ply list from anomalies or eval drops
    let plies = if ($anomalies | length) > 0 {
        $anomalies | get ply | uniq
    } else {
        # Fall back to eval drops
        let moves = (review-game $game_id)
        let perspective_moves = ($moves | where color == $perspective)
        let worst = ($perspective_moves
            | insert total_delta {|r| $r.Δ_material + $r.Δ_structure + $r.Δ_activity + $r.Δ_king + $r.Δ_passed + $r.Δ_dev + $r.Δ_space + $r.Δ_strategic }
            | where total_delta < -20
            | sort-by total_delta
            | first 3
        )
        if ($worst | is-empty) {
            print "No significant eval drops or anomalies found — clean game!"
            return
        }
        $worst | get ply
    }

    # 3. For each interesting ply, build structured review
    let reviews = ($plies | each {|ply|
        let ply = ($ply | into int)

        # Get FEN of the position BEFORE the move was played (what the player saw)
        let fen_record = (open $db | query db "
            SELECT p.fen FROM moves m
            JOIN positions p ON m.position_id = p.zobrist
            WHERE m.game_id = ? AND m.ply = ?
        " --params [$game_id, $ply] | first)

        let anomaly_info = ($anomalies | where ply == $ply | first)
        # Include anomaly info for structured output (no text headers)

        # 4. Run full sensor pipeline
        let eval = ($fen_record.fen | chessdb hugm-eval --verbose true --player-elo $player_elo)
        let report = $eval.sensor_report

        # 5. Extract ELO-gated ranked concepts (single source: Rust concepts.rs)
        let concepts = if ($report.gated_issues | is-not-empty) {
            $report.gated_issues | each {|gi| {
                name: $gi.name,
                severity: $gi.severity,
                elo_min: $gi.elo_min,
                side: $gi.side,
                phrase: $gi.phrase,
                score: $gi.score,
            }}
        } else { [] }

        # 6. Format for coach contract
        let coach_input = {
            fen: $fen_record.fen, player_elo: $player_elo,
            concepts: $concepts, scores: $report.aggregated,
            chaos: $report.aggregated.chaos,
        }

        # 7. Call nu-agent CLI
        let agent_path = "../nu-agent/nu-agent"
        let contract_path = "../nu-agent/contracts/chess_coach.toml"
        let coach_raw = if ($concepts | is-not-empty) {
            (nu $agent_path --prompt ($coach_input | to json -r) --contract $contract_path | str trim)
        } else { "" }

        let coach = if ($coach_raw | is-not-empty) {
            let cleaned = ($coach_raw | str replace -r '^```(json)?\s*\n?' '' | str replace -r '\n?```\s*$' '')
            try { $cleaned | from json } catch { $coach_raw }
        } else { null }

        {
            ply: $ply,
            fen: $fen_record.fen,
            anomaly: (if ($anomaly_info | is-not-empty) {
                { type: $anomaly_info.anomaly_type, concept: $anomaly_info.concept_name,
                  z_score: ($anomaly_info.z_score | into float), severity: ($anomaly_info.severity | into int),
                  signed_delta: ($anomaly_info.signed_delta | default 0 | into int),
                  hurt_player: ($anomaly_info.hurt_player | default false | into bool) }
            } else { null }),
            concepts: $concepts,
            coach: $coach,
        }
    })

    let summary = {
        game_id: $game_id, white: $game.white, black: $game.black,
        white_elo: $game.white_elo, black_elo: $game.black_elo,
        perspective: $perspective, player_elo: $player_elo,
        player_name: $player_name, anomaly_count: ($anomalies | length),
        reviews: $reviews,
    }
    print ($summary | to json -r)
}

# --- 4. Main Interface ---
def main [--limit: int, ...args] {
    if ($args | is-empty) { print-help; return }
    let cmd = $args.0
    let rest = if ($args | length) > 1 { $args | skip 1 } else { [] }

    match $cmd {
        "init" => { init-schema }
        "sync" => { 
            if ($rest | is-empty) { print "Provide chess.com username"; return }
            let user = $rest.0
            if ($limit != null) {
                sync-chesscom $user --limit $limit
            } else {
                sync-chesscom $user
            }
        }
        "explore" => {
            if ($rest | is-empty) { print "Provide Zobrist hash of position"; return }
            report-moves $rest.0 | table
        }
        "review" => {
            if ($rest | is-empty) { print "Provide the game_id (integer)"; return }
            let id = ($rest.0 | into int)
            review-game $id | table
        }
        "coach-review" => {
            if ($rest | is-empty) { print "Provide the game_id (integer)"; return }
            let id = ($rest.0 | into int)
            let perspective = if ($rest | length) > 1 { $rest.1 } else { "white" }
            coach-review-game $id --perspective $perspective
        }
        "coach-profile" => {
            if ($rest | is-empty) { print "Provide username"; return }
            nu coach-profile.nu $rest.0 --db ./chess.db
        }
        "recent" => {
            let limit = if ($rest | is-empty) { 5 } else { ($rest.0 | into int) }
            let db = (_db_path)
            open $db | query db "
                SELECT played_at, white, black, result, opening, game_id 
                FROM games 
                ORDER BY played_at DESC 
                LIMIT ?
            " --params [$limit] | table
        }
        "derive-coach" => {
            if ($rest | is-empty) { print "Provide username"; return }
            nu derive-coach.nu $rest.0 --db ./chess.db
        }
        "dictionary-update" => {
            if ($rest | is-empty) { print "Provide username"; return }
            nu dictionary-update.nu $rest.0 --db ./chess.db
        }
        "validate-gate" => {
            if ($rest | is-empty) { print "Provide username and game_id"; return }
            let game_id = ($rest.1 | into int)
            nu validate-gate.nu $rest.0 $game_id --db ./chess.db
        }
        "status" => {
            let db = (_db_path)
            open $db | query db "SELECT (SELECT COUNT(*) FROM games) as g, (SELECT COUNT(*) FROM positions) as p, (SELECT COUNT(*) FROM moves) as m" | table
        }
        _ => { print-help }
    }
}


def print-help [] {
    print "nuchessdb.nu - Professional Chess Analytics Platform

COMMANDS:
  init                     Initialize relational analytics engine
  --limit N                 Process only last N archives (use before subcommand, e.g. --limit 3 sync <user>)
  sync <user>              Stream games from chess.com
  recent [n]               List the n most recent games and their IDs (default 5)
  explore <zobrist>        Show move frequencies and ELO performance for a position
  review <game_id>         Show move-by-move engine evaluations for a specific game
  coach-review <game_id> [perspective]  AI coaching with anomaly detection (default: white)
  coach-profile <username>            Show what concepts you consistently miss
  derive-coach <username>             Compute per-player baselines and anomaly alerts (standalone)
  dictionary-update <username> [--limit N]  Update Tier 1000 blunder sensor Welford states
  validate-gate <username> <game_id>    Anomaly intercept gate (3-line JSON output)
  status                             Platform health and data counts" 
}
