use ./config.nu *
use ./db.nu *
use ./eco.nu *

# Export a RAG-compatible corpus of positions with structural vectors.
export def export-corpus [output_path: string = "corpus.msgpack"] {
    let cfg = load-config
    let db_path = $cfg.database.path

    print $"Exporting corpus from ($db_path)..."

        # 1. Get positions joined with critter evals
    let rows = (open $db_path | query db "
        SELECT 
            p.id, 
            p.canonical_fen, 
            p.canonical_hash,
            e.final_score,
            e.material_json,
            e.king_safety_json,
            e.piece_activity_json,
            e.analysis_json
        FROM positions p
        JOIN position_critter_evals e ON p.id = e.position_id
    ")

    if ($rows | is-empty) {
        error make {msg: "No evaluated positions found. Run critter-eval-queue first."}
    }

    # 2. Enrich and Vectorize
    let corpus = ($rows | each { |row|
        print $"Processing ($row.canonical_fen)..."
        
        # Get structural vector from plugin
        let vector = ($row.canonical_fen | chessdb encode-fen)
        
        # Get ECO classification
        let eco = ([$row] | eco-classify | first)
        
        {
            id: $row.id
            fen: $row.canonical_fen
            hash: $row.canonical_hash
            chess_embedding: $vector
            metadata: {
                score: $row.final_score
                opening: $eco.opening_name
                eco: $eco.eco_code
                # Add high-level critter summary
                summary: (summarize-critter $row)
            }
        }
    })

    # 3. Save as msgpack for nu_plugin_rag
    $corpus | to msgpack | save --force $output_path
    print $"Corpus saved to ($output_path) with ($corpus | length) entries."
}

def summarize-critter [row: record] {
    let mat = ($row.material_json | from json | get -o blended | default 0)
    let safe = ($row.king_safety_json | from json | get -o blended | default 0)
    let act = ($row.piece_activity_json | from json | get -o blended | default 0)
    
    $"Material: ($mat), Safety: ($safe), Activity: ($act)"
}
