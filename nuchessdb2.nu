#!/usr/bin/env nu

# nuchessdb2.nu - Unified Chess Data Analytics Platform
# A high-performance, compact chess engine/database/analytics tool.

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
            critter_score INTEGER,
            critter_eval_arr TEXT,
            nnue_score INTEGER,
            eval_depth INTEGER,
            is_theoretical BOOLEAN DEFAULT 0,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
    " | ignore

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
}

# --- 2. Ingestion Pipeline ---
# Cleanest path: chess.com JSON -> Streamed SQLite ingestion.
def sync-chesscom [username: string, --limit: int] {
    let archives = (http get $"https://api.chess.com/pub/player/($username)/games/archives").archives
    let target_archives = if ($limit == null) { $archives } else { $archives | last $limit }

    print $"[Sync] Downloading ($target_archives | length) archives into memory..."
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

# --- 2. Batch Ingestion Pipeline (ELT) ---
def import-records [games: list, platform: string, username: string] {
    init-schema | ignore
    let db = (_db_path)
    let temp_db = "./temp_sync.db"

    print $"[Engine] Processing ($games | length) games in RAM..."
    
        # 1. Rust does all the math in one pass (We will build this Rust command next)
        let corpus = ($games | to json | chessdb process-corpus --username $username)
        
        # 2. Nushell pipes the flat arrays into a temporary database instantly
        rm -f $temp_db
        "" | save -f $temp_db
        
        # Guard against completely empty datasets failing table creation
        if ($corpus.games | is-not-empty) { $corpus.games | into sqlite $temp_db -t temp_games }
        if ($corpus.positions | is-not-empty) { $corpus.positions | into sqlite $temp_db -t temp_positions }
        if ($corpus.moves | is-not-empty) { $corpus.moves | into sqlite $temp_db -t temp_moves }

        # 3. Single Transaction Merge
        print $"[Database] Merging corpus into ($db)..."
        
        if ($corpus.games | is-not-empty) {
            open $temp_db | query db "SELECT game_id, source, white, black, white_elo, black_elo, result, played_at, time_control, eco, opening FROM temp_games;" | into sqlite $db -t games
        }
        if ($corpus.positions | is-not-empty) {
            open $temp_db | query db "SELECT zobrist, fen, critter_score, critter_eval_arr, nnue_score FROM temp_positions;" | into sqlite $db -t positions
        }
        if ($corpus.moves | is-not-empty) {
            open $temp_db | query db "SELECT game_id, position_id, next_position_id, ply, move_number, color, san, uci FROM temp_moves;" | into sqlite $db -t moves
        }
        
        rm -f $temp_db
        print "✓ Batch merge complete."
}

# --- 3. Analytics & Intelligence ---
def analyze-position [fen: string, weights_path: string = "./weights.json"] {
    # Calls the resurrected Rust engine modules
    let critter = ($fen | chessdb critter-eval)
    let nnue = ($fen | chessdb nnue-eval --weights $weights_path)
    { critter: $critter, nnue: $nnue }
}

def report-moves [zobrist: string] {
    let db = (_db_path)
    open $db | query db "
        SELECT m.san, COUNT(m.id) as frequency, AVG(g.white_elo + g.black_elo) / 2 as avg_elo
        FROM moves m
        JOIN games g ON m.game_id = g.id
        WHERE m.position_id = (SELECT id FROM positions WHERE zobrist = ?)
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
            p.critter_score,
            p.critter_eval_arr
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        WHERE m.game_id = ?
        ORDER BY m.ply ASC
    " --params [$game_id])
    
    # Process array dynamically to calculate deltas and map readable columns
    mut last_arr = [0 0 0 0 0 0 0 0 0 0 0]
    
    $raw | each { |row|
        let current_arr = ($row.critter_eval_arr | from json)
        
        # Calculate deltas for each metric
        let deltas = ($current_arr | zip $last_arr | each { |pair| $pair.0 - $pair.1 })
        
        # Update state for next row
        $last_arr = $current_arr
        
        {
            ply: $row.ply
            move: $row.san
            color: $row.color
            score: $row.critter_score
            Δ_material: $deltas.0
            Δ_structure: $deltas.1
            Δ_activity: $deltas.2
            Δ_king: $deltas.3
            Δ_passed: $deltas.4
            Δ_dev: $deltas.5
            Δ_space: $deltas.6
            Δ_strategic: $deltas.7
        }
    }
}

# --- 4. Main Interface ---
def main [...args] {
    if ($args | is-empty) { print-help; return }
    let cmd = $args.0
    let rest = if ($args | length) > 1 { $args | skip 1 } else { [] }

    match $cmd {
        "init" => { init-schema }
        "sync" => { sync-chesscom $rest.0 }
        "explore" => {
            if ($rest | is-empty) { print "Provide Zobrist hash of position"; return }
            report-moves $rest.0 | table
        }
        "review" => {
            if ($rest | is-empty) { print "Provide the game_id (integer)"; return }
            let id = ($rest.0 | into int)
            review-game $id | table
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
        "status" => {
            let db = (_db_path)
            open $db | query db "SELECT (SELECT COUNT(*) FROM games) as g, (SELECT COUNT(*) FROM positions) as p, (SELECT COUNT(*) FROM moves) as m" | table
        }
        _ => { print-help }
    }
}


def print-help [] {
    print "nuchessdb2 - Professional Chess Analytics Platform

COMMANDS:
  init              Initialize relational analytics engine
  sync <user>       Stream games from chess.com
  recent [n]        List the n most recent games and their IDs (default 5)
  explore <zobrist> Show move frequencies and ELO performance for a position
  review <game_id>  Show move-by-move engine evaluations for a specific game
  status            Platform health and data counts"
}
