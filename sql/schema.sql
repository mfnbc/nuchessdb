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
