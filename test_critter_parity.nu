plugin use chessdb

# ---------------------------------------------------------------------------
# Critter-eval consistency and sanity test
#
# Tests two things:
#   1. Internal consistency: checks.sum_groups == final_score for every position.
#   2. Sign sanity: for positions with a clear material advantage, the plugin
#      agrees with OpenCritter on the sign of the evaluation.
#
# Note: chessdb critter-eval is an independent reimplementation, NOT a direct
# port of OpenCritter. The individual group values (particularly king_safety)
# differ materially from OpenCritter. These tests verify self-consistency and
# directional correctness, not numeric parity.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Tal vs Fischer, Candidates Tournament 1959, game 3
# We extract positions up to move 20 and check internal consistency for all.
# ---------------------------------------------------------------------------
let tal_fischer_pgn = '[Event "Candidates Tournament"]
[Site "Bled/Zagreb/Belgrade YUG"]
[Date "1959.10.11"]
[Round "3"]
[White "Tal, M"]
[Black "Fischer, R"]
[Result "1-0"]

1.e4 e5 2.Nf3 Nc6 3.Bb5 a6 4.Ba4 Nf6 5.O-O Be7 6.Re1 b5 7.Bb3 d6
8.c3 O-O 9.h3 Na5 10.Bc2 c5 11.d4 Qc7 12.Nbd2 Bd7 13.Nf1 cxd4
14.cxd4 Nc6 15.Ne3 Nb4 16.Bb1 exd4 17.Nxd4 Nxe4 18.Ndf5 Bxf5
19.Nxf5 Nd2 20.Qxd2 g6 1-0'

let pgn_fens = ($tal_fischer_pgn | chessdb pgn-to-fens | first 20)

if ($pgn_fens | length) == 0 {
  error make { msg: 'pgn-to-fens returned no rows for Tal-Fischer PGN' }
}

# ---------------------------------------------------------------------------
# 1. Internal consistency: sum_groups == final_score for all game positions
# ---------------------------------------------------------------------------
print $"Checking internal consistency for ($pgn_fens | length) Tal-Fischer positions..."

let consistency_failures = (
  $pgn_fens
  | each { |row|
      let ev = ($row.fen | chessdb critter-eval)
      if $ev.checks.sum_groups != $ev.final_score {
        { ply: $row.ply, fen: $row.fen, final_score: $ev.final_score, sum_groups: $ev.checks.sum_groups }
      }
    }
  | compact
)

if ($consistency_failures | length) > 0 {
  $consistency_failures | each { |r|
    print $"  FAIL ply=($r.ply): final_score=($r.final_score) sum_groups=($r.sum_groups) fen=($r.fen)"
  }
  error make { msg: $'($consistency_failures | length) positions have sum_groups != final_score' }
}

# Also check starting position and a king-only endgame
let extra_fens = [
  "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
  "8/8/8/8/8/7k/8/6K1 w - - 0 1"
  "r1bq1rk1/1ppn1p1n/p2p1bpp/3Pp3/1PP1P2B/2N5/P2NBPPP/R2Q1RK1 w - - 1 13"
  "r1b1qrk1/1ppn1pb1/p2p1npp/3Pp3/2P1P2B/2N5/PP1NBPPP/R2Q1RK1 b - - 3 11"
]

let extra_failures = (
  $extra_fens
  | each { |fen|
      let ev = ($fen | chessdb critter-eval)
      if $ev.checks.sum_groups != $ev.final_score {
        { fen: $fen, final_score: $ev.final_score, sum_groups: $ev.checks.sum_groups }
      }
    }
  | compact
)

if ($extra_failures | length) > 0 {
  $extra_failures | each { |r|
    print $"  FAIL: final_score=($r.final_score) sum_groups=($r.sum_groups) fen=($r.fen)"
  }
  error make { msg: $'($extra_failures | length) reference positions have sum_groups != final_score' }
}

# ---------------------------------------------------------------------------
# 2. Sign sanity: clear material-advantage positions
# We use pure material imbalances (extra rook / extra queen) where positional
# factors cannot override the material count.
# ---------------------------------------------------------------------------
print "Checking sign sanity for material-advantage positions..."

# White has an extra rook: should be positive
let white_adv_fen = "4k3/8/8/8/8/8/8/R3K3 w Q - 0 1"
let white_ev = ($white_adv_fen | chessdb critter-eval)
let ws = $white_ev.final_score
if $ws <= 0 {
  error make { msg: $"Expected positive score for white_rook_up position, got ($ws)" }
}

# Black has an extra rook: should be negative
let black_adv_fen = "4k3/r7/8/8/8/8/8/4K3 b - - 0 1"
let black_ev = ($black_adv_fen | chessdb critter-eval)
let bs = $black_ev.final_score
if $bs >= 0 {
  error make { msg: $"Expected negative score for black_rook_up position, got ($bs)" }
}

# White has extra queen: should be strongly positive
let white_queen_fen = "4k3/8/8/8/8/8/8/4K2Q w - - 0 1"
let wq_ev = ($white_queen_fen | chessdb critter-eval)
let wqs = $wq_ev.final_score
if $wqs <= 0 {
  error make { msg: $"Expected positive score for white_queen_up position, got ($wqs)" }
}

# ---------------------------------------------------------------------------
# 3. Structural checks: all required groups are present in the output
# ---------------------------------------------------------------------------
print "Checking output structure..."

let required_groups = [material pawn_structure piece_activity king_safety passed_pawns development vector_features strategic]
let sample_ev = ($pgn_fens | first | get fen | chessdb critter-eval)
let actual_groups = ($sample_ev | get groups | columns)

let missing_groups = ($required_groups | where { |g| $g not-in $actual_groups })
if ($missing_groups | length) > 0 {
  error make { msg: $'Missing eval groups: ($missing_groups | str join ", ")' }
}

# Verify checks record is present and has expected keys
if not ($sample_ev | get checks | columns | any { |c| $c == "sum_groups" }) {
  error make { msg: 'checks.sum_groups missing from critter-eval output' }
}

if not ($sample_ev | get checks | columns | any { |c| $c == "matches_final" }) {
  error make { msg: 'checks.matches_final missing from critter-eval output' }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
let game_count = ($pgn_fens | length)
let extra_count = ($extra_fens | length)
print $"Tal-Fischer positions checked for sum consistency: ($game_count)"
print $"Reference positions checked for sum consistency: ($extra_count)"
let white_score = $ws
let black_score = $bs
let wqueen_score = $wqs
print $"Sign sanity checks: 3 white_rook_up=($white_score) black_rook_up=($black_score) white_queen_up=($wqueen_score) centipawns"
print 'critter-parity-test-ok'
