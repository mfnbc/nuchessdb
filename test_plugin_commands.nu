plugin use chessdb

# ---------------------------------------------------------------------------
# Plugin command coverage tests
#
# Covers the 10 commands that had zero prior test coverage:
#   encode-fen, normalize-fen, attack-summary, checker-summary, mobility,
#   nnue-eval (error path only — no weights file in repo), apply-san,
#   apply-uci, san-to-uci, fen-info
# ---------------------------------------------------------------------------

let START  = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
let E4_FEN = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"

# ---------------------------------------------------------------------------
# encode-fen
# ---------------------------------------------------------------------------
print "Testing encode-fen..."

let enc = ($START | chessdb encode-fen)
if ($enc | describe) != "list<float>" {
  error make { msg: $"encode-fen should return list<float>, got ($enc | describe)" }
}
if ($enc | length) != 1024 {
  error make { msg: $"encode-fen should return 1024 floats, got ($enc | length)" }
}
# All values should be in [0.0, 1.0] (piece-position features are binary; material/positional features are normalised)
let bad_values = ($enc | where { |x| $x < 0.0 or $x > 1.0 })
if ($bad_values | length) > 0 {
  error make { msg: $"encode-fen values should all be in [0.0, 1.0], found ($bad_values | length) outliers" }
}
print "  encode-fen OK"

# ---------------------------------------------------------------------------
# normalize-fen
# ---------------------------------------------------------------------------
print "Testing normalize-fen..."

# Canonical FEN should survive a round-trip unchanged
let norm = ($START | chessdb normalize-fen)
if $norm != $START {
  error make { msg: $"normalize-fen round-trip failed: expected ($START), got ($norm)" }
}

# A FEN with a different en-passant legality should be normalised
# After 1.e4 the FEN has en-passant on e3 only if Black can immediately capture it.
# The starting position normalises to itself.
let norm2 = ($E4_FEN | chessdb normalize-fen)
if ($norm2 | str length) == 0 {
  error make { msg: "normalize-fen returned empty string for e4 position" }
}
print "  normalize-fen OK"

# ---------------------------------------------------------------------------
# attack-summary
# ---------------------------------------------------------------------------
print "Testing attack-summary..."

let atk = ($START | chessdb attack-summary)
let atk_cols = ($atk | columns)
for col in [attacked_by_white attacked_by_black white_attack_count black_attack_count] {
  if $col not-in $atk_cols {
    error make { msg: $"attack-summary missing column: ($col)" }
  }
}
# Starting position: each side attacks 22 squares (standard value)
if $atk.white_attack_count != 22 {
  error make { msg: $"attack-summary white_attack_count expected 22, got ($atk.white_attack_count)" }
}
if $atk.black_attack_count != 22 {
  error make { msg: $"attack-summary black_attack_count expected 22, got ($atk.black_attack_count)" }
}
if ($atk.attacked_by_white | describe) != "list<string>" {
  error make { msg: "attack-summary attacked_by_white should be list<string>" }
}
print "  attack-summary OK"

# ---------------------------------------------------------------------------
# checker-summary
# ---------------------------------------------------------------------------
print "Testing checker-summary..."

let chk_start = ($START | chessdb checker-summary)
let chk_cols = ($chk_start | columns)
for col in [side_to_move is_check is_checkmate checker_squares] {
  if $col not-in $chk_cols {
    error make { msg: $"checker-summary missing column: ($col)" }
  }
}
if $chk_start.is_check != false {
  error make { msg: "checker-summary: starting position should not be in check" }
}
if $chk_start.is_checkmate != false {
  error make { msg: "checker-summary: starting position should not be checkmate" }
}
if ($chk_start.checker_squares | length) != 0 {
  error make { msg: "checker-summary: starting position should have no checkers" }
}
if $chk_start.side_to_move != "white" {
  error make { msg: $"checker-summary: side_to_move expected white, got ($chk_start.side_to_move)" }
}

# Test a position in check: Scholar's mate (after Qxf7+)
# r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4
let check_fen = "r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4"
let chk_check = ($check_fen | chessdb checker-summary)
if $chk_check.is_check != true {
  error make { msg: "checker-summary: Scholar's mate position should be in check" }
}
if ($chk_check.checker_squares | length) == 0 {
  error make { msg: "checker-summary: Scholar's mate position should have checker squares" }
}
print "  checker-summary OK"

# ---------------------------------------------------------------------------
# mobility
# ---------------------------------------------------------------------------
print "Testing mobility..."

let mob = ($START | chessdb mobility)
let mob_cols = ($mob | columns)
for col in [side_to_move legal_move_count mobility_san] {
  if $col not-in $mob_cols {
    error make { msg: $"mobility missing column: ($col)" }
  }
}
# Starting position has exactly 20 legal moves
if $mob.legal_move_count != 20 {
  error make { msg: $"mobility: starting position should have 20 legal moves, got ($mob.legal_move_count)" }
}
if ($mob.mobility_san | length) != 20 {
  error make { msg: $"mobility: mobility_san list length expected 20, got ($mob.mobility_san | length)" }
}
if $mob.side_to_move != "white" {
  error make { msg: $"mobility: side_to_move expected white, got ($mob.side_to_move)" }
}
# Checkmate position has 0 legal moves
# Fool's mate: 1.f3 e5 2.g4 Qh4# — Black's queen gives checkmate
let mate_fen = "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3"
let mob_mate = ($mate_fen | chessdb mobility)
if $mob_mate.legal_move_count != 0 {
  error make { msg: $"mobility: checkmate position should have 0 moves, got ($mob_mate.legal_move_count)" }
}
print "  mobility OK"

# ---------------------------------------------------------------------------
# fen-info
# ---------------------------------------------------------------------------
print "Testing fen-info..."

let fi = ($START | chessdb fen-info)
let fi_cols = ($fi | columns)
for col in [fen turn castling ep_square halfmoves fullmoves material_white material_black material_diff is_check is_checkmate is_stalemate is_insufficient_material legal_move_count] {
  if $col not-in $fi_cols {
    error make { msg: $"fen-info missing column: ($col)" }
  }
}
if $fi.turn != "white" {
  error make { msg: $"fen-info turn expected white, got ($fi.turn)" }
}
if $fi.legal_move_count != 20 {
  error make { msg: $"fen-info legal_move_count expected 20, got ($fi.legal_move_count)" }
}
if $fi.is_check != false {
  error make { msg: "fen-info: starting position is_check should be false" }
}
if $fi.material_diff != 0 {
  error make { msg: $"fen-info: starting position material_diff should be 0, got ($fi.material_diff)" }
}
if $fi.material_white != $fi.material_black {
  error make { msg: "fen-info: starting position material_white should equal material_black" }
}
print "  fen-info OK"

# ---------------------------------------------------------------------------
# apply-san
# ---------------------------------------------------------------------------
print "Testing apply-san..."

let after_e4 = ($START | chessdb apply-san "e4")
if $after_e4 != $E4_FEN {
  error make { msg: $"apply-san e4: expected ($E4_FEN), got ($after_e4)" }
}

# Chained moves
let after_e4_e5 = ($after_e4 | chessdb apply-san "e5")
if ($after_e4_e5 | str length) == 0 {
  error make { msg: "apply-san: chained e5 returned empty FEN" }
}

# Illegal move should produce an error (we catch it with try)
let illegal_result = (try { $START | chessdb apply-san "e5" } catch { |e| "error" })
if $illegal_result != "error" {
  error make { msg: "apply-san: e5 from starting position should fail (illegal)" }
}
print "  apply-san OK"

# ---------------------------------------------------------------------------
# apply-uci
# ---------------------------------------------------------------------------
print "Testing apply-uci..."

let after_uci = ($START | chessdb apply-uci "e2e4")
if $after_uci != $E4_FEN {
  error make { msg: $"apply-uci e2e4: expected ($E4_FEN), got ($after_uci)" }
}

# Promotion: pawn to queen
let promo_fen = "8/P7/8/8/8/8/8/4k1K1 w - - 0 1"
let after_promo = ($promo_fen | chessdb apply-uci "a7a8q")
if ($after_promo | str length) == 0 {
  error make { msg: "apply-uci: pawn promotion returned empty FEN" }
}

# Illegal UCI should produce an error
let illegal_uci = (try { $START | chessdb apply-uci "e7e5" } catch { |e| "error" })
if $illegal_uci != "error" {
  error make { msg: "apply-uci: e7e5 from starting position should fail (illegal for White)" }
}
print "  apply-uci OK"

# ---------------------------------------------------------------------------
# san-to-uci
# ---------------------------------------------------------------------------
print "Testing san-to-uci..."

let uci = ($START | chessdb san-to-uci "e4")
if $uci != "e2e4" {
  error make { msg: $"san-to-uci e4: expected e2e4, got ($uci)" }
}

let uci_knight = ($START | chessdb san-to-uci "Nf3")
if $uci_knight != "g1f3" {
  error make { msg: $"san-to-uci Nf3: expected g1f3, got ($uci_knight)" }
}

# Round-trip: san-to-uci then uci-to-san should recover original SAN
let san_roundtrip = ($START | chessdb san-to-uci "e4" | { |uci_move| $START | chessdb uci-to-san $uci_move })
# (uci-to-san is already tested elsewhere; we just verify no crash here)
print "  san-to-uci OK"

# ---------------------------------------------------------------------------
# nnue-eval (error path only — no weights file in repo)
# ---------------------------------------------------------------------------
print "Testing nnue-eval error path..."

let nnue_result = (try {
  $START | chessdb nnue-eval --weights "/nonexistent/path.weights"
} catch { |e| "error" })
if $nnue_result != "error" {
  error make { msg: "nnue-eval with missing weights file should return an error" }
}
print "  nnue-eval error path OK"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print ""
print "All plugin command coverage tests passed."
print "Commands tested: encode-fen, normalize-fen, attack-summary, checker-summary, mobility, fen-info, apply-san, apply-uci, san-to-uci, nnue-eval (error path)"
