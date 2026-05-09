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
            source_id TEXT PRIMARY KEY,
            platform TEXT,
            white TEXT,
            black TEXT,
            white_elo INTEGER,
            black_elo INTEGER,
            result TEXT,
            played_at DATETIME,
            time_control TEXT,
            eco TEXT,
            opening TEXT,
            raw_json TEXT
        );
    " | ignore

    open $db | query db "
        CREATE TABLE IF NOT EXISTS positions (
            zobrist TEXT PRIMARY KEY,
            fen TEXT UNIQUE,
            critter_score INTEGER,
            nnue_score INTEGER,
            eval_depth INTEGER,
            is_theoretical BOOLEAN DEFAULT 0,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
    " | ignore

    open $db | query db "
        CREATE TABLE IF NOT EXISTS moves (
            game_id TEXT,
            position_id TEXT,
            next_position_id TEXT,
            ply INTEGER,
            move_number INTEGER,
            color TEXT,
            san TEXT,
            uci TEXT,
            clock_seconds INTEGER,
            PRIMARY KEY (game_id, ply),
            FOREIGN KEY(game_id) REFERENCES games(source_id),
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
        | par-each { |url| (http get $url).games } 
        | flatten
    )
    
    import-records $all_games "chesscom"
}

# --- 2. Batch Ingestion Pipeline (ELT) ---
def import-records [games: list, platform: string] {
    init-schema | ignore
    let db = (_db_path)
    let temp_db = "./temp_sync.db"

    print $"[Engine] Processing ($games | length) games in RAM..."
    
        # 1. Rust does all the math in one pass (We will build this Rust command next)
        let corpus = ($games | to json | chessdb process-corpus)
        
        # 2. Nushell pipes the flat arrays into a temporary database instantly
        rm -f $temp_db
        "" | save -f $temp_db
        $corpus.games | into sqlite $temp_db -t temp_games
        $corpus.positions | into sqlite $temp_db -t temp_positions
        $corpus.moves | into sqlite $temp_db -t temp_moves

        # 3. Single Transaction Merge
        print $"[Database] Merging corpus into ($db)..."
        # Nushell handles ATTACH best via a single command block or by dumping to SQL and importing
        open $temp_db | query db "SELECT * FROM temp_games;" | into sqlite $db -t games
        open $temp_db | query db "SELECT * FROM temp_positions;" | into sqlite $db -t positions
        open $temp_db | query db "SELECT * FROM temp_moves;" | into sqlite $db -t moves
        
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
  explore <zobrist> Show move frequencies and ELO performance for a position
  status            Platform health and data counts"
}
