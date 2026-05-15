/// End-to-end ingest contract test.
/// Validates pgn_to_batch_record output matches what nuchessdb.nu merge query expects.
#[test]
fn ingest_contract_matches_merge_schema() {
    let pgn = "[Event \"Test\"]\n[Site \"?\"]\n[Date \"2024.01.01\"]\n[Round \"1\"]\n[White \"Alice\"]\n[Black \"Bob\"]\n[Result \"1-0\"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 1-0\n\n[Event \"Test2\"]\n[Site \"?\"]\n[Date \"2024.01.01\"]\n[Round \"2\"]\n[White \"Bob\"]\n[Black \"Alice\"]\n[Result \"1-0\"]\n\n1. d4 Nf6 2. c4 e6 3. Nc3 Bb4 1-0\n";

    let result = nu_plugin_chessdb::core::pgn_to_batch_record(pgn, nu_protocol::Span::test_data());
    let batch = result.expect("should parse multi-game PGN");

    assert!(!batch.games.is_empty(), "should produce games");
    assert!(!batch.unique_positions.is_empty(), "should produce unique positions");
    assert!(batch.positions.len() > 4, "should produce position records");

    let pos = &batch.unique_positions[0];
    assert!(!pos.zobrist.is_empty(), "must have zobrist");
    assert!(!pos.fen.is_empty(), "must have fen");

    let mov = &batch.positions[0];
    assert!(!mov.fen.is_empty(), "move must have fen");
    assert!(!mov.zobrist.is_empty(), "move must have zobrist");
    assert!(!mov.san.is_empty(), "move must have san");
    assert!(!mov.uci.is_empty(), "move must have uci");
    assert!(mov.ply > 0, "move must have ply > 0");

    let has_start = batch.unique_positions.iter().any(|p| p.fen.contains("rnbqkbnr/pppppppp"));
    assert!(has_start, "must include starting position");
}

#[test]
fn ingest_produces_sequential_indices() {
    let pgn = "[Event \"A\"]\n[White \"A\"]\n[Black \"B\"]\n[Result \"1-0\"]\n\n1. e4 e5 2. Nf3 Nc6 1-0\n\n[Event \"B\"]\n[White \"B\"]\n[Black \"A\"]\n[Result \"1-0\"]\n\n1. d4 Nf6 2. c4 g6 1-0\n";
    let batch = nu_plugin_chessdb::core::pgn_to_batch_record(pgn, nu_protocol::Span::test_data()).expect("should parse");
    let indices: Vec<u32> = batch.games.iter().map(|g| g.game_index).collect();
    assert_eq!(indices, vec![0, 1], "game indices sequential");
}

#[test]
fn ingest_empty_payload_no_error() {
    let result = nu_plugin_chessdb::core::pgn_to_batch_record("[Event \"X\"]\n[Result \"*\"]\n\n*", nu_protocol::Span::test_data());
    assert!(result.is_ok(), "empty game should not error");
}
