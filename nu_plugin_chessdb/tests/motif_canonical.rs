// Canonical motif examples for HUGM validation
// Sources:
// - chessprogramming.org (tactical/positional motif pages)
// - Wikipedia: Positional play / pawn structures (examples adapted)
// - Lichess public puzzles / study examples (representative)

use nu_plugin_chessdb::eval::{analyze_fen};

#[test]
fn wikipedia_pawn_break_detected() {
    // Source: Wikipedia / positional play (example adapted)
    // White pawn on c4 with no opposing pawns ahead should show a pawn-break opportunity c4->c5
    let fen = "4k3/8/8/8/2P5/8/8/4K3 w - - 0 1";
    let rec = analyze_fen(fen).expect("FEN should parse");
    let pb = rec
        .groups
        .pawn_structure
        .terms
        .get("pawn_breaks")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    assert!(pb >= 1, "expected at least one pawn break opportunity");
    // structured example present when verbose; we still expect the plural array in terms when generated
}

#[test]
fn chessprogramming_minority_example() {
    // Source: chessprogramming.org / pawn majority discussion (adapted)
    // White has queenside majority (a2,b2,c2) vs Black (a7,b7,c6)
    let fen = "4k3/pp6/8/8/8/8/PPP5/4K3 w - - 0 1";
    let rec = analyze_fen(fen).expect("FEN should parse");
    let minority = rec
        .groups
        .pawn_structure
        .terms
        .get("minority_attack")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    let strength = rec
        .groups
        .pawn_structure
        .terms
        .get("minority_attack_strength")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    assert!(minority == 1 || strength > 0, "expected minority attack signal");
}

#[test]
fn lichess_outpost_example() {
    // Source: Lichess / typical outpost positions (adapted)
    // White knight on d5 supported by pawn on c4; no black pawn attacks d5
    let fen = "k7/8/8/3N4/2P5/8/8/4K3 w - - 0 1";
    let rec = analyze_fen(fen).expect("FEN should parse");
    let outposts = rec
        .groups
        .piece_activity
        .terms
        .get("outposts_us")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    assert!(outposts >= 1, "expected at least one outpost detected");
}

#[test]
fn passed_pawn_example() {
    // Source: Wikipedia / passed pawn examples (adapted)
    // White pawn on c5 with no opposing pawns ahead should be detected as passed
    let fen = "4k3/8/8/2P5/8/8/8/4K3 w - - 0 1";
    let rec = analyze_fen(fen).expect("FEN should parse");
    let passed = rec
        .groups
        .pawn_structure
        .terms
        .get("passed")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    assert!(passed >= 1, "expected at least one passed pawn");
}

#[test]
fn isolated_pawn_example() {
    // Source: chessprogramming.org / pawn structure (isolated pawn example adapted)
    // White pawn isolated on d4 (no adjacent white pawns)
    let fen = "4k3/8/8/3P4/8/8/8/4K3 w - - 0 1";
    let rec = analyze_fen(fen).expect("FEN should parse");
    let isolated = rec
        .groups
        .pawn_structure
        .terms
        .get("isolated")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    assert!(isolated >= 1, "expected at least one isolated pawn");
}

#[test]
fn doubled_rooks_and_rook_on_seventh() {
    // Source: chessprogramming.org / rook activity
    // Two rooks doubled on a-file and a rook on the 7th rank
    let fen = "4k3/R7/8/8/8/8/R7/4K3 w - - 0 1";
    let rec = analyze_fen(fen).expect("FEN should parse");
    let doubled = rec
        .groups
        .piece_activity
        .terms
        .get("doubled_rooks")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    let rook_on_seventh = rec
        .groups
        .piece_activity
        .terms
        .get("rook_on_seventh")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    assert!(doubled >= 1, "expected doubled rooks detected");
    assert!(rook_on_seventh >= 1, "expected a rook on the seventh");
}

#[test]
fn center_control_example() {
    // Source: chessprogramming.org / center control
    // White occupies d4 which should give center control
    let fen = "4k3/8/8/3P4/8/8/8/4K3 w - - 0 1";
    let rec = analyze_fen(fen).expect("FEN should parse");
    let cc = rec
        .groups
        .vector_features
        .terms
        .get("center_control_us")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    assert!(cc > 0, "expected positive center control score");
}
