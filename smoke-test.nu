#!/usr/bin/env nu
# smoke-test.nu — End-to-end coach pipeline test
#
# Prerequisites:
#   plugin add ./nu_plugin_chessdb/target/release/nu_plugin_chessdb

# 1. Build
print "Building plugin..."
cd nu_plugin_chessdb
cargo build --release
cd ..

# 2. Fork position from eval::position::tests::detects_fork
let fen = "7k/8/1r3q2/3N4/8/8/8/4K3 w - - 0 1"
print $"\nEvaluating: ($fen)"

let eval = ($fen | chessdb hugm-eval --verbose true --player-elo 1400)
let report = $eval.sensor_report

# 3. Show what we detected
print "\n── SensorReport ──"
let fork_count = ($report.tactical.forks | length)
print $"  Forks: ($fork_count)"
if $fork_count > 0 {
    let fork_dump = ($report.tactical.forks | each {|f| {
        attacker: $"($f.attacker.role)($f.attacker.square)",
        targets: ($f.targets | each {|t| $"($t.role)($t.square)"})
    }})
    print $"    ($fork_dump | to json -r)"
}
let pin_count = ($report.tactical.pins | length)
print $"  Pins: ($pin_count)"
print $"  Skewers: ($report.tactical.skewers | length)"
print $"  Discovered: ($report.tactical.discovered | length)"
print $"  Hanging: ($report.tactical.hanging | length)"
print $"  Outposts: ($report.positional.outposts | length)"
print $"  Open files: ($report.positional.open_files | length)"
print $"  Passed: ($report.positional.passed_pawns | length)"
print $"  Doubled: ($report.positional.doubled_pawns | length)"
print $"  Isolated: ($report.positional.isolated_pawns | length)"
print $"  Pawn islands: ($report.positional.pawn_islands | length)"
print $"  Pawn breaks: ($report.positional.pawn_breaks | length)"
let minority = ($report.positional.minority_attack | default "none")
let dev = ($report.positional.development | default "none")
let king = ($report.positional.king_exposure | default "none")
print $"  Minority attack: ($minority)"
print $"  Development: ($dev)"
print $"  King exposure: ($king)"
let bal_white = ($report.material.balance.white | to json -r)
let bal_black = ($report.material.balance.black | to json -r)
print $"\n  Material white: ($bal_white)"
print $"  Material black: ($bal_black)"

# 4. Build coach input from typed concepts
let concepts = (
    $report.tactical.forks | each {|f| {
        name: "fork", severity: 240, elo_min: 1000,
        side: $f.attacker.color,
        data: { attacker: $f.attacker, targets: $f.targets }
    }}
    | append ($report.tactical.pins | each {|p| {
        name: "pin", severity: 160, elo_min: 1200,
        side: $p.attacker.color,
        data: { attacker: $p.attacker, pinned: $p.pinned,
                shielded: $p.shielded, pin_type: $p.pin_type }
    }})
    | append ($report.tactical.hanging | each {|h| {
        name: "hanging_piece", severity: 200, elo_min: 1000,
        side: $h.piece.color,
        data: { piece: $h.piece, attacker_count: $h.attacker_count }
    }})
)

let coach_input = {
    fen: $fen, player_elo: 1400,
    concepts: ($concepts | sort-by -severity),
    scores: $report.aggregated
}

print "\n── Coach Input JSON ──"
print ($coach_input | to json -r)

# 5. Enrich via nu-agent
print "\n── LLM Coaching ──"
let coaching = (nu nu-agent/engine.nu run nu-agent/contracts/chess_coach.toml ($coach_input | to json -r))
print $coaching
