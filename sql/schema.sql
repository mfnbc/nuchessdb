PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS accounts (
  id INTEGER PRIMARY KEY,
  platform TEXT NOT NULL,
  username TEXT NOT NULL,
  is_me INTEGER NOT NULL DEFAULT 0,
  UNIQUE(platform, username)
);

CREATE TABLE IF NOT EXISTS games (
  id INTEGER PRIMARY KEY,
  platform TEXT NOT NULL,
  source_game_id TEXT NOT NULL,
  white_account_id INTEGER,
  black_account_id INTEGER,
  result TEXT NOT NULL,
  time_control TEXT,
  played_at TEXT,
  white_elo INTEGER,
  black_elo INTEGER,
  raw_pgn TEXT NOT NULL,
  imported_at TEXT,
  -- Compact game representation: list of position IDs (JSON or blob)
  -- This allows reconstructing the game path without massive joins or row duplication.
  path_json TEXT, 
  UNIQUE(platform, source_game_id),
  FOREIGN KEY (white_account_id) REFERENCES accounts(id),
  FOREIGN KEY (black_account_id) REFERENCES accounts(id)
);

CREATE TABLE IF NOT EXISTS positions (
  id INTEGER PRIMARY KEY,
  -- canonical_hash is now the Zobrist of the 4-field stripped FEN.
  canonical_hash TEXT NOT NULL UNIQUE,
  canonical_fen TEXT NOT NULL,
  side_to_move TEXT NOT NULL,
  castling TEXT,
  en_passant TEXT,
  created_at TEXT
);

-- Deduplicated directed edges between positions.
CREATE TABLE IF NOT EXISTS moves (
  id INTEGER PRIMARY KEY,
  from_position_id INTEGER NOT NULL,
  to_position_id INTEGER NOT NULL,
  move_uci TEXT NOT NULL,
  move_san TEXT,
  UNIQUE(from_position_id, to_position_id, move_uci),
  FOREIGN KEY (from_position_id) REFERENCES positions(id),
  FOREIGN KEY (to_position_id) REFERENCES positions(id)
);

-- Stats are now strictly tied to the unique structural position.
CREATE TABLE IF NOT EXISTS position_color_stats (
  position_id INTEGER PRIMARY KEY,
  white_wins INTEGER NOT NULL DEFAULT 0,
  draws INTEGER NOT NULL DEFAULT 0,
  black_wins INTEGER NOT NULL DEFAULT 0,
  occurrences INTEGER NOT NULL DEFAULT 0,
  me_wins INTEGER NOT NULL DEFAULT 0,
  me_draws INTEGER NOT NULL DEFAULT 0,
  me_losses INTEGER NOT NULL DEFAULT 0,
  me_occurrences INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (position_id) REFERENCES positions(id)
);

CREATE TABLE IF NOT EXISTS position_player_stats (
  position_id INTEGER NOT NULL,
  account_id INTEGER NOT NULL,
  wins INTEGER NOT NULL DEFAULT 0,
  draws INTEGER NOT NULL DEFAULT 0,
  losses INTEGER NOT NULL DEFAULT 0,
  occurrences INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (position_id, account_id),
  FOREIGN KEY (position_id) REFERENCES positions(id),
  FOREIGN KEY (account_id) REFERENCES accounts(id)
);

CREATE TABLE IF NOT EXISTS annotations (
  id INTEGER PRIMARY KEY,
  position_id INTEGER,
  game_id INTEGER,
  ply INTEGER,
  kind TEXT NOT NULL,
  source TEXT NOT NULL,
  content TEXT NOT NULL,
  model TEXT,
  prompt_version TEXT,
  created_at TEXT,
  FOREIGN KEY (position_id) REFERENCES positions(id),
  FOREIGN KEY (game_id) REFERENCES games(id)
);

CREATE TABLE IF NOT EXISTS position_critter_evals (
  id INTEGER PRIMARY KEY,
  position_id INTEGER NOT NULL,
  critter_name TEXT NOT NULL,
  critter_model TEXT,
  normalized_fen TEXT,
  phase INTEGER,
  final_score INTEGER NOT NULL,
  engine_score INTEGER,
  legal_is_legal INTEGER,
  legal_is_check INTEGER,
  legal_is_checkmate INTEGER,
  legal_is_stalemate INTEGER,
  legal_is_insufficient_material INTEGER,
  legal_move_count INTEGER,
  material_json TEXT,
  pawn_structure_json TEXT,
  piece_activity_json TEXT,
  king_safety_json TEXT,
  passed_pawns_json TEXT,
  development_json TEXT,
  scaling_value INTEGER,
  scaling_factor INTEGER,
  drawishness_value INTEGER,
  drawishness_factor INTEGER,
  override_value INTEGER,
  override_factor INTEGER,
  checks_sum_groups INTEGER,
  checks_matches_final INTEGER,
  checks_delta INTEGER,
  analysis_json TEXT NOT NULL,
  created_at TEXT,
  UNIQUE(position_id, critter_name, critter_model),
  FOREIGN KEY (position_id) REFERENCES positions(id)
);

-- Queues and Enrichment
CREATE TABLE IF NOT EXISTS position_critter_eval_queue (
  position_id INTEGER PRIMARY KEY,
  priority INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending',
  source TEXT,
  queued_at TEXT,
  started_at TEXT,
  finished_at TEXT,
  last_error TEXT,
  FOREIGN KEY (position_id) REFERENCES positions(id)
);

CREATE INDEX IF NOT EXISTS idx_moves_from_id ON moves(from_position_id);
CREATE INDEX IF NOT EXISTS idx_moves_to_id ON moves(to_position_id);
CREATE INDEX IF NOT EXISTS idx_games_white ON games(white_account_id);
CREATE INDEX IF NOT EXISTS idx_games_black ON games(black_account_id);

CREATE TABLE IF NOT EXISTS move_stats (
  move_id INTEGER PRIMARY KEY,
  white_wins INTEGER NOT NULL DEFAULT 0,
  draws INTEGER NOT NULL DEFAULT 0,
  black_wins INTEGER NOT NULL DEFAULT 0,
  occurrences INTEGER NOT NULL DEFAULT 0,
  me_wins INTEGER NOT NULL DEFAULT 0,
  me_draws INTEGER NOT NULL DEFAULT 0,
  me_losses INTEGER NOT NULL DEFAULT 0,
  me_occurrences INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (move_id) REFERENCES moves(id)
);
