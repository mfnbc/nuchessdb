#!/usr/bin/env nu
# coach-one.nu — single-position coaching example
#
# Evaluates a FEN, extracts the top tactical concept, and gets Socratic
# coaching from nu-agent. Useful for testing the full pipeline end-to-end.
#
# Usage: nu coach-one.nu [fen]

def main [fen: string = "7k/8/1r3q2/3N4/8/8/8/4K3 w - - 0 1"] {
    let eval   = ($fen | chessdb hugm-eval --verbose true --player-elo 1400)
    let report = $eval.sensor_report

    let concepts = (
        $report.tactical.forks | each { |f| {
            name: "fork", severity: 240, elo_min: 1000,
            side: $f.attacker.color,
            data: {attacker: $f.attacker, targets: $f.targets}
        }}
        | sort-by severity --reverse
    )

    let coach_input = {fen: $fen, player_elo: 1400, concepts: $concepts, scores: $report.aggregated}

    let sys = (open ../nu-agent/contracts/chess_coach.toml | get prompt.system)
    let cfg = (open ../nu-agent/config.toml)

    let body = {
        model: $cfg.chat.model
        temperature: 0
        messages: [
            {role: "system", content: $sys}
            {role: "user",   content: ($coach_input | to json -r)}
        ]
    }

    (http post --content-type application/json $cfg.chat.url $body)
    | get choices.0.message.content
    | print
}
