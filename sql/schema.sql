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
  UNIQUE(platform, source_game_id),
  FOREIGN KEY (white_account_id) REFERENCES accounts(id),
  FOREIGN KEY (black_account_id) REFERENCES accounts(id)
);

CREATE TABLE IF NOT EXISTS positions (
  id INTEGER PRIMARY KEY,
  canonical_hash TEXT NOT NULL UNIQUE,
  canonical_fen TEXT NOT NULL,
  raw_fen TEXT NOT NULL,
  side_to_move TEXT NOT NULL,
  castling TEXT,
  en_passant TEXT,
  halfmove_clock INTEGER,
  fullmove_number INTEGER,
  created_at TEXT
);

CREATE TABLE IF NOT EXISTS game_positions (
  id INTEGER PRIMARY KEY,
  game_id INTEGER NOT NULL,
  ply INTEGER NOT NULL,
  move_san TEXT,
  move_uci TEXT,
  position_before_id INTEGER,
  position_after_id INTEGER,
  mover_account_id INTEGER,
  FOREIGN KEY (game_id) REFERENCES games(id),
  FOREIGN KEY (position_before_id) REFERENCES positions(id),
  FOREIGN KEY (position_after_id) REFERENCES positions(id),
  FOREIGN KEY (mover_account_id) REFERENCES accounts(id)
);

CREATE TABLE IF NOT EXISTS position_color_stats (
  position_id INTEGER PRIMARY KEY,
  white_wins INTEGER NOT NULL DEFAULT 0,
  draws INTEGER NOT NULL DEFAULT 0,
  black_wins INTEGER NOT NULL DEFAULT 0,
  occurrences INTEGER NOT NULL DEFAULT 0,
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
  game_position_id INTEGER,
  kind TEXT NOT NULL,
  source TEXT NOT NULL,
  content TEXT NOT NULL,
  model TEXT,
  prompt_version TEXT,
  created_at TEXT,
  FOREIGN KEY (position_id) REFERENCES positions(id),
  FOREIGN KEY (game_position_id) REFERENCES game_positions(id)
);

CREATE TABLE IF NOT EXISTS position_engine_evals (
  id INTEGER PRIMARY KEY,
  position_id INTEGER NOT NULL,
  engine_name TEXT NOT NULL,
  engine_model TEXT,
  depth INTEGER,
  nodes INTEGER,
  centipawn INTEGER,
  mate INTEGER,
  best_move_uci TEXT,
  best_move_san TEXT,
  analysis_json TEXT,
  created_at TEXT,
  UNIQUE(position_id, engine_name, engine_model),
  FOREIGN KEY (position_id) REFERENCES positions(id)
);

CREATE TABLE IF NOT EXISTS dynamic_model_profiles (
  id INTEGER PRIMARY KEY,
  engine_name TEXT NOT NULL,
  elo_tune INTEGER NOT NULL,
  created_at TEXT,
  UNIQUE(engine_name, elo_tune)
);

CREATE TABLE IF NOT EXISTS position_dynamic_queue (
  position_zobrist TEXT NOT NULL,
  profile_id INTEGER NOT NULL,
  priority INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'popular',
  status TEXT NOT NULL DEFAULT 'pending',
  queued_at TEXT,
  started_at TEXT,
  finished_at TEXT,
  last_error TEXT,
  PRIMARY KEY (position_zobrist, profile_id),
  FOREIGN KEY (position_zobrist) REFERENCES positions(canonical_hash),
  FOREIGN KEY (profile_id) REFERENCES dynamic_model_profiles(id)
);

CREATE TABLE IF NOT EXISTS position_dynamic_runs (
  id INTEGER PRIMARY KEY,
  position_zobrist TEXT NOT NULL,
  profile_id INTEGER NOT NULL,
  position_fen TEXT NOT NULL,
  side_to_move TEXT,
  depth INTEGER,
  nodes INTEGER,
  value_cp INTEGER,
  value_mate INTEGER,
  best_move_uci TEXT,
  best_move_san TEXT,
  analysis_json TEXT NOT NULL,
  created_at TEXT,
  UNIQUE(position_zobrist, profile_id),
  FOREIGN KEY (position_zobrist) REFERENCES positions(canonical_hash),
  FOREIGN KEY (profile_id) REFERENCES dynamic_model_profiles(id)
);

CREATE TABLE IF NOT EXISTS position_dynamic_top_moves (
  id INTEGER PRIMARY KEY,
  run_id INTEGER NOT NULL,
  move_rank INTEGER NOT NULL,
  move_uci TEXT NOT NULL,
  move_san TEXT,
  prior REAL,
  q_cp INTEGER,
  q_mate INTEGER,
  value_cp INTEGER,
  pv TEXT,
  analysis_json TEXT,
  created_at TEXT,
  UNIQUE(run_id, move_rank),
  UNIQUE(run_id, move_uci),
  FOREIGN KEY (run_id) REFERENCES position_dynamic_runs(id)
);

CREATE TABLE IF NOT EXISTS position_critter_eval_queue (
  position_id INTEGER PRIMARY KEY,
  priority INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'popular',
  status TEXT NOT NULL DEFAULT 'pending',
  queued_at TEXT,
  started_at TEXT,
  finished_at TEXT,
  last_error TEXT,
  FOREIGN KEY (position_id) REFERENCES positions(id)
);

CREATE TABLE IF NOT EXISTS position_critter_evals (
  id INTEGER PRIMARY KEY,
  position_id INTEGER NOT NULL,
  critter_name TEXT NOT NULL,
  critter_model TEXT,
  normalized_fen TEXT NOT NULL,
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
  checks_matches_final INTEGER NOT NULL DEFAULT 0,
  checks_delta INTEGER,
  analysis_json TEXT NOT NULL,
  created_at TEXT,
  UNIQUE(position_id, critter_name, critter_model),
  FOREIGN KEY (position_id) REFERENCES positions(id)
);

CREATE TABLE IF NOT EXISTS position_import_collisions (
  id INTEGER PRIMARY KEY,
  source_game_id TEXT NOT NULL,
  batch_index INTEGER,
  zobrist TEXT NOT NULL,
  fen TEXT NOT NULL,
  occurrences INTEGER NOT NULL,
  game_indexes_json TEXT,
  created_at TEXT,
  UNIQUE(source_game_id, zobrist),
  FOREIGN KEY (zobrist) REFERENCES positions(canonical_hash)
);

CREATE TABLE IF NOT EXISTS position_enrichment_queue (
  position_id INTEGER PRIMARY KEY,
  priority INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  queued_at TEXT,
  started_at TEXT,
  finished_at TEXT,
  last_error TEXT,
  FOREIGN KEY (position_id) REFERENCES positions(id)
);

-- Indexes on FK columns that are not already primary keys.
-- These prevent full table scans when joining from positions into the eval/run tables.
CREATE INDEX IF NOT EXISTS idx_position_engine_evals_position_id    ON position_engine_evals(position_id);
CREATE INDEX IF NOT EXISTS idx_position_critter_evals_position_id   ON position_critter_evals(position_id);
CREATE INDEX IF NOT EXISTS idx_position_dynamic_runs_position_id    ON position_dynamic_runs(position_id);
CREATE INDEX IF NOT EXISTS idx_game_positions_game_id               ON game_positions(game_id);
CREATE INDEX IF NOT EXISTS idx_game_positions_position_before_id    ON game_positions(position_before_id);
CREATE INDEX IF NOT EXISTS idx_game_positions_position_after_id     ON game_positions(position_after_id);
CREATE INDEX IF NOT EXISTS idx_game_positions_mover_account_id      ON game_positions(mover_account_id);
CREATE INDEX IF NOT EXISTS idx_position_player_stats_account_id     ON position_player_stats(account_id);

