#!/usr/bin/env nu
# smoke-test.nu — end-to-end pipeline verification
#
# Verifies the plugin is registered and the full eval → coach flow works.
# Run from the nuchessdb project root.
#
# Prerequisites:
#   cd nu_plugin_chessdb && cargo build --release && cd ..
#   nu -c 'plugin add nu_plugin_chessdb/target/release/nu_plugin_chessdb'

let fen = "7k/8/1r3q2/3N4/8/8/8/4K3 w - - 0 1"
print $"Evaluating: ($fen)\n"

let eval   = ($fen | chessdb hugm-eval --verbose true --player-elo 1400)
let report = $eval.sensor_report

print "── Sensor report ────────────────────────────────────"
{
    forks:       ($report.tactical.forks       | length)
    pins:        ($report.tactical.pins        | length)
    skewers:     ($report.tactical.skewers     | length)
    discovered:  ($report.tactical.discovered  | length)
    hanging:     ($report.tactical.hanging     | length)
    outposts:    ($report.positional.outposts  | length)
    open_files:  ($report.positional.open_files | length)
    passed_pawns: ($report.positional.passed_pawns | length)
} | print ($in | table)

if ($report.tactical.forks | is-not-empty) {
    print "\nFork details:"
    $report.tactical.forks | each { |f| {
        attacker: $"($f.attacker.role)@($f.attacker.square)"
        targets:  ($f.targets | each { $"($in.role)@($in.square)" } | str join ", ")
    }} | print ($in | table)
}

print "\n── Coach input ──────────────────────────────────────"
let concepts = (
    $report.tactical.forks | each { |f| {
        name: "fork", severity: 240, elo_min: 1000,
        side: $f.attacker.color,
        data: {attacker: $f.attacker, targets: $f.targets}
    }}
    | append ($report.tactical.pins | each { |p| {
        name: "pin", severity: 160, elo_min: 1200,
        side: $p.attacker.color,
        data: {attacker: $p.attacker, pinned: $p.pinned, shielded: $p.shielded, pin_type: $p.pin_type}
    }})
    | append ($report.tactical.hanging | each { |h| {
        name: "hanging_piece", severity: 200, elo_min: 1000,
        side: $h.piece.color,
        data: {piece: $h.piece, attacker_count: $h.attacker_count}
    }})
    | sort-by severity --reverse
)

let coach_input = {fen: $fen, player_elo: 1400, concepts: $concepts, scores: $report.aggregated}
print ($coach_input | to json -r)

print "\n── LLM coaching ─────────────────────────────────────"
nu ../nu-agent/nu-agent --prompt ($coach_input | to json -r) --contract ../nu-agent/contracts/chess_coach.toml
| print
