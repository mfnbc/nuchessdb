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
    // White has queenside majority (a2,b2,c2) vs Black (a7,b7)
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

// Negative / near-miss tests to guard against hallucinations

#[test]
fn fork_negative_no_second_target() {
    // Similar to a fork position but only one attacked piece -> should NOT detect a fork
    let fen = "7k/8/8/3N2q1/8/8/8/4K3 w - - 0 1"; // knight on d5 attacks queen on f6 only
    let rec = analyze_fen(fen).expect("FEN should parse");
    let forks_us = rec
        .groups
        .tactical
        .terms
        .get("forks_us")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    assert_eq!(forks_us, 0, "expected no fork detected");
}

#[test]
fn skewer_negative_no_back_piece() {
    // Rook aligned with queen but no piece behind -> not a skewer
    let fen = "7k/8/8/8/8/8/q7/R3K3 w - - 0 1";
    let rec = analyze_fen(fen).expect("FEN should parse");
    let skewers_us = rec
        .groups
        .tactical
        .terms
        .get("skewers_us")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    assert_eq!(skewers_us, 0, "expected no skewer detected");
}

#[test]
fn discovered_negative_no_target() {
    // Sliding piece is blocked but there is no enemy target behind -> not a discovered attack
    let fen = "7k/8/8/8/8/8/P7/R3K3 w - - 0 1"; // rook a1, pawn a2, no enemy on a3
    let rec = analyze_fen(fen).expect("FEN should parse");
    let disc_us = rec
        .groups
        .tactical
        .terms
        .get("discovered_us")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    assert_eq!(disc_us, 0, "expected no discovered attack detected");
}

#[test]
fn outpost_negative_attacked_by_pawn() {
    // Knight on d5 but attacked by an enemy pawn on c4 -> not an outpost
    let fen = "k7/8/8/3N4/2p5/8/8/4K3 w - - 0 1";
    let rec = analyze_fen(fen).expect("FEN should parse");
    let outposts = rec
        .groups
        .piece_activity
        .terms
        .get("outposts_us")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    assert_eq!(outposts, 0, "expected no outpost detected when attacked by pawn");
}
