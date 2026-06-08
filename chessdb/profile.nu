# Coaching profile commands.
# Internal KPI helpers are private (def, not export def).
# Public surface: chess-profile, chess-profile-tactical, chess-profile-precision,
#                 chess-profile-position, chess-profile-opening.

# ── Internal pivot helper ─────────────────────────────────────────────────────

def win-rate-pivot [] {
    let rows = $in
    $rows | get concept | uniq | each { |c|
        let r    = ($rows | where concept == $c)
        let cell = { |who flag|
            let m = ($r | where who == $who | where present == $flag).0?
            { games: ($m.games? | default 0), win_pct: $m.win_pct? }
        }
        {
            concept:                $c
            player_has_pattern:     (do $cell "player"   1)
            player_lacks_pattern:   (do $cell "player"   0)
            opponent_has_pattern:   (do $cell "opponent" 1)
            opponent_lacks_pattern: (do $cell "opponent" 0)
        }
    }
}

# ── Profile KPI helpers ───────────────────────────────────────────────────────

def "profile-wdl" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT color, COUNT(*) as games,
               SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) as wins,
               SUM(CASE WHEN result IN ('agreed','repetition','stalemate','insufficient','timevsinsufficient','50move') THEN 1 ELSE 0 END) as draws,
               SUM(CASE WHEN result NOT IN ('win','agreed','repetition','stalemate','insufficient','timevsinsufficient','50move') THEN 1 ELSE 0 END) as losses,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct,
               ROUND(100.0 * SUM(CASE WHEN result IN ('agreed','repetition','stalemate','insufficient','timevsinsufficient','50move') THEN 1 ELSE 0 END) / COUNT(*), 1) as draw_pct
        FROM (
            SELECT 'white' as color, result FROM games WHERE white = ?
            UNION ALL
            SELECT 'black' as color, result FROM games WHERE black = ?
        ) GROUP BY color
    " --params [$username, $username]
}

def "profile-phase-stats" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT m.color,
            CASE WHEN m.ply <= 12 THEN 'opening'
                 WHEN m.ply <= 30 THEN 'midgame'
                 WHEN m.ply <= 50 THEN 'late_mid'
                 ELSE 'endgame' END as phase,
            COUNT(*) as n,
            ROUND(AVG(CASE WHEN m.color='white' THEN p.hugm_score ELSE -p.hugm_score END), 0) as avg_score_cp,
            ROUND(AVG(ABS(p.hugm_score)), 0) as avg_abs_material
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        JOIN games g ON m.game_id = g.game_id
        WHERE (m.color = 'white' AND g.white = ?) OR (m.color = 'black' AND g.black = ?)
        GROUP BY m.color, phase
        ORDER BY m.color,
            CASE phase WHEN 'opening' THEN 1 WHEN 'midgame' THEN 2 WHEN 'late_mid' THEN 3 ELSE 4 END
    " --params [$username, $username]
}

def "profile-concepts" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT concept_name as concept,
               COUNT(*) as occurrences,
               SUM(hurt_player) as hurt_count,
               ROUND(AVG(CAST(hurt_player AS REAL)), 3) as hurt_rate,
               ROUND(AVG(severity), 0) as avg_severity
        FROM move_anomalies
        WHERE username = ? AND concept_name != 'hugm_delta'
        GROUP BY concept_name
        ORDER BY occurrences DESC
    " --params [$username]
}

def "profile-worst-moments" [username: string --db: string = "./chess.db"] {
    open $db | query db "
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
        ORDER BY severity_cp DESC
    " --params [$username]
    | update game_id      { into string }
    | update severity_cp  { into int }
    | upsert signed_delta { default 0 | into int }
    | upsert hurt_player  { default 0 | into bool }
    | upsert king_involved { default 0 | into bool }
}

def "profile-mate-analysis" [username: string --db: string = "./chess.db"] {
    open $db | query db "
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
    " --params [$username, $username, $username, $username]
}

def "concept-examples" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT ma.concept_name as concept, ma.game_id, ma.ply,
               ROUND(MAX(ma.z_score), 2) as z_score,
               ROUND(MAX(ma.severity), 0) as severity_cp
        FROM move_anomalies ma
        WHERE ma.username = ? AND ma.consumed = 0
          AND ma.concept_name != 'hugm_delta'
        GROUP BY ma.concept_name, ma.game_id, ma.ply
        ORDER BY ma.concept_name, severity_cp DESC
    " --params [$username]
    | update game_id { into string }
    | update z_score { math round --precision 2 }
}

# ── Tactical KPI helpers ──────────────────────────────────────────────────────

def "tactical-concepts" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT concept_name,
               COUNT(*) as anomalies,
               SUM(hurt_player) as hurt_count,
               ROUND(AVG(CAST(hurt_player AS REAL)), 3) as hurt_rate,
               ROUND(AVG(z_score), 2) as avg_z,
               ROUND(MAX(severity), 0) as peak_severity_cp
        FROM move_anomalies
        WHERE username = ? AND concept_name IN ('fork', 'pin', 'hanging_piece', 'skewer', 'discovered_attack')
        GROUP BY concept_name
        ORDER BY hurt_count DESC
    " --params [$username]
}

def "tactical-phase-breakdown" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT ms.phase_bucket,
               CASE ms.phase_bucket WHEN 0 THEN 'deep_endgame' WHEN 1 THEN 'endgame'
                                    WHEN 2 THEN 'midgame'      ELSE 'opening' END as phase_label,
               ma.concept_name, COUNT(*) as cnt,
               ROUND(AVG(CAST(ma.hurt_player AS REAL)), 3) as hurt_rate,
               ROUND(AVG(ma.z_score), 2) as avg_z
        FROM move_anomalies ma
        JOIN move_states ms ON ms.game_id = ma.game_id AND ms.ply = ma.ply
        WHERE ma.username = ? AND ma.concept_name IN ('fork', 'pin', 'hanging_piece', 'skewer', 'discovered_attack')
        GROUP BY ms.phase_bucket, ma.concept_name
        ORDER BY ms.phase_bucket, hurt_rate DESC
    " --params [$username]
}

def "tactical-win-impact" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        WITH player_flags AS (
            SELECT ms.game_id,
                   MAX((ms.state_id >> 7) & 1) as had_fork,
                   MAX((ms.state_id >> 8) & 1) as had_pin,
                   MAX((ms.state_id >> 9) & 1) as had_hanging
            FROM move_states ms
            JOIN moves m ON m.game_id = ms.game_id AND m.ply = ms.ply
            JOIN games g ON g.game_id = ms.game_id
            WHERE (g.white = ? AND m.color = 'white') OR (g.black = ? AND m.color = 'black')
            GROUP BY ms.game_id
        ),
        opp_flags AS (
            SELECT ms.game_id,
                   MAX((ms.state_id >> 7) & 1) as had_fork,
                   MAX((ms.state_id >> 8) & 1) as had_pin,
                   MAX((ms.state_id >> 9) & 1) as had_hanging
            FROM move_states ms
            JOIN moves m ON m.game_id = ms.game_id AND m.ply = ms.ply
            JOIN games g ON g.game_id = ms.game_id
            WHERE (g.white = ? AND m.color = 'black') OR (g.black = ? AND m.color = 'white')
            GROUP BY ms.game_id
        ),
        player_games AS (
            SELECT game_id, result FROM games WHERE white = ? OR black = ?
        )
        SELECT concept, who, present, COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct
        FROM (
            SELECT 'fork'          as concept, 'player'   as who, pf.had_fork    as present, pg.result FROM player_flags pf JOIN player_games pg ON pg.game_id = pf.game_id
            UNION ALL
            SELECT 'pin',                       'player',          pf.had_pin,                 pg.result FROM player_flags pf JOIN player_games pg ON pg.game_id = pf.game_id
            UNION ALL
            SELECT 'hanging_piece',             'player',          pf.had_hanging,             pg.result FROM player_flags pf JOIN player_games pg ON pg.game_id = pf.game_id
            UNION ALL
            SELECT 'fork',                      'opponent',        of.had_fork,                pg.result FROM opp_flags of JOIN player_games pg ON pg.game_id = of.game_id
            UNION ALL
            SELECT 'pin',                       'opponent',        of.had_pin,                 pg.result FROM opp_flags of JOIN player_games pg ON pg.game_id = of.game_id
            UNION ALL
            SELECT 'hanging_piece',             'opponent',        of.had_hanging,             pg.result FROM opp_flags of JOIN player_games pg ON pg.game_id = of.game_id
        )
        GROUP BY concept, who, present
        ORDER BY concept, who, present
    " --params [$username, $username, $username, $username, $username, $username]
    | win-rate-pivot
}

def "tactical-worst-games" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT ma.game_id,
               SUM(CASE WHEN ma.hurt_player = 1 THEN 1 ELSE 0 END) as hurt_moves,
               COUNT(*) as total_anomalies,
               ROUND(MAX(ma.z_score), 2) as peak_z,
               ROUND(MAX(ma.severity), 0) as peak_severity_cp,
               GROUP_CONCAT(DISTINCT ma.concept_name) as concepts
        FROM move_anomalies ma
        WHERE ma.username = ?
          AND ma.concept_name IN ('fork', 'pin', 'hanging_piece', 'skewer', 'discovered_attack')
          AND ma.consumed = 0
        GROUP BY ma.game_id
        HAVING hurt_moves > 0
        ORDER BY hurt_moves DESC, peak_z DESC
    " --params [$username]
}

# ── Precision KPI helpers ─────────────────────────────────────────────────────

def "precision-baselines" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT phase_bucket,
               CASE phase_bucket WHEN 0 THEN 'deep_endgame' WHEN 1 THEN 'endgame'
                                 WHEN 2 THEN 'midgame'      ELSE 'opening' END as phase_label,
               mean, std
        FROM player_baselines
        WHERE username = ? AND concept_name = 'hugm_delta'
        ORDER BY phase_bucket
    " --params [$username]
}

def "precision-severity" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT
            CASE
                WHEN z_score < 3.0 THEN 'borderline (z 2-3)'
                WHEN z_score < 4.0 THEN 'notable (z 3-4)'
                WHEN z_score < 5.0 THEN 'major (z 4-5)'
                ELSE 'extreme (z 5+)'
            END as tier,
            COUNT(*) as cnt,
            ROUND(AVG(CAST(hurt_player AS REAL)), 3) as hurt_rate,
            ROUND(AVG(severity), 0) as avg_severity_cp
        FROM move_anomalies
        WHERE username = ? AND concept_name = 'hugm_delta'
        GROUP BY tier
        ORDER BY MIN(z_score)
    " --params [$username]
}

def "precision-blunder-phases" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT ms.phase_bucket,
               CASE ms.phase_bucket WHEN 0 THEN 'deep_endgame' WHEN 1 THEN 'endgame'
                                    WHEN 2 THEN 'midgame'      ELSE 'opening' END as phase_label,
               COUNT(*) as hurt_moves,
               COUNT(DISTINCT ma.game_id) as games_with_blunder,
               ROUND(AVG(ma.severity), 0) as avg_severity_cp,
               ROUND(MAX(ma.severity), 0) as max_severity_cp
        FROM move_anomalies ma
        JOIN move_states ms ON ms.game_id = ma.game_id AND ms.ply = ma.ply
        WHERE ma.username = ? AND ma.hurt_player = 1 AND ma.severity > 150
        GROUP BY ms.phase_bucket
        ORDER BY ms.phase_bucket
    " --params [$username]
}

def "precision-risky-transitions" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT state_from, state_to, total_count, blunder_count,
               ROUND(blunder_risk, 3) as blunder_risk
        FROM transition_events
        WHERE username = ? AND blunder_risk > 0.15 AND total_count >= 3
        ORDER BY blunder_risk DESC
    " --params [$username]
}

def "precision-top-anomalies" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT game_id, ply, concept_name,
               ROUND(z_score, 2) as z_score,
               ROUND(severity, 0) as severity_cp,
               hurt_player
        FROM move_anomalies
        WHERE username = ? AND consumed = 0
        ORDER BY z_score DESC
    " --params [$username]
}

# ── Positional KPI helpers ────────────────────────────────────────────────────

def "position-eval-components" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT m.color,
            CASE WHEN m.ply <= 12 THEN 'opening'
                 WHEN m.ply <= 30 THEN 'midgame'
                 WHEN m.ply <= 50 THEN 'late_mid'
                 ELSE 'endgame' END as phase_label,
            COUNT(*) as n,
            ROUND(AVG(CAST(json_extract(p.hugm_eval_arr, '\$[1]') AS REAL)), 1) as avg_pawns_cp,
            ROUND(AVG(CAST(json_extract(p.hugm_eval_arr, '\$[2]') AS REAL)), 1) as avg_activity_cp,
            ROUND(AVG(CAST(
                CASE WHEN m.color = 'white' THEN  json_extract(p.hugm_eval_arr, '\$[3]')
                     ELSE                        -json_extract(p.hugm_eval_arr, '\$[3]') END
            AS REAL)), 1) as avg_king_safety_cp
        FROM moves m
        JOIN positions p ON m.next_position_id = p.zobrist
        JOIN games g ON m.game_id = g.game_id
        WHERE (m.color = 'white' AND g.white = ?) OR (m.color = 'black' AND g.black = ?)
        GROUP BY m.color, phase_label
        ORDER BY m.color, phase_label
    " --params [$username, $username]
}

def "position-win-rates" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        WITH player_games AS (
            SELECT g.game_id, g.result,
                   CASE WHEN g.white = ? THEN 'white' ELSE 'black' END as player_color
            FROM games g WHERE g.white = ? OR g.black = ?
        ),
        game_flags AS (
            SELECT ms.game_id,
                   MAX((ms.state_id >> 10) & 1) as had_outpost,
                   MAX((ms.state_id >> 11) & 1) as had_open_file,
                   MAX((ms.state_id >> 12) & 1) as had_passed_pawn,
                   MAX(CASE WHEN m.color = pg.player_color THEN (ms.state_id >> 5) & 1 ELSE 0 END) as had_king_exposed
            FROM move_states ms
            JOIN moves m ON m.game_id = ms.game_id AND m.ply = ms.ply
            JOIN player_games pg ON pg.game_id = ms.game_id
            GROUP BY ms.game_id
        )
        SELECT concept, present, COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct
        FROM (
            SELECT 'outpost'      as concept, gf.had_outpost      as present, pg.result FROM game_flags gf JOIN player_games pg ON pg.game_id = gf.game_id
            UNION ALL
            SELECT 'open_file',              gf.had_open_file,      pg.result           FROM game_flags gf JOIN player_games pg ON pg.game_id = gf.game_id
            UNION ALL
            SELECT 'passed_pawn',            gf.had_passed_pawn,    pg.result           FROM game_flags gf JOIN player_games pg ON pg.game_id = gf.game_id
            UNION ALL
            SELECT 'king_exposed',           gf.had_king_exposed,   pg.result           FROM game_flags gf JOIN player_games pg ON pg.game_id = gf.game_id
        )
        GROUP BY concept, present
        ORDER BY concept, present
    " --params [$username, $username, $username]
}

def "position-anomalies" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT concept_name, COUNT(*) as anomalies,
               ROUND(AVG(CAST(hurt_player AS REAL)), 3) as hurt_rate,
               ROUND(AVG(z_score), 2) as avg_z
        FROM move_anomalies
        WHERE username = ?
          AND concept_name IN ('outpost', 'open_file', 'passed_pawn', 'king_exposed')
        GROUP BY concept_name
        ORDER BY anomalies DESC
    " --params [$username]
}

# ── Opening KPI helpers ───────────────────────────────────────────────────────

def "opening-repertoire" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT CASE WHEN white = ? THEN 'white' ELSE 'black' END as color,
               eco, opening, COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct,
               ROUND(100.0 * SUM(CASE WHEN result IN ('agreed','repetition','stalemate','insufficient','timevsinsufficient','50move') THEN 1 ELSE 0 END) / COUNT(*), 1) as draw_pct
        FROM games WHERE white = ? OR black = ?
        GROUP BY eco, color
        ORDER BY games DESC
    " --params [$username, $username, $username]
}

def "opening-eco-families" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT SUBSTR(eco, 1, 1) as eco_family,
               CASE SUBSTR(eco, 1, 1)
                 WHEN 'A' THEN 'flank'    WHEN 'B' THEN 'semi_open'
                 WHEN 'C' THEN 'open'     WHEN 'D' THEN 'closed'
                 WHEN 'E' THEN 'indian'   ELSE 'other' END as family_name,
               COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct
        FROM games WHERE white = ? OR black = ?
        GROUP BY eco_family ORDER BY games DESC
    " --params [$username, $username]
}

def "opening-weakest" [username: string --db: string = "./chess.db" --min-games: int = 10] {
    open $db | query db "
        SELECT eco, opening,
               CASE WHEN white = ? THEN 'white' ELSE 'black' END as color,
               COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct
        FROM games WHERE white = ? OR black = ?
        GROUP BY eco, color HAVING games >= ?
        ORDER BY win_pct ASC
    " --params [$username, $username, $username, $min_games]
}

def "opening-strongest" [username: string --db: string = "./chess.db" --min-games: int = 10] {
    open $db | query db "
        SELECT eco, opening,
               CASE WHEN white = ? THEN 'white' ELSE 'black' END as color,
               COUNT(*) as games,
               ROUND(100.0 * SUM(CASE WHEN result = 'win' THEN 1 ELSE 0 END) / COUNT(*), 1) as win_pct
        FROM games WHERE white = ? OR black = ?
        GROUP BY eco, color HAVING games >= ?
        ORDER BY win_pct DESC
    " --params [$username, $username, $username, $min_games]
}

def "opening-anomalies" [username: string --db: string = "./chess.db"] {
    open $db | query db "
        SELECT g.eco, g.opening,
               COUNT(*) as anomalies,
               COUNT(DISTINCT g.game_id) as games_affected,
               ROUND(AVG(ma.z_score), 2) as avg_z,
               ROUND(AVG(CAST(ma.hurt_player AS REAL)), 3) as hurt_rate
        FROM move_anomalies ma
        JOIN games g ON g.game_id = ma.game_id
        WHERE ma.username = ? AND ma.concept_name = 'hugm_delta'
        GROUP BY g.eco HAVING games_affected >= 3
        ORDER BY hurt_rate DESC
    " --params [$username]
}

# ── Public profile commands ───────────────────────────────────────────────────

# Comprehensive one-shot coaching profile. Pipe to `to json -r` for LLM consumption.
export def "chess-profile" [
    username: string
    --db: string = "./chess.db"
    --hurt-threshold: int = 1000
] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }

    let game_count = (open $db | query db "
        SELECT COUNT(DISTINCT m.game_id) as cnt
        FROM moves m JOIN games g ON m.game_id = g.game_id
        WHERE g.white = ? OR g.black = ?
    " --params [$username, $username]).0.cnt | into int

    let hurt_count = (open $db | query db "
        SELECT COUNT(*) as cnt FROM move_anomalies
        WHERE username = ? AND consumed = 0 AND hurt_player = 1
    " --params [$username]).0.cnt | into int

    let blunder_count = (open $db | query db "
        SELECT COUNT(*) as cnt FROM move_anomalies
        WHERE username = ? AND consumed = 0 AND hurt_player = 1 AND severity >= ?
    " --params [$username, $hurt_threshold]).0.cnt | into int

    let anomaly_count = (open $db | query db "
        SELECT COUNT(*) as cnt FROM move_anomalies WHERE username = ? AND consumed = 0
    " --params [$username]).0.cnt | into int

    {
        player:                   $username
        games:                    $game_count
        unreviewed_anomalies:     $anomaly_count
        hurt_anomalies_per_game:  (if $game_count > 0 { ($hurt_count | into float) / $game_count | math round --precision 2 } else { 0.0 })
        blunders_per_game:        (if $game_count > 0 { ($blunder_count | into float) / $game_count | math round --precision 2 } else { 0.0 })
        hurt_threshold:           $hurt_threshold
        "profile-wdl":              (profile-wdl              $username --db $db)
        "profile-phase-stats":      (profile-phase-stats      $username --db $db)
        "position-eval-components": (position-eval-components $username --db $db)
        "profile-concepts":         (profile-concepts         $username --db $db)
        "profile-worst-moments":    (profile-worst-moments    $username --db $db | first 5)
        "profile-mate-analysis":    (profile-mate-analysis    $username --db $db)
        "concept-examples":         (concept-examples $username --db $db | sort-by z_score --reverse | first 10)
    }
}

# Tactical drill-down: fork/pin/hanging by phase with win-rate correlation.
export def "chess-profile-tactical" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    {
        player:                     $username
        "tactical-concepts":        (tactical-concepts       $username --db $db)
        "tactical-phase-breakdown": (tactical-phase-breakdown $username --db $db)
        "tactical-win-impact":      (tactical-win-impact     $username --db $db)
        "tactical-worst-games":     (tactical-worst-games    $username --db $db)
    }
}

# Precision drill-down: eval-swing baselines, blunder distribution, top anomalies.
export def "chess-profile-precision" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    {
        player:                        $username
        "precision-baselines":         (precision-baselines         $username --db $db)
        "precision-severity":          (precision-severity          $username --db $db)
        "precision-blunder-phases":    (precision-blunder-phases    $username --db $db)
        "precision-risky-transitions": (precision-risky-transitions $username --db $db)
        "precision-top-anomalies":     (precision-top-anomalies     $username --db $db)
    }
}

# Positional drill-down: eval components by phase/color, win rates with positional features.
export def "chess-profile-position" [username: string --db: string = "./chess.db"] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    {
        player:                     $username
        "position-eval-components": (position-eval-components $username --db $db)
        "position-win-rates":       (position-win-rates       $username --db $db)
        "position-anomalies":       (position-anomalies       $username --db $db)
    }
}

# Opening drill-down: ECO repertoire, family win rates, weakest/strongest openings.
export def "chess-profile-opening" [
    username: string
    --db: string = "./chess.db"
    --min-games: int = 10
] {
    if not ($db | path exists) { error make {msg: $"Database not found: ($db)"} }
    {
        player:                 $username
        "opening-repertoire":   (opening-repertoire   $username --db $db)
        "opening-eco-families": (opening-eco-families $username --db $db)
        "opening-weakest":      (opening-weakest      $username --db $db --min-games $min_games)
        "opening-strongest":    (opening-strongest    $username --db $db --min-games $min_games)
        "opening-anomalies":    (opening-anomalies    $username --db $db)
    }
}
