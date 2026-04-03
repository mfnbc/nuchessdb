use ./config.nu *

export def show-overview [] {
  let cfg = load-config
  let db_path = $cfg.database.path

  let games = (open $db_path | query db "SELECT COUNT(*) AS count FROM games")
  let positions = (open $db_path | query db "SELECT COUNT(*) AS count FROM positions")
  let annotations = (open $db_path | query db "SELECT COUNT(*) AS count FROM annotations")

  {
    database: $db_path
    games: (if ($games | is-empty) { 0 } else { $games.0.count })
    positions: (if ($positions | is-empty) { 0 } else { $positions.0.count })
    annotations: (if ($annotations | is-empty) { 0 } else { $annotations.0.count })
  }
}

export def recent-games [limit: int = 10] {
  let cfg = load-config
  let db_path = $cfg.database.path
  open $db_path | query db $'SELECT platform, source_game_id, result, played_at FROM games ORDER BY id DESC LIMIT ($limit)'
}

export def top-positions [limit: int = 20] {
  let cfg = load-config
  let db_path = $cfg.database.path

  open $db_path | query db ([
    "SELECT p.canonical_hash, p.canonical_fen, s.occurrences, s.white_wins, s.draws, s.black_wins FROM positions p ",
    "LEFT JOIN position_color_stats s ON s.position_id = p.id ",
    "ORDER BY COALESCE(s.occurrences, 0) DESC, p.id DESC ",
    "LIMIT ", ($limit | into string)
  ] | str join)
}

export def position-report [limit: int = 20] {
  let cfg = load-config
  let db_path = $cfg.database.path

  open $db_path | query db ([
    "WITH color_stats AS (SELECT position_id, white_wins, draws, black_wins, occurrences FROM position_color_stats), ",
    "me_stats AS (SELECT ps.position_id, SUM(ps.wins) AS me_wins, SUM(ps.draws) AS me_draws, SUM(ps.losses) AS me_losses, SUM(ps.occurrences) AS me_occurrences FROM position_player_stats ps JOIN accounts a ON a.id = ps.account_id WHERE a.is_me = 1 GROUP BY ps.position_id) ",
    "SELECT p.canonical_hash, p.canonical_fen, COALESCE(c.occurrences, 0) AS occurrences, COALESCE(c.white_wins, 0) AS white_wins, COALESCE(c.draws, 0) AS draws, COALESCE(c.black_wins, 0) AS black_wins, ROUND(100.0 * COALESCE(c.white_wins, 0) / NULLIF(COALESCE(c.occurrences, 0), 0), 1) AS white_win_rate, ROUND(100.0 * COALESCE(c.black_wins, 0) / NULLIF(COALESCE(c.occurrences, 0), 0), 1) AS black_win_rate, COALESCE(m.me_occurrences, 0) AS me_occurrences, COALESCE(m.me_wins, 0) AS me_wins, COALESCE(m.me_draws, 0) AS me_draws, COALESCE(m.me_losses, 0) AS me_losses, ROUND(100.0 * COALESCE(m.me_wins, 0) / NULLIF(COALESCE(m.me_occurrences, 0), 0), 1) AS me_win_rate, ROUND(100.0 * COALESCE(m.me_losses, 0) / NULLIF(COALESCE(m.me_occurrences, 0), 0), 1) AS me_loss_rate FROM positions p LEFT JOIN color_stats c ON c.position_id = p.id LEFT JOIN me_stats m ON m.position_id = p.id WHERE COALESCE(c.occurrences, 0) > 0 OR COALESCE(m.me_occurrences, 0) > 0 ORDER BY COALESCE(m.me_losses, 0) DESC, COALESCE(c.occurrences, 0) DESC, p.id DESC LIMIT ", ($limit | into string)
  ] | str join)
}

export def most-played-opponents [limit: int = 20] {
  let cfg = load-config
  let db_path = $cfg.database.path

  open $db_path | query db ([
    "WITH me_accounts AS (SELECT id, platform, username FROM accounts WHERE is_me = 1), opp AS (SELECT g.platform AS platform, CASE WHEN g.white_account_id = m.id THEN b.username ELSE w.username END AS opponent, CASE WHEN g.white_account_id = m.id THEN g.black_elo ELSE g.white_elo END AS opponent_elo, CASE WHEN g.white_account_id = m.id THEN 'white' ELSE 'black' END AS me_color, g.result AS result FROM games g JOIN me_accounts m ON m.platform = g.platform AND (g.white_account_id = m.id OR g.black_account_id = m.id) LEFT JOIN accounts w ON w.id = g.white_account_id LEFT JOIN accounts b ON b.id = g.black_account_id) SELECT platform, opponent, COUNT(*) AS games, ROUND(AVG(opponent_elo), 1) AS avg_opponent_elo, MAX(opponent_elo) AS max_opponent_elo, SUM(CASE WHEN (me_color = 'white' AND result = '1-0') OR (me_color = 'black' AND result = '0-1') THEN 1 ELSE 0 END) AS wins, SUM(CASE WHEN result = '1/2-1/2' THEN 1 ELSE 0 END) AS draws, SUM(CASE WHEN (me_color = 'white' AND result = '0-1') OR (me_color = 'black' AND result = '1-0') THEN 1 ELSE 0 END) AS losses FROM opp GROUP BY platform, opponent ORDER BY games DESC, avg_opponent_elo DESC, opponent ASC LIMIT ", ($limit | into string)
  ] | str join)
}

export def highest-rated-opponents [limit: int = 50] {
  let cfg = load-config
  let db_path = $cfg.database.path

  open $db_path | query db ([
    "WITH me_accounts AS (SELECT id, platform, username FROM accounts WHERE is_me = 1), opp AS (SELECT g.platform AS platform, CASE WHEN g.white_account_id = m.id THEN b.username ELSE w.username END AS opponent, CASE WHEN g.white_account_id = m.id THEN g.black_elo ELSE g.white_elo END AS opponent_elo, CASE WHEN g.white_account_id = m.id THEN 'white' ELSE 'black' END AS me_color, g.result AS result FROM games g JOIN me_accounts m ON m.platform = g.platform AND (g.white_account_id = m.id OR g.black_account_id = m.id) LEFT JOIN accounts w ON w.id = g.white_account_id LEFT JOIN accounts b ON b.id = g.black_account_id) SELECT platform, opponent, ROUND(AVG(opponent_elo), 1) AS avg_opponent_elo, MAX(opponent_elo) AS max_opponent_elo, COUNT(*) AS games, SUM(CASE WHEN (me_color = 'white' AND result = '1-0') OR (me_color = 'black' AND result = '0-1') THEN 1 ELSE 0 END) AS wins, SUM(CASE WHEN result = '1/2-1/2' THEN 1 ELSE 0 END) AS draws, SUM(CASE WHEN (me_color = 'white' AND result = '0-1') OR (me_color = 'black' AND result = '1-0') THEN 1 ELSE 0 END) AS losses FROM opp WHERE opponent_elo IS NOT NULL GROUP BY platform, opponent ORDER BY avg_opponent_elo DESC, games DESC, opponent ASC LIMIT ", ($limit | into string)
  ] | str join)
}

export def enqueue-hot-positions [limit: int = 50] {
  let cfg = load-config
  let db_path = $cfg.database.path

  open $db_path | query db ([
    "INSERT INTO position_enrichment_queue (position_id, priority, source, status, queued_at) SELECT p.id, COALESCE(s.occurrences, 0) AS priority, 'hot' AS source, 'pending' AS status, datetime('now') AS queued_at FROM positions p LEFT JOIN position_color_stats s ON s.position_id = p.id ORDER BY COALESCE(s.occurrences, 0) DESC, p.id DESC LIMIT ", ($limit | into string), " ON CONFLICT(position_id) DO UPDATE SET priority = excluded.priority, source = excluded.source, status = 'pending', queued_at = excluded.queued_at;"
  ] | str join)
}

export def queued-enrichment [limit: int = 50] {
  let cfg = load-config
  let db_path = $cfg.database.path

  open $db_path | query db ([
    "SELECT q.position_id, q.priority, q.status, q.source, q.queued_at, p.canonical_hash, p.canonical_fen, COALESCE(s.occurrences, 0) AS occurrences FROM position_enrichment_queue q JOIN positions p ON p.id = q.position_id LEFT JOIN position_color_stats s ON s.position_id = p.id WHERE q.status = 'pending' ORDER BY q.priority DESC, q.queued_at ASC LIMIT ", ($limit | into string)
  ] | str join)
}

export def queue-stats [] {
  let cfg = load-config
  let db_path = $cfg.database.path

  open $db_path | query db "SELECT status, COUNT(*) AS count FROM position_enrichment_queue GROUP BY status ORDER BY status"
}

export def enqueue-positions-by-occurrence [limit: int = 50] {
  let cfg = load-config
  let db_path = $cfg.database.path

  open $db_path | query db ([
    "INSERT INTO position_enrichment_queue (position_id, priority, source, status, queued_at) SELECT p.id, COALESCE(s.occurrences, 0) AS priority, 'occurrence' AS source, 'pending' AS status, datetime('now') AS queued_at FROM positions p LEFT JOIN position_color_stats s ON s.position_id = p.id ORDER BY COALESCE(s.occurrences, 0) DESC, p.id DESC LIMIT ", ($limit | into string), " ON CONFLICT(position_id) DO UPDATE SET priority = excluded.priority, source = excluded.source, status = 'pending', queued_at = excluded.queued_at;"
  ] | str join)
}
