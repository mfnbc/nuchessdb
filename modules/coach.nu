use ./annotate.nu *
use ./rag_export.nu *
use ./export_pgn.nu *

# The main entry point for the Coach's Notebook.
# This command builds the corpus and reviews a specific game.
export def coach-review [game_id: int] {
    # 1. Ensure structural corpus is up to date
    export-corpus "data/corpus.msgpack"
    
    # 2. Perform move-by-move delta analysis and generate annotations
    review-game $game_id "data/corpus.msgpack"
    
    # 3. Display the results
    export-annotated-pgn $game_id
}
