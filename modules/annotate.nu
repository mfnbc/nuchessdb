use ./config.nu *
use ./db.nu *
use ./utils.nu *

# Calculate the decomposed score deltas for each move in a game.
# This joins game_positions with the critter evaluations of the positions before and after each move.
export def calculate-game-deltas [game_id: int] {
    let cfg = load-config
    let db_path = $cfg.database.path

    # Query to get moves and their associated critter evals
    let query = $"
        SELECT 
            gp.id as game_position_id,
            gp.ply,
            gp.move_san,
            gp.move_uci,
            gp.position_after_id,
            e_before.final_score as score_before,
            e_after.final_score as score_after,
            e_before.material_json as mat_before,
            e_after.material_json as mat_after,
            e_before.king_safety_json as safe_before,
            e_after.king_safety_json as safe_after,
            e_before.piece_activity_json as act_before,
            e_after.piece_activity_json as act_after,
            e_before.pawn_structure_json as pawn_before,
            e_after.pawn_structure_json as pawn_after,
            e_before.passed_pawns_json as pass_before,
            e_after.passed_pawns_json as pass_after,
            e_before.development_json as dev_before,
            e_after.development_json as dev_after
        FROM game_positions gp
        LEFT JOIN position_critter_evals e_before ON gp.position_before_id = e_before.position_id
        LEFT JOIN position_critter_evals e_after ON gp.position_after_id = e_after.position_id
        WHERE gp.game_id = ($game_id)
        ORDER BY gp.ply ASC
    "

    let rows = (open $db_path | query db $query)

    $rows | each { |row|
        let m_before = ($row.mat_before | from json | get -o blended | default 0)
        let m_after = ($row.mat_after | from json | get -o blended | default 0)
        
        let s_before = ($row.safe_before | from json | get -o blended | default 0)
        let s_after = ($row.safe_after | from json | get -o blended | default 0)

        let a_before = ($row.act_before | from json | get -o blended | default 0)
        let a_after = ($row.act_after | from json | get -o blended | default 0)

        let p_before = ($row.pawn_before | from json | get -o blended | default 0)
        let p_after = ($row.pawn_after | from json | get -o blended | default 0)

        let ps_before = ($row.pass_before | from json | get -o blended | default 0)
        let ps_after = ($row.pass_after | from json | get -o blended | default 0)

        let d_before = ($row.dev_before | from json | get -o blended | default 0)
        let d_after = ($row.dev_after | from json | get -o blended | default 0)

        # Total delta (absolute diff, we handle POV in the prompt/logic later)
        let total_delta = ($row.score_after - $row.score_before)
        
        {
            game_position_id: $row.game_position_id
            position_id: $row.position_after_id
            ply: $row.ply
            move: $row.move_san
            total_delta: $total_delta
            deltas: {
                material: ($m_after - $m_before)
                king_safety: ($s_after - $s_before)
                activity: ($a_after - $a_before)
                pawn_structure: ($p_after - $p_before)
                passed_pawns: ($ps_after - $ps_before)
                development: ($d_after - $d_before)
            }
        }
    }
}

# Review a game using Critter Deltas and RAG context.
export def review-game [game_id: int, corpus_path: string = "corpus.msgpack"] {
    let cfg = load-config
    let db_path = $cfg.database.path
    
    let deltas = (calculate-game-deltas $game_id)
    let corpus = (if ($corpus_path | path exists) { open $corpus_path } else { [] })

    for move in $deltas {
        let abs_delta = ($move.total_delta | math abs)
        
        # Only annotate significant moves (> 50 cp)
        if $abs_delta > 50 {
            print $"Reviewing move ($move.ply): ($move.move)..."
            
            # 1. Identify culprit
            let culprit = ($move.deltas | transpose key value | sort-by -r { |r| $r.value | math abs } | first)
            
            # 2. Get RAG neighbors for structural context
            let fen = (open $db_path | query db $"SELECT canonical_fen FROM positions WHERE id = ($move.position_id)").0.canonical_fen
            let vec = ($fen | chessdb encode-fen)
            # Similarity works on records with embedding fields.
            # We use --field chess_embedding to match our corpus.
            let neighbors = (if ($corpus | is-empty) { [] } else {
                $corpus | rag similarity --query $vec --k 3 --field chess_embedding
            })

            # 3. Construct prompt
            let prompt = (build-coach-prompt $move $culprit $neighbors)
            
            # 4. Call LLM (using nu-agent consult if available, else fallback)
            let comment = (if (which consult | is-not-empty) {
                # Pipe prompt to LLM agent
                $prompt | consult --model "gemini-3-flash" --system "You are a Grandmaster Chess Coach. Be concise."
            } else {
                # Fallback template
                $"[Coach] Your ($culprit.key) shifted significantly ($move.deltas | get $culprit.key | into string) cp. In similar positions ($neighbors | get -o metadata.opening | default ['unknown'] | str join ', '), players usually focus on structural integrity."
            })

            # 5. Save to annotations table
            let sql = [
                "INSERT INTO annotations (game_position_id, position_id, kind, source, content, created_at) "
                "VALUES ("
                ($move.game_position_id | into string) ","
                ($move.position_id | into string) ","
                "'coach', 'nu-agent',"
                (sql-string $comment) ","
                "datetime('now'))"
            ] | str join
            open $db_path | query db $sql
        }
    }
}

def build-coach-prompt [move, culprit, neighbors] {
    let neighbor_ctx = if ($neighbors | is-empty) {
        "No similar games found in your history."
    } else {
        let n_list = ($neighbors | each { |n| $"- ($n.metadata.opening) (Eval: ($n.metadata.score))" } | str join "\n")
        $"Similar structural themes in your history:\n($n_list)"
    }

    $"
    Analyze this chess move: ($move.move) (Ply ($move.ply)).
    The engine evaluation shifted by ($move.total_delta) centipawns.
    The primary driver was ($culprit.key) which changed by ($move.deltas | get $culprit.key).
    
    Context:
    ($neighbor_ctx)
    
    Provide a 1-2 sentence coaching tip focusing on the structural or strategic reason for this shift.
    "
}
