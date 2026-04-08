use ./config.nu *
use ./eco.nu *

# ---------------------------------------------------------------------------
# Report generation
#
# Writes .md reports to ./reports/ with .nuon cache files in ./reports/.cache/
#
# Phase 1 — Game-level facts:
#   color-performance.md   Win/draw/loss split as White vs Black
#   rating-bands.md        Results vs lower / similar / higher-rated opponents
#   time-control.md        Performance by bullet / blitz / rapid / classical
# ---------------------------------------------------------------------------

def reports-dir [] { "./reports" }
def cache-dir []   { "./reports/.cache" }

def ensure-dirs [] {
  mkdir (reports-dir)
  mkdir (cache-dir)
}

# ---------------------------------------------------------------------------
# Phase 1 — Report 1: Color performance
# ---------------------------------------------------------------------------

# Generate color-performance.md — win/draw/loss split as White vs Black.
# Writes reports/color-performance.md and reports/.cache/color.nuon.
export def generate-color-performance [] {
  let cfg = load-config
  let db = $cfg.database.path
  ensure-dirs

  let rows = (open $db | query db "
    WITH me_games AS (
      SELECT
        CASE WHEN g.white_account_id = a.id THEN 'white' ELSE 'black' END AS color,
        CASE
          WHEN g.white_account_id = a.id AND g.result = '1-0' THEN 'win'
          WHEN g.black_account_id = a.id AND g.result = '0-1' THEN 'win'
          WHEN g.result = '1/2-1/2' THEN 'draw'
          ELSE 'loss'
        END AS outcome
      FROM games g
      JOIN accounts a ON a.is_me = 1
        AND (g.white_account_id = a.id OR g.black_account_id = a.id)
    )
    SELECT
      color,
      COUNT(*) AS total,
      SUM(CASE WHEN outcome = 'win'  THEN 1 ELSE 0 END) AS wins,
      SUM(CASE WHEN outcome = 'draw' THEN 1 ELSE 0 END) AS draws,
      SUM(CASE WHEN outcome = 'loss' THEN 1 ELSE 0 END) AS losses,
      ROUND(100.0 * SUM(CASE WHEN outcome = 'win'  THEN 1 ELSE 0 END) / COUNT(*), 1) AS win_pct,
      ROUND(100.0 * SUM(CASE WHEN outcome = 'draw' THEN 1 ELSE 0 END) / COUNT(*), 1) AS draw_pct,
      ROUND(100.0 * SUM(CASE WHEN outcome = 'loss' THEN 1 ELSE 0 END) / COUNT(*), 1) AS loss_pct
    FROM me_games
    GROUP BY color
    ORDER BY color
  ")

  let report_path = $"(reports-dir)/color-performance.md"
  let cache_path  = $"(cache-dir)/color.nuon"
  let generated   = (date now | format date "%Y-%m-%d %H:%M:%S")

  if ($rows | is-empty) {
    ["# Color Performance", "", "_No game data available._", ""] | str join "\n" | save --force $report_path
    return { status: "no-data", path: $report_path }
  }

  $rows | to nuon | save --force $cache_path

  let total = ($rows | get total | math sum)
  let table_header = "| Color | Games | Wins | Draws | Losses | Win% | Draw% | Loss% |"
  let table_sep    = "|-------|-------|------|-------|--------|------|-------|-------|"
  let table_rows   = ($rows | each { |r|
    let c = ($r.color | str capitalize)
    $"| ($c) | ($r.total) | ($r.wins) | ($r.draws) | ($r.losses) | ($r.win_pct)% | ($r.draw_pct)% | ($r.loss_pct)% |"
  })

  [
    "# Color Performance", "",
    $"_Generated ($generated) — ($total) games_", "",
    "## Results by Color", "",
    $table_header, $table_sep,
  ] | append $table_rows | append [""] | str join "\n" | save --force $report_path

  { status: "ok", path: $report_path, games: $total }
}

# ---------------------------------------------------------------------------
# Phase 1 — Report 2: Rating bands
# ---------------------------------------------------------------------------

# Generate rating-bands.md — results vs lower / similar / higher-rated opponents.
# Bands: opponents rated >=100 points above or below your rating at game time.
# Writes reports/rating-bands.md and reports/.cache/rating-bands.nuon.
export def generate-rating-bands [] {
  let cfg = load-config
  let db = $cfg.database.path
  ensure-dirs

  let rows = (open $db | query db "
    WITH me_games AS (
      SELECT
        g.result AS g_result,
        CASE WHEN g.white_account_id = a.id THEN 'white' ELSE 'black' END AS my_color,
        CASE WHEN g.white_account_id = a.id THEN g.white_elo ELSE g.black_elo END AS my_elo,
        CASE WHEN g.white_account_id = a.id THEN g.black_elo ELSE g.white_elo END AS opp_elo
      FROM games g
      JOIN accounts a ON a.is_me = 1
        AND (g.white_account_id = a.id OR g.black_account_id = a.id)
    ),
    classified AS (
      SELECT
        CASE
          WHEN my_elo IS NULL OR opp_elo IS NULL THEN 'unknown'
          WHEN opp_elo >= my_elo + 100 THEN 'higher_rated'
          WHEN opp_elo <= my_elo - 100 THEN 'lower_rated'
          ELSE 'similar_rated'
        END AS band,
        CASE
          WHEN (my_color = 'white' AND g_result = '1-0') OR (my_color = 'black' AND g_result = '0-1') THEN 'win'
          WHEN g_result = '1/2-1/2' THEN 'draw'
          ELSE 'loss'
        END AS outcome
      FROM me_games
    )
    SELECT
      band,
      COUNT(*) AS total,
      SUM(CASE WHEN outcome = 'win'  THEN 1 ELSE 0 END) AS wins,
      SUM(CASE WHEN outcome = 'draw' THEN 1 ELSE 0 END) AS draws,
      SUM(CASE WHEN outcome = 'loss' THEN 1 ELSE 0 END) AS losses,
      ROUND(100.0 * SUM(CASE WHEN outcome = 'win'  THEN 1 ELSE 0 END) / COUNT(*), 1) AS win_pct,
      ROUND(100.0 * SUM(CASE WHEN outcome = 'draw' THEN 1 ELSE 0 END) / COUNT(*), 1) AS draw_pct,
      ROUND(100.0 * SUM(CASE WHEN outcome = 'loss' THEN 1 ELSE 0 END) / COUNT(*), 1) AS loss_pct
    FROM classified
    GROUP BY band
    ORDER BY
      CASE band
        WHEN 'higher_rated'  THEN 1
        WHEN 'similar_rated' THEN 2
        WHEN 'lower_rated'   THEN 3
        ELSE 4
      END
  ")

  let report_path = $"(reports-dir)/rating-bands.md"
  let cache_path  = $"(cache-dir)/rating-bands.nuon"
  let generated   = (date now | format date "%Y-%m-%d %H:%M:%S")

  if ($rows | is-empty) {
    ["# Performance vs Rating Bands", "", "_No game data available._", ""] | str join "\n" | save --force $report_path
    return { status: "no-data", path: $report_path }
  }

  $rows | to nuon | save --force $cache_path

  let total = ($rows | get total | math sum)

  # Map internal band keys to display labels
  let display = {
    higher_rated:  "Higher rated  (opp >=100 above)"
    similar_rated: "Similar rated (within 100)"
    lower_rated:   "Lower rated   (opp >=100 below)"
    unknown:       "Unknown ELO"
  }

  let table_header = "| Band | Games | Wins | Draws | Losses | Win% | Draw% | Loss% |"
  let table_sep    = "|------|-------|------|-------|--------|------|-------|-------|"
  let table_rows = ($rows | each { |r|
    let label = ($display | get -o $r.band | default $r.band)
    $"| ($label) | ($r.total) | ($r.wins) | ($r.draws) | ($r.losses) | ($r.win_pct)% | ($r.draw_pct)% | ($r.loss_pct)% |"
  })

  [
    "# Performance vs Rating Bands", "",
    $"_Generated ($generated) — ($total) games_", "",
    "Bands are based on ELO at game time. Opponents rated ≥100 points above or below",
    "are classed as higher or lower rated. Games without ELO data are shown separately.", "",
    "## Results by Opponent Rating", "",
    $table_header, $table_sep,
  ] | append $table_rows | append [""] | str join "\n" | save --force $report_path

  { status: "ok", path: $report_path, games: $total }
}

# ---------------------------------------------------------------------------
# Phase 1 — Report 3: Time control
# ---------------------------------------------------------------------------

# Generate time-control.md — performance by bullet / blitz / rapid / classical.
# Classification uses the base time (seconds before any increment):
#   bullet:    < 3 min  (180 s)
#   blitz:     3–10 min (180–599 s)
#   rapid:     10–60 min (600–3599 s)
#   classical: >= 60 min (3600 s)
# Writes reports/time-control.md and reports/.cache/time-control.nuon.
export def generate-time-control [] {
  let cfg = load-config
  let db = $cfg.database.path
  ensure-dirs

  let rows = (open $db | query db "
    WITH me_games AS (
      SELECT
        g.result AS g_result,
        g.time_control,
        CASE WHEN g.white_account_id = a.id THEN 'white' ELSE 'black' END AS my_color
      FROM games g
      JOIN accounts a ON a.is_me = 1
        AND (g.white_account_id = a.id OR g.black_account_id = a.id)
    ),
    parsed AS (
      SELECT
        g_result,
        my_color,
        CAST(CASE
          WHEN time_control LIKE '%+%' THEN SUBSTR(time_control, 1, INSTR(time_control, '+') - 1)
          WHEN time_control IS NOT NULL AND time_control != '' THEN time_control
          ELSE NULL
        END AS INTEGER) AS base_secs
      FROM me_games
    ),
    classified AS (
      SELECT
        CASE
          WHEN base_secs IS NULL  THEN 'unknown'
          WHEN base_secs < 180    THEN 'bullet'
          WHEN base_secs < 600    THEN 'blitz'
          WHEN base_secs < 3600   THEN 'rapid'
          ELSE 'classical'
        END AS time_class,
        CASE
          WHEN (my_color = 'white' AND g_result = '1-0') OR (my_color = 'black' AND g_result = '0-1') THEN 'win'
          WHEN g_result = '1/2-1/2' THEN 'draw'
          ELSE 'loss'
        END AS outcome
      FROM parsed
    )
    SELECT
      time_class,
      COUNT(*) AS total,
      SUM(CASE WHEN outcome = 'win'  THEN 1 ELSE 0 END) AS wins,
      SUM(CASE WHEN outcome = 'draw' THEN 1 ELSE 0 END) AS draws,
      SUM(CASE WHEN outcome = 'loss' THEN 1 ELSE 0 END) AS losses,
      ROUND(100.0 * SUM(CASE WHEN outcome = 'win'  THEN 1 ELSE 0 END) / COUNT(*), 1) AS win_pct,
      ROUND(100.0 * SUM(CASE WHEN outcome = 'draw' THEN 1 ELSE 0 END) / COUNT(*), 1) AS draw_pct,
      ROUND(100.0 * SUM(CASE WHEN outcome = 'loss' THEN 1 ELSE 0 END) / COUNT(*), 1) AS loss_pct
    FROM classified
    GROUP BY time_class
    ORDER BY
      CASE time_class
        WHEN 'bullet'    THEN 1
        WHEN 'blitz'     THEN 2
        WHEN 'rapid'     THEN 3
        WHEN 'classical' THEN 4
        ELSE 5
      END
  ")

  let report_path = $"(reports-dir)/time-control.md"
  let cache_path  = $"(cache-dir)/time-control.nuon"
  let generated   = (date now | format date "%Y-%m-%d %H:%M:%S")

  if ($rows | is-empty) {
    ["# Performance by Time Control", "", "_No game data available._", ""] | str join "\n" | save --force $report_path
    return { status: "no-data", path: $report_path }
  }

  $rows | to nuon | save --force $cache_path

  let total = ($rows | get total | math sum)

  let display = {
    bullet:    "Bullet    (< 3 min)"
    blitz:     "Blitz     (3–10 min)"
    rapid:     "Rapid     (10–60 min)"
    classical: "Classical (> 60 min)"
    unknown:   "Unknown"
  }

  let table_header = "| Format | Games | Wins | Draws | Losses | Win% | Draw% | Loss% |"
  let table_sep    = "|--------|-------|------|-------|--------|------|-------|-------|"
  let table_rows = ($rows | each { |r|
    let label = ($display | get -o $r.time_class | default $r.time_class)
    $"| ($label) | ($r.total) | ($r.wins) | ($r.draws) | ($r.losses) | ($r.win_pct)% | ($r.draw_pct)% | ($r.loss_pct)% |"
  })

  [
    "# Performance by Time Control", "",
    $"_Generated ($generated) — ($total) games_", "",
    "Classified by base time (seconds before any increment per move).", "",
    "## Results by Format", "",
    $table_header, $table_sep,
  ] | append $table_rows | append [""] | str join "\n" | save --force $report_path

  { status: "ok", path: $report_path, games: $total }
}

# ---------------------------------------------------------------------------
# Phase 2 — Report 4: Opening repertoire
# ---------------------------------------------------------------------------

# Generate opening-repertoire.md — most common opening positions with ECO names.
# Joins position_player_stats + positions, enriches with eco-classify.
# Writes reports/opening-repertoire.md and reports/.cache/openings.nuon.
export def generate-opening-repertoire [limit: int = 20] {
  let cfg = load-config
  let db = $cfg.database.path
  ensure-dirs

  let lim = ($limit | into string)
  let rows = (open $db | query db ([
    "SELECT p.canonical_fen, ps.wins AS me_wins, ps.draws AS me_draws, ps.losses AS me_losses, ps.occurrences AS me_occurrences,",
    " ROUND(100.0 * ps.wins / ps.occurrences, 1) AS win_pct,",
    " ROUND(100.0 * ps.draws / ps.occurrences, 1) AS draw_pct,",
    " ROUND(100.0 * ps.losses / ps.occurrences, 1) AS loss_pct",
    " FROM position_player_stats ps",
    " JOIN positions p ON p.id = ps.position_id",
    " JOIN accounts a  ON a.id = ps.account_id AND a.is_me = 1",
    " WHERE ps.occurrences >= 1",
    " ORDER BY ps.occurrences DESC, ps.wins DESC",
    " LIMIT ", $lim
  ] | str join))

  let report_path = $"(reports-dir)/opening-repertoire.md"
  let cache_path  = $"(cache-dir)/openings.nuon"
  let generated   = (date now | format date "%Y-%m-%d %H:%M:%S")

  if ($rows | is-empty) {
    ["# Opening Repertoire", "", "_No position data available._", ""] | str join "\n" | save --force $report_path
    return { status: "no-data", path: $report_path }
  }

  # Enrich with ECO classification
  let enriched = ($rows | eco-classify)

  $enriched | to nuon | save --force $cache_path

  let total_positions = ($enriched | length)
  let total_games     = ($enriched | get me_occurrences | math sum)

  let table_header = "| Opening | ECO | Games | Wins | Draws | Losses | Win% | Draw% | Loss% |"
  let table_sep    = "|---------|-----|-------|------|-------|--------|------|-------|-------|"
  let table_rows = ($enriched | each { |r|
    let name = if ($r.opening_name | is-empty) { "_Unknown_" } else { $r.opening_name }
    let eco  = if ($r.eco_code    | is-empty) { "—"         } else { $r.eco_code }
    $"| ($name) | ($eco) | ($r.me_occurrences) | ($r.me_wins) | ($r.me_draws) | ($r.me_losses) | ($r.win_pct)% | ($r.draw_pct)% | ($r.loss_pct)% |"
  })

  [
    "# Opening Repertoire", "",
    $"_Generated ($generated) — ($total_positions) positions across ($total_games) game appearances_", "",
    "Positions ranked by frequency. ECO classification matched on 4-field FEN prefix.", "",
    "## Most Frequent Positions", "",
    $table_header, $table_sep,
  ] | append $table_rows | append [""] | str join "\n" | save --force $report_path

  { status: "ok", path: $report_path, positions: $total_positions, games: $total_games }
}

# ---------------------------------------------------------------------------
# Phase 2 — Reports 5 & 6: Frequent losses / wins (shared implementation)
# ---------------------------------------------------------------------------

# Shared engine for generate-frequent-losses and generate-frequent-wins.
# outcome_col  — "losses" or "wins" (the column to sort and filter by)
# primary_pct  — "loss_pct" or "win_pct" (the primary percentage column)
# secondary_pct — "win_pct" or "loss_pct" (the secondary percentage column)
# report_file  — filename under reports/
# cache_file   — filename under reports/.cache/
# heading      — markdown heading (e.g. "Frequent Loss Positions")
# rank_line    — description line after heading
# section_head — ## sub-heading inside the report
# table_header — markdown table header row
# table_sep    — markdown table separator row
# row_fmt      — closure that formats one enriched row into a markdown table row string
def generate-frequent-outcome [
  min_occurrences: int,
  limit: int,
  outcome_col: string,
  primary_pct: string,
  secondary_pct: string,
  report_file: string,
  cache_file: string,
  heading: string,
  rank_line: string,
  section_head: string,
  table_header: string,
  table_sep: string,
  row_fmt: closure,
] {
  let cfg = load-config
  let db = $cfg.database.path
  ensure-dirs

  let min_occ = ($min_occurrences | into string)
  let lim     = ($limit | into string)
  let rows = (open $db | query db ([
    "SELECT p.canonical_fen, ps.wins AS me_wins, ps.draws AS me_draws, ps.losses AS me_losses, ps.occurrences AS me_occurrences,",
    $" ROUND\(100.0 * ps.losses / ps.occurrences, 1\) AS loss_pct,",
    $" ROUND\(100.0 * ps.wins / ps.occurrences, 1\) AS win_pct",
    " FROM position_player_stats ps",
    " JOIN positions p ON p.id = ps.position_id",
    " JOIN accounts a  ON a.id = ps.account_id AND a.is_me = 1",
    $" WHERE ps.occurrences >= ($min_occ) AND ps.($outcome_col) > 0",
    $" ORDER BY ps.($outcome_col) DESC, ($primary_pct) DESC",
    $" LIMIT ($lim)"
  ] | str join))

  let report_path = $"(reports-dir)/($report_file)"
  let cache_path  = $"(cache-dir)/($cache_file)"
  let generated   = (date now | format date "%Y-%m-%d %H:%M:%S")

  if ($rows | is-empty) {
    [$"# ($heading)", "", $"_No positions found with >= ($min_occurrences) occurrences and at least one ($outcome_col | str replace -a 's' '' | str trim)._", ""] | str join "\n" | save --force $report_path
    return { status: "no-data", path: $report_path }
  }

  let enriched = ($rows | eco-classify)
  $enriched | to nuon | save --force $cache_path

  let table_rows = ($enriched | each $row_fmt)

  [
    $"# ($heading)", "",
    $"_Generated ($generated) — positions with >= ($min_occurrences) occurrences_", "",
    $rank_line, "",
    $"## ($section_head)", "",
    $table_header, $table_sep,
  ] | append $table_rows | append [""] | str join "\n" | save --force $report_path

  { status: "ok", path: $report_path, positions: ($enriched | length) }
}

# Generate frequent-losses.md — positions where you lose most often.
# Uses a minimum occurrence threshold to filter noise.
# Writes reports/frequent-losses.md and reports/.cache/loss-positions.nuon.
export def generate-frequent-losses [min_occurrences: int = 2, limit: int = 20] {
  generate-frequent-outcome $min_occurrences $limit
    "losses" "loss_pct" "win_pct"
    "frequent-losses.md" "loss-positions.nuon"
    "Frequent Loss Positions"
    "Positions ranked by number of losses, then loss rate."
    "Positions Where You Lose Most"
    "| Opening | ECO | Occurrences | Losses | Loss% | Wins | Win% |"
    "|---------|-----|-------------|--------|-------|------|------|"
    { |r|
      let name = if ($r.opening_name | is-empty) { "_Unknown_" } else { $r.opening_name }
      let eco  = if ($r.eco_code    | is-empty) { "—"         } else { $r.eco_code }
      $"| ($name) | ($eco) | ($r.me_occurrences) | ($r.me_losses) | ($r.loss_pct)% | ($r.me_wins) | ($r.win_pct)% |"
    }
}

# Generate frequent-wins.md — positions where you win most reliably.
# Uses a minimum occurrence threshold to filter noise.
# Writes reports/frequent-wins.md and reports/.cache/win-positions.nuon.
export def generate-frequent-wins [min_occurrences: int = 2, limit: int = 20] {
  generate-frequent-outcome $min_occurrences $limit
    "wins" "win_pct" "loss_pct"
    "frequent-wins.md" "win-positions.nuon"
    "Frequent Win Positions"
    "Positions ranked by number of wins, then win rate."
    "Positions Where You Win Most"
    "| Opening | ECO | Occurrences | Wins | Win% | Losses | Loss% |"
    "|---------|-----|-------------|------|------|--------|-------|"
    { |r|
      let name = if ($r.opening_name | is-empty) { "_Unknown_" } else { $r.opening_name }
      let eco  = if ($r.eco_code    | is-empty) { "—"         } else { $r.eco_code }
      $"| ($name) | ($eco) | ($r.me_occurrences) | ($r.me_wins) | ($r.win_pct)% | ($r.me_losses) | ($r.loss_pct)% |"
    }
}

# ---------------------------------------------------------------------------
# Phase 3 — Report 7: Position profiles
# ---------------------------------------------------------------------------

# Classify a single row on three axes using the critter group blended scores.
# Returns the row with openness, character, and tempo columns appended.
def classify-position [r: record] {
  let act    = ($r.activity_blended | default 0 | into int)
  let pawn   = ($r.pawn_blended     | default 0 | into int)
  let safety = ($r.safety_blended   | default 0 | into int)
  let passed = ($r.passed_blended   | default 0 | into int)
  let dev    = ($r.dev_blended      | default 0 | into int)

  # Open vs Closed: piece activity score vs pawn structure score
  let openness = if ($act >= $pawn) { "Open" } else { "Closed" }

  # Tactical vs Strategic: (activity + |safety|) vs (|pawn| + |passed|)
  let tact_sum  = (($act | math abs) + ($safety | math abs))
  let strat_sum = (($pawn | math abs) + ($passed | math abs))
  let character = if ($tact_sum >= $strat_sum) { "Tactical" } else { "Strategic" }

  # Dynamic vs Positional: (|dev| + |safety|) vs (|pawn| + |passed|)
  let dyn_sum  = (($dev | math abs) + ($safety | math abs))
  let pos_sum  = (($pawn | math abs) + ($passed | math abs))
  let tempo = if ($dyn_sum >= $pos_sum) { "Dynamic" } else { "Positional" }

  $r | insert openness $openness | insert character $character | insert tempo $tempo
}

# Summarise a list of classified rows grouped by the value of one column.
# Returns a table: category, positions, games, wins, draws, losses, win_pct
def axis-summary [col: string, labels: list<string>, classified: list<record>] {
  $labels | each { |lbl|
    let grp    = ($classified | where { |r| ($r | get $col) == $lbl })
    let games  = if ($grp | is-empty) { 0 } else { $grp | get me_occurrences | math sum }
    let wins   = if ($grp | is-empty) { 0 } else { $grp | get me_wins | math sum }
    let draws  = if ($grp | is-empty) { 0 } else { $grp | get me_draws | math sum }
    let losses = if ($grp | is-empty) { 0 } else { $grp | get me_losses | math sum }
    let wp = if $games > 0 { ($wins * 100.0 / $games | math round --precision 1) } else { 0.0 }
    let dp = if $games > 0 { ($draws * 100.0 / $games | math round --precision 1) } else { 0.0 }
    let lp = if $games > 0 { ($losses * 100.0 / $games | math round --precision 1) } else { 0.0 }
    { category: $lbl, positions: ($grp | length), games: $games, wins: $wins, draws: $draws, losses: $losses, win_pct: $wp, draw_pct: $dp, loss_pct: $lp }
  }
}

# Render one axis summary block as markdown lines.
def axis-md-block [title: string, col1: string, rows: list<record>] {
  let header = $"| ($col1) | Positions | Games | Wins | Draws | Losses | Win% | Draw% | Loss% |"
  let sep    = $"|---------|-----------|-------|------|-------|--------|------|-------|-------|"
  let trows  = ($rows | each { |r|
    $"| ($r.category) | ($r.positions) | ($r.games) | ($r.wins) | ($r.draws) | ($r.losses) | ($r.win_pct)% | ($r.draw_pct)% | ($r.loss_pct)% |"
  })
  [$title, "", $header, $sep] | append $trows | append [""]
}

# Generate position-profiles.md — classify my positions as Open/Closed,
# Tactical/Strategic, and Dynamic/Positional using critter blended group scores.
# Requires critter evals to be present (run chessdb critter-eval-queue first).
# Writes reports/position-profiles.md and reports/.cache/profiles.nuon.
export def generate-position-profiles [limit: int = 50] {
  let cfg = load-config
  let db = $cfg.database.path
  ensure-dirs

  let lim = ($limit | into string)
  let rows = (open $db | query db ([
    "SELECT p.canonical_fen, e.phase, e.final_score,",
    " json_extract(e.material_json,       '$.blended') AS material_blended,",
    " json_extract(e.pawn_structure_json, '$.blended') AS pawn_blended,",
    " json_extract(e.piece_activity_json, '$.blended') AS activity_blended,",
    " json_extract(e.king_safety_json,    '$.blended') AS safety_blended,",
    " json_extract(e.passed_pawns_json,   '$.blended') AS passed_blended,",
    " json_extract(e.development_json,    '$.blended') AS dev_blended,",
    " ps.wins AS me_wins, ps.draws AS me_draws, ps.losses AS me_losses,",
    " ps.occurrences AS me_occurrences",
    " FROM position_critter_evals e",
    " JOIN positions p ON p.id = e.position_id",
    " JOIN position_player_stats ps ON ps.position_id = e.position_id",
    " JOIN accounts a ON a.id = ps.account_id AND a.is_me = 1",
    " WHERE ps.occurrences >= 1",
    " ORDER BY ps.occurrences DESC, ABS(e.final_score) DESC",
    " LIMIT ", $lim
  ] | str join))

  let report_path = $"(reports-dir)/position-profiles.md"
  let cache_path  = $"(cache-dir)/profiles.nuon"
  let generated   = (date now | format date "%Y-%m-%d %H:%M:%S")

  if ($rows | is-empty) {
    [
      "# Position Profiles", "",
      "_No critter-evaluated positions found. Run `chessdb critter-eval-queue` first._", ""
    ] | str join "\n" | save --force $report_path
    return { status: "no-data", path: $report_path }
  }

  # Classify each position on three axes, enrich with ECO names
  let classified = ($rows | eco-classify | each { |r| classify-position $r })

  $classified | to nuon | save --force $cache_path

  let total = ($classified | length)

  # Build axis summary tables
  let open_rows  = (axis-summary "openness"  ["Open" "Closed"]     $classified)
  let char_rows  = (axis-summary "character" ["Tactical" "Strategic"] $classified)
  let tempo_rows = (axis-summary "tempo"     ["Dynamic" "Positional"] $classified)

  # Build top-positions detail table (top 20 by occurrences)
  let top = ($classified | first ([$total 20] | math min))
  let top_header = "| Opening | ECO | Open/Closed | Tact/Strat | Dyn/Pos | Score | Games | Win% |"
  let top_sep    = "|---------|-----|-------------|------------|---------|-------|-------|------|"
  let top_rows = ($top | each { |r|
    let name  = if ($r.opening_name | is-empty) { "_Unknown_" } else { $r.opening_name }
    let eco   = if ($r.eco_code    | is-empty) { "—"         } else { $r.eco_code }
    let wp    = if $r.me_occurrences > 0 { ($r.me_wins * 100.0 / $r.me_occurrences | math round) } else { 0 }
    $"| ($name) | ($eco) | ($r.openness) | ($r.character) | ($r.tempo) | ($r.final_score) | ($r.me_occurrences) | ($wp)% |"
  })

  let open_md  = (axis-md-block "## Open vs Closed"          "Category" $open_rows)
  let char_md  = (axis-md-block "## Tactical vs Strategic"   "Category" $char_rows)
  let tempo_md = (axis-md-block "## Dynamic vs Positional"   "Category" $tempo_rows)

  let lines = [
    "# Position Profiles", "",
    $"_Generated ($generated) — ($total) evaluated positions_", "",
    "Positions classified using critter-eval blended group scores.",
    "- **Open/Closed**: piece activity score vs pawn structure score",
    "- **Tactical/Strategic**: (activity + |safety|) vs (|pawn structure| + |passed pawns|)",
    "- **Dynamic/Positional**: (|development| + |safety|) vs (|pawn structure| + |passed pawns|)",
    "",
  ]

  let detail_lines = [
    "## Top Evaluated Positions", "",
    $top_header, $top_sep,
  ]

  $lines
  | append $open_md
  | append $char_md
  | append $tempo_md
  | append $detail_lines
  | append $top_rows
  | append [""]
  | str join "\n"
  | save --force $report_path

  { status: "ok", path: $report_path, positions: $total }
}

# ---------------------------------------------------------------------------
# Phase 4 helpers
# ---------------------------------------------------------------------------

# Open a .nuon cache file, returning [] if the file does not exist.
def safe-open-nuon [path: string] {
  if ($path | path exists) { open $path } else { [] }
}

# Render a compact 3-column table row for a profile axis.
def profile-axis-row [axis: string, a_label: string, a_n: int, b_label: string, b_n: int, total: int] {
  let pct = if $total > 0 { ($a_n * 100 / $total) } else { 0 }
  $"| ($axis) | ($a_n) ($a_label), ($b_n) ($b_label) | ($pct)% ($a_label) |"
}

# ---------------------------------------------------------------------------
# Phase 4 — Report 8: Playstyle summary
# ---------------------------------------------------------------------------

# Generate playstyle-summary.md — synthesise all cache files into a single
# narrative report. Reads from reports/.cache/*.nuon; missing caches are
# handled gracefully with a "no data" note for that section.
# Does NOT run a DB query — all data comes from caches written by phases 1-3.
export def generate-playstyle-summary [] {
  ensure-dirs

  let report_path = $"(reports-dir)/playstyle-summary.md"
  let generated   = (date now | format date "%Y-%m-%d %H:%M:%S")
  let cd          = (cache-dir)

  let color_data    = (safe-open-nuon $"($cd)/color.nuon")
  let bands_data    = (safe-open-nuon $"($cd)/rating-bands.nuon")
  let tc_data       = (safe-open-nuon $"($cd)/time-control.nuon")
  let openings_data = (safe-open-nuon $"($cd)/openings.nuon")
  let losses_data   = (safe-open-nuon $"($cd)/loss-positions.nuon")
  let wins_data     = (safe-open-nuon $"($cd)/win-positions.nuon")
  let profiles_data = (safe-open-nuon $"($cd)/profiles.nuon")

  let loaded = (
    [$color_data $bands_data $tc_data $openings_data $losses_data $wins_data $profiles_data]
    | where { |d| not ($d | is-empty) }
    | length
  )

  if $loaded == 0 {
    [
      "# Playstyle Summary", "",
      "_No cache data available. Run phases 1, 2, and 3 first:_",
      "_`generate-reports 1`, `generate-reports 2`, `generate-reports 3`_", ""
    ] | str join "\n" | save --force $report_path
    return { status: "no-data", path: $report_path }
  }

  # -------------------------------------------------------------------------
  # At a Glance — one line per dimension
  # -------------------------------------------------------------------------
  mut glance = []

  if not ($color_data | is-empty) {
    let best  = ($color_data | sort-by -r win_pct | first)
    let clbl  = ($best.color | str capitalize)
    let other = ($color_data | where color != $best.color)
    let owp   = if ($other | is-empty) { "—" } else {
      let v = ($other | first | get win_pct)
      $"($v)%"
    }
    let color_finding = [$clbl " - " ($best.win_pct | into string) "% win rate (other: " $owp ")"] | str join
    $glance = ($glance | append { dimension: "Best color", finding: $color_finding })
  }

  if not ($tc_data | is-empty) {
    let non_unk = ($tc_data | where time_class != "unknown")
    if not ($non_unk | is-empty) {
      let best = ($non_unk | sort-by -r win_pct | first)
      let tlbl = ($best.time_class | str capitalize)
      $glance = ($glance | append { dimension: "Best time format", finding: $"($tlbl) — ($best.win_pct)% win rate, ($best.total) games" })
    }
  }

  if not ($openings_data | is-empty) {
    let top  = ($openings_data | first)
    let oname = if ($top.opening_name | is-empty) { "Unknown" } else { $top.opening_name }
    let oeco  = if ($top.eco_code | is-empty) { "" } else {
      let ec = $top.eco_code
      $" ($ec)"
    }
    $glance = ($glance | append { dimension: "Most frequent opening", finding: $"($oname)($oeco) — ($top.me_occurrences) games, ($top.win_pct)% wins" })
  }

  if not ($profiles_data | is-empty) {
    let total    = ($profiles_data | length)
    let open_n   = ($profiles_data | where openness  == "Open"     | length)
    let tact_n   = ($profiles_data | where character == "Tactical"  | length)
    let dyn_n    = ($profiles_data | where tempo     == "Dynamic"   | length)
    let open_pct = ($open_n * 100 / $total)
    let tact_pct = ($tact_n * 100 / $total)
    let dyn_pct  = ($dyn_n  * 100 / $total)
    let sl = if $open_pct >= 50 { "Open" } else { "Closed" }
    let cl = if $tact_pct >= 50 { "Tactical" } else { "Strategic" }
    let tl = if $dyn_pct  >= 50 { "Dynamic" } else { "Positional" }
    $glance = ($glance | append { dimension: "Position style", finding: $"($sl) / ($cl) / ($tl) across ($total) evaluated positions" })
  }

  let glance_section = if ($glance | is-empty) { [] } else {
    let th = "| Dimension | Finding |"
    let ts = "|-----------|---------|"
    let tr = ($glance | each { |g| $"| ($g.dimension) | ($g.finding) |" })
    ["## At a Glance", "", $th, $ts] | append $tr | append [""]
  }

  # -------------------------------------------------------------------------
  # Color section
  # -------------------------------------------------------------------------
  let color_section = if ($color_data | is-empty) {
    ["## Color Performance", "", "_Run `generate-reports 1` to populate._", ""]
  } else {
    let th = "| Color | Games | Wins | Draws | Losses | Win% |"
    let ts = "|-------|-------|------|-------|--------|------|"
    let tr = ($color_data | each { |r|
      let cl = ($r.color | str capitalize)
      $"| ($cl) | ($r.total) | ($r.wins) | ($r.draws) | ($r.losses) | ($r.win_pct)% |"
    })
    ["## Color Performance", "", $th, $ts] | append $tr | append [""]
  }

  # -------------------------------------------------------------------------
  # Rating bands section
  # -------------------------------------------------------------------------
  let bands_section = if ($bands_data | is-empty) {
    ["## Rating Band Performance", "", "_Run `generate-reports 1` to populate._", ""]
  } else {
    let display = { higher_rated: "vs Higher-rated", similar_rated: "vs Similar-rated", lower_rated: "vs Lower-rated", unknown: "Unknown ELO" }
    let th = "| Band | Games | Win% |"
    let ts = "|------|-------|------|"
    let tr = ($bands_data | each { |r|
      let bl = ($display | get -o $r.band | default $r.band)
      $"| ($bl) | ($r.total) | ($r.win_pct)% |"
    })
    ["## Rating Band Performance", "", $th, $ts] | append $tr | append [""]
  }

  # -------------------------------------------------------------------------
  # Time control section
  # -------------------------------------------------------------------------
  let tc_section = if ($tc_data | is-empty) {
    ["## Time Control", "", "_Run `generate-reports 1` to populate._", ""]
  } else {
    let display = { bullet: "Bullet", blitz: "Blitz", rapid: "Rapid", classical: "Classical", unknown: "Unknown" }
    let th = "| Format | Games | Win% |"
    let ts = "|--------|-------|------|"
    let tr = ($tc_data | each { |r|
      let tl = ($display | get -o $r.time_class | default $r.time_class)
      $"| ($tl) | ($r.total) | ($r.win_pct)% |"
    })
    ["## Time Control", "", $th, $ts] | append $tr | append [""]
  }

  # -------------------------------------------------------------------------
  # Openings section (top 5)
  # -------------------------------------------------------------------------
  let openings_section = if ($openings_data | is-empty) {
    ["## Openings", "", "_Run `generate-reports 2` to populate._", ""]
  } else {
    let total_open = ($openings_data | length)
    let top_n = if $total_open < 5 { $total_open } else { 5 }
    let top5  = ($openings_data | first $top_n)
    let th = "| Opening | ECO | Games | Win% |"
    let ts = "|---------|-----|-------|------|"
    let tr = ($top5 | each { |r|
      let on = if ($r.opening_name | is-empty) { "_Unknown_" } else { $r.opening_name }
      let oe = if ($r.eco_code | is-empty) { "—" } else { $r.eco_code }
      $"| ($on) | ($oe) | ($r.me_occurrences) | ($r.win_pct)% |"
    })
    ["## Openings", "", "_Top 5 most frequent positions._", "", $th, $ts] | append $tr | append [""]
  }

  # -------------------------------------------------------------------------
  # Position profile section
  # -------------------------------------------------------------------------
  let profile_section = if ($profiles_data | is-empty) {
    ["## Position Profile", "", "_Run `generate-reports 3` to populate (requires critter evals)._", ""]
  } else {
    let total    = ($profiles_data | length)
    let open_n   = ($profiles_data | where openness  == "Open"      | length)
    let closed_n = ($profiles_data | where openness  == "Closed"    | length)
    let tact_n   = ($profiles_data | where character == "Tactical"  | length)
    let strat_n  = ($profiles_data | where character == "Strategic" | length)
    let dyn_n    = ($profiles_data | where tempo     == "Dynamic"   | length)
    let pos_n    = ($profiles_data | where tempo     == "Positional"| length)
    let row1 = (profile-axis-row "Open / Closed"       "Open"     $open_n  "Closed"    $closed_n $total)
    let row2 = (profile-axis-row "Tactical / Strategic" "Tactical" $tact_n  "Strategic" $strat_n  $total)
    let row3 = (profile-axis-row "Dynamic / Positional" "Dynamic"  $dyn_n   "Positional" $pos_n   $total)
    [
      "## Position Profile", "",
      $"_Based on ($total) critter-evaluated positions._", "",
      "| Axis | Breakdown | Majority % |",
      "|------|-----------|------------|",
      $row1, $row2, $row3, ""
    ]
  }

  # -------------------------------------------------------------------------
  # Insights — auto-generated strengths and weaknesses
  # -------------------------------------------------------------------------
  mut strengths  = []
  mut weaknesses = []

  if not ($color_data | is-empty) {
    let wr = ($color_data | where color == "white")
    let br = ($color_data | where color == "black")
    if not ($wr | is-empty) and not ($br | is-empty) {
      let ww = ($wr | first | get win_pct)
      let bw = ($br | first | get win_pct)
      if $ww > ($bw + 10.0) {
        $strengths = ($strengths | append $"Strong as White: ($ww)% win rate (vs ($bw)% as Black)")
      } else if $bw > ($ww + 10.0) {
        $strengths = ($strengths | append $"Strong as Black: ($bw)% win rate (vs ($ww)% as White)")
      }
      if $ww < 40.0 {
        $weaknesses = ($weaknesses | append $"White results need work: ($ww)% win rate")
      }
      if $bw < 40.0 {
        $weaknesses = ($weaknesses | append $"Black results need work: ($bw)% win rate")
      }
    }
  }

  if not ($bands_data | is-empty) {
    let higher_r = ($bands_data | where band == "higher_rated")
    let lower_r  = ($bands_data | where band == "lower_rated")
    if not ($higher_r | is-empty) {
      let hw = ($higher_r | first | get win_pct)
      if $hw >= 40.0 {
        $strengths  = ($strengths  | append $"Solid vs higher-rated opponents: ($hw)% win rate")
      } else {
        $weaknesses = ($weaknesses | append $"Struggles vs higher-rated opponents: ($hw)% win rate")
      }
    }
    if not ($lower_r | is-empty) {
      let lw = ($lower_r | first | get win_pct)
      if $lw >= 70.0 {
        $strengths = ($strengths | append $"Dominates lower-rated opponents: ($lw)% win rate")
      }
    }
  }

  if not ($wins_data | is-empty) {
    let tw = ($wins_data | first)
    let wn = if ($tw.opening_name | is-empty) { "an unclassified position" } else { $tw.opening_name }
    $strengths = ($strengths | append $"Most reliable win position: ($wn) — ($tw.me_wins) wins in ($tw.me_occurrences) games")
  }

  if not ($losses_data | is-empty) {
    let tl = ($losses_data | first)
    let ln = if ($tl.opening_name | is-empty) { "an unclassified position" } else { $tl.opening_name }
    $weaknesses = ($weaknesses | append $"Recurring losses at: ($ln) — ($tl.me_losses) losses in ($tl.me_occurrences) games")
  }

  let sw_section = if ($strengths | is-empty) and ($weaknesses | is-empty) {
    ["## Insights", "", "_Not enough data for automated insights._", ""]
  } else {
    mut sw = ["## Insights", ""]
    if not ($strengths | is-empty) {
      $sw = ($sw | append "**Strengths:**")
      $sw = ($sw | append ($strengths | each { |s| $"- ($s)" }))
      $sw = ($sw | append "")
    }
    if not ($weaknesses | is-empty) {
      $sw = ($sw | append "**Areas to improve:**")
      $sw = ($sw | append ($weaknesses | each { |w| $"- ($w)" }))
      $sw = ($sw | append "")
    }
    $sw
  }

  # -------------------------------------------------------------------------
  # Assemble and save
  # -------------------------------------------------------------------------
  let header = [
    "# Playstyle Summary", "",
    $"_Generated ($generated) — ($loaded) of 7 cache sources loaded_",
    "_Sources: color, rating-bands, time-control, openings, loss-positions, win-positions, profiles_",
    ""
  ]

  $header
  | append $glance_section
  | append $color_section
  | append $bands_section
  | append $tc_section
  | append $openings_section
  | append $profile_section
  | append $sw_section
  | str join "\n"
  | save --force $report_path

  { status: "ok", path: $report_path, sources_loaded: $loaded }
}

# ---------------------------------------------------------------------------
# Top-level dispatcher
# ---------------------------------------------------------------------------

# Generate player introspection reports.
#   phase 1 (default): color-performance, rating-bands, time-control
#   phase 2: opening-repertoire, frequent-losses, frequent-wins
#   phase 3: position-profiles (requires critter evals)
#   phase 4: playstyle-summary (synthesises all caches from phases 1-3)
# Writes .md files to ./reports/ and .nuon caches to ./reports/.cache/
export def generate-reports [phase: int = 1] {
  match $phase {
    1 => {
      let r1 = (generate-color-performance)
      let r2 = (generate-rating-bands)
      let r3 = (generate-time-control)
      { phase: 1, reports: [$r1, $r2, $r3] }
    }
    2 => {
      let r1 = (generate-opening-repertoire)
      let r2 = (generate-frequent-losses)
      let r3 = (generate-frequent-wins)
      { phase: 2, reports: [$r1, $r2, $r3] }
    }
    3 => {
      let r1 = (generate-position-profiles)
      { phase: 3, reports: [$r1] }
    }
    4 => {
      let r1 = (generate-playstyle-summary)
      { phase: 4, reports: [$r1] }
    }
    _ => {
      error make { msg: $"Phase ($phase) not yet implemented. Available phases: 1, 2, 3, 4" }
    }
  }
}
