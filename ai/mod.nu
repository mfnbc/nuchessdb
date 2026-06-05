# Chess tools and prompts for ai.nu.
# Load after ai.nu so AI_STATE / AI_SESSION are initialised.
#
# export-env registers tool handlers into $env.AI_TOOLS and the two
# chess prompts into $env.AI_PROMPTS (in-memory; no DB write needed).
#
# Entry commands:
#   $question | chess analyst   — investigate with all chess tools
#   $json_pos | chess coach     — enrich a position record (Socratic Coach)
#
# Mirrors engine.nu: function.nu must be imported before base.nu in this
# file so that ai-send's reference to closure-list resolves at compile time.

use ../../ai.nu/ai/config.nu [ai-config-env-tools, ai-config-env-prompts]
export use ../../ai.nu/ai/function.nu [closure-list, closure-run]
use ../../ai.nu/ai/base.nu [ai-send]
use ../../ai.nu/ai/data.nu

const HERE = (path self | path dirname)

export-env {
    if ($env.AI_TOOLS? | is-empty) { $env.AI_TOOLS = {} }

    let db = ($HERE | path join ".." "chess.db")
    let nu_script = ($HERE | path join ".." "nuchessdb.nu")

    ai-config-env-tools "get_coach_profile" {
        schema: {
            description: "Return a comprehensive one-shot coaching profile for a player: win/loss/draw rates by color, phase performance in centipawns, eval component breakdown (pawns/activity/king-safety), most anomalous concepts, blunders-per-game, mate-in-1 conversion rate, and the top 5 worst unreviewed moves. Call this as the first step for any player-specific question."
            parameters: {
                type: "object"
                properties: {
                    username: { type: "string", description: "Player username exactly as stored in the database." }
                }
                required: ["username"]
            }
        }
        handler: {|args, _|
            let u = ($args.username? | default "")
            if $u == "" { return "tool error: requires `username`" }
            let r = (do { ^nu $nu_script coach-profile $u --db $db --json --examples 0 } | complete)
            if $r.exit_code != 0 { return $"tool error: ($r.stderr | str trim)" }
            $r.stdout | str trim
        }
    }

    ai-config-env-tools "get_tactical_profile" {
        schema: {
            description: "Return a focused tactical drill-down: anomaly counts and hurt rates for each tactical concept (fork, pin, hanging_piece, skewer, discovered_attack) broken down by phase, plus win-rate correlation for games where each pattern appeared. Use after get_coach_profile when tactical patterns show up as a weakness."
            parameters: {
                type: "object"
                properties: {
                    username: { type: "string", description: "Player username exactly as stored in the database." }
                }
                required: ["username"]
            }
        }
        handler: {|args, _|
            let u = ($args.username? | default "")
            if $u == "" { return "tool error: requires `username`" }
            let r = (do { ^nu $nu_script coach-profile-tactical $u --db $db } | complete)
            if $r.exit_code != 0 { return $"tool error: ($r.stderr | str trim)" }
            $r.stdout | str trim
        }
    }

    ai-config-env-tools "get_precision_profile" {
        schema: {
            description: "Return a focused precision drill-down: eval-swing baselines per phase (mean/std of |hugm_delta|), blunder frequency by phase, severity distribution, risky state transitions, and top anomalies by z_score. Use to investigate whether the player makes consistent mistakes or occasional catastrophic ones."
            parameters: {
                type: "object"
                properties: {
                    username: { type: "string", description: "Player username exactly as stored in the database." }
                }
                required: ["username"]
            }
        }
        handler: {|args, _|
            let u = ($args.username? | default "")
            if $u == "" { return "tool error: requires `username`" }
            let r = (do { ^nu $nu_script coach-profile-precision $u --db $db } | complete)
            if $r.exit_code != 0 { return $"tool error: ($r.stderr | str trim)" }
            $r.stdout | str trim
        }
    }

    ai-config-env-tools "get_positional_profile" {
        schema: {
            description: "Return a focused positional drill-down: avg eval components (pawns/activity/king-safety in cp) by phase and color, plus win-rate when positional advantages (outpost, open file, passed pawn) or weaknesses (king exposed) were present. Use to investigate positional patterns."
            parameters: {
                type: "object"
                properties: {
                    username: { type: "string", description: "Player username exactly as stored in the database." }
                }
                required: ["username"]
            }
        }
        handler: {|args, _|
            let u = ($args.username? | default "")
            if $u == "" { return "tool error: requires `username`" }
            let r = (do { ^nu $nu_script coach-profile-position $u --db $db } | complete)
            if $r.exit_code != 0 { return $"tool error: ($r.stderr | str trim)" }
            $r.stdout | str trim
        }
    }

    ai-config-env-tools "get_opening_profile" {
        schema: {
            description: "Return the player's opening repertoire: top ECOs by games played as white and black, ECO family win rates, weakest and strongest openings by win%, and which openings correlate with the most anomalies. Use to investigate repertoire gaps or opening-specific weaknesses."
            parameters: {
                type: "object"
                properties: {
                    username: { type: "string", description: "Player username exactly as stored in the database." }
                }
                required: ["username"]
            }
        }
        handler: {|args, _|
            let u = ($args.username? | default "")
            if $u == "" { return "tool error: requires `username`" }
            let r = (do { ^nu $nu_script coach-profile-opening $u --db $db } | complete)
            if $r.exit_code != 0 { return $"tool error: ($r.stderr | str trim)" }
            $r.stdout | str trim
        }
    }

    ai-config-env-tools "chess_db_schema" {
        schema: {
            description: "Return the CREATE TABLE DDL for every table in the chess database. Call this first to understand what data is available before writing any queries."
            parameters: {
                type: "object"
                properties: {}
                required: []
            }
        }
        handler: {|_, _|
            let tables = (open $db | query db "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE '_%' ORDER BY name")
            if ($tables | is-empty) { return "No tables found." }
            $tables | each { |t| $t.sql } | str join "\n\n"
        }
    }

    ai-config-env-tools "query_chess_db" {
        schema: {
            description: "Execute a read-only SELECT query against the chess database. Returns up to 100 rows as JSON. Use chess_db_schema first to learn the schema. Only SELECT statements are permitted."
            parameters: {
                type: "object"
                properties: {
                    sql: { type: "string", description: "A SQL SELECT statement." }
                    params: { type: "array", items: { type: "string" }, description: "Optional positional parameter values for ? placeholders." }
                }
                required: ["sql"]
            }
        }
        handler: {|args, _|
            let sql = ($args.sql? | default "" | str trim)
            if $sql == "" { return "tool error: requires `sql`" }
            if not ($sql | str downcase | str starts-with "select") {
                return "tool error: only SELECT statements are permitted"
            }
            let params = ($args.params? | default [])
            let results = try {
                if ($params | is-empty) {
                    open $db | query db $sql
                } else {
                    open $db | query db $sql --params $params
                }
            } catch { |e| return $"tool error: query failed — ($e.msg)" }
            if ($results | is-empty) { return "(no rows returned)" }
            let count = ($results | length)
            let body = ($results | first 100 | to json)
            if $count > 100 { $"($body)\n\n(showing first 100 of ($count) rows)" } else { $body }
        }
    }

    ai-config-env-prompts "chess-analyst" {
        system: "/no_think

Role: Chess Database Analyst
Identity: You help players discover patterns in their own games by querying a
personal chess database. You are data-driven, curious, and always ground your
observations in the actual numbers you find.

Database: A SQLite chess database built by nuchessdb. Use chess_db_schema to
learn the schema before writing any queries.

Key tables and their exact columns:
- games(game_id, source, white, black, white_elo, black_elo, result,
        played_at, time_control, eco, opening, source_game_id)
- moves(game_id, ply, move_number, color, san, uci,
        position_id, next_position_id, clock_seconds)
- positions(zobrist, fen, hugm_score, hugm_eval_arr, nnue_score,
            eval_depth, state_id, is_checkmate, mate_in_1)
  hugm_eval_arr is a JSON array: [material, pawns, activity, king_safety, ...]
- player_baselines(username, concept_name, phase_bucket, mean, std)
- move_anomalies(username, game_id, ply, state_id, anomaly_type,
                 concept_name, z_score, severity, signed_delta, hurt_player, consumed)
  NOTE: move_anomalies has NO phase_bucket column. To break anomalies by
  phase, JOIN with move_states on (game_id, ply):
    JOIN move_states ms ON ms.game_id = ma.game_id AND ms.ply = ma.ply
- move_states(game_id, ply, state_id, phase_bucket,
              has_fork, has_pin, has_hanging, king_exposed)
- transition_events(username, state_from, state_to,
                    total_count, blunder_count, blunder_risk)

IMPORTANT: move_anomalies links to a player via `username`, NOT via white/black/color.
To query anomalies for a player use: WHERE username = 'PlayerName'

Score convention: hugm_score is from White's perspective (positive = White ahead).
When analysing a specific player, flip the sign for Black moves.
Phase labels in baselines/anomalies are material-based: opening=25+ material, midgame=17-24, endgame=9-16, deep_endgame=0-8.
eval_components in get_positional_profile uses ply-based phases: opening=ply≤12, midgame≤30, late_mid≤50, endgame.

Workflow:
1. If you do not know who is in the database yet, run a quick discovery query:
     SELECT white AS player, COUNT(*) AS cnt FROM games GROUP BY white
     UNION ALL SELECT black, COUNT(*) FROM games GROUP BY black
     ORDER BY cnt DESC LIMIT 20
   Players with 300+ games are the account holders; the rest are opponents.
2. For any player-specific question, call get_coach_profile first.
3. Use focused sub-profile tools to drill into specific areas:
   - get_tactical_profile: fork/pin/hanging breakdown by phase, win rates
   - get_precision_profile: eval-swing baselines, blunder distribution, top anomalies
   - get_positional_profile: eval components by phase/color, win rates with positional features
   - get_opening_profile: ECO repertoire, family win rates, weakest/strongest openings
4. Write ad-hoc follow-up queries with query_chess_db for anything the sub-profiles
   do not cover. Do NOT group by float columns — group by categoricals.
5. chess_db_schema is available if you need to verify exact column names.

Useful query patterns:
  Weakest tactical concepts:
    SELECT ma.concept_name, COUNT(*) AS cnt,
           ROUND(AVG(CAST(ma.hurt_player AS REAL)), 3) AS hurt_rate
    FROM move_anomalies ma WHERE ma.username = 'PlayerName'
    GROUP BY ma.concept_name ORDER BY hurt_rate DESC LIMIT 10

  Phase breakdown (JOIN required — move_anomalies has no phase_bucket):
    SELECT ms.phase_bucket, ma.concept_name, COUNT(*) AS cnt,
           ROUND(AVG(CAST(ma.hurt_player AS REAL)), 3) AS hurt_rate
    FROM move_anomalies ma
    JOIN move_states ms ON ms.game_id = ma.game_id AND ms.ply = ma.ply
    WHERE ma.username = 'PlayerName'
    GROUP BY ms.phase_bucket, ma.concept_name ORDER BY hurt_rate DESC

Style:
- Be direct. One clear observation per paragraph.
- Use centipawn values (cp) when quoting eval numbers.
- Offer a follow-up query when the data raises a natural next question.
- Never fabricate data — only state what the queries actually returned.
- If a player is missing, tell the user to run:
    nu nuchessdb.nu sync <username>"
        template: "{{}}"
        placeholder: "[]"
        description: "Chess database analyst with query and profile tools"
    }

    ai-config-env-prompts "chess-coach" {
        system: "Role: Socratic Chess Coach
Identity: A patient, question-driven chess coach who helps players notice what
matters in their positions. You never lecture; you ask Socratic questions.

Input: A JSON record with detected concepts filtered by player ELO:
{
  \"fen\": \"r3kq2/ppp1np2/...\",
  \"player_elo\": 1400,
  \"concepts\": [{
    \"name\": \"fork\", \"severity\": 240, \"elo_min\": 1000, \"side\": \"white\",
    \"data\": {
      \"attacker\": {\"role\":\"Knight\",\"color\":\"white\",\"square\":\"d5\"},
      \"targets\": [{\"role\":\"Queen\",\"color\":\"black\",\"square\":\"f6\"},
                   {\"role\":\"Rook\",\"color\":\"black\",\"square\":\"b6\"}]
    }
  }],
  \"scores\": {\"material_cp\": 285, \"positional_cp\": -42, \"tactical_cp\": 80, \"total_cp\": 323}
}

Concepts are ranked by severity descending and already filtered to the player's ELO.

Philosophy:
1. Socratic method: Ask, don't tell. \"What do you notice about the knight?\" not \"The knight forks queen and rook.\"
2. ELO-appropriate language. Simple words for 800, master terms for 2000+.
3. One concept at a time. Pick the highest-severity concept.
4. Bridge to action: \"What would you play here?\"
5. Encourage calculation: \"Can you see a way to win material?\"

Output: Add these three fields to the JSON record:
- pgn_comment: One-line factual annotation for the game score.
- socratic_question: A single question guiding the player to notice the most important concept.
- lesson_point: 2-3 sentences on WHY this concept matters at their level.

Tone: Warm, professional. Use \"your\" perspective. Never say \"the engine says.\"
No concepts → comment on material balance. Check → acknowledge immediately."
        template: "{{}}"
        placeholder: "[]"
        description: "Socratic chess coach — enriches position records with coaching annotations"
    }
}

export def "chess analyst" [] {
    let s = data session
    let p = ($env.AI_PROMPTS | get chess-analyst)
    $in | ai-send -s $s --system $p.system --function [
        get_coach_profile get_tactical_profile get_precision_profile
        get_positional_profile get_opening_profile chess_db_schema query_chess_db
    ] --oneshot
    | get result.content
}

export def "chess coach" [] {
    let s = data session
    let p = ($env.AI_PROMPTS | get chess-coach)
    $in | to json -r | ai-send -s $s --system $p.system --oneshot
    | get result.content
}
