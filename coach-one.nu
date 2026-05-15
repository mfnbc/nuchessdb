#!/usr/bin/env nu
# 1. Eval
let fen = "7k/8/1r3q2/3N4/8/8/8/4K3 w - - 0 1"
let eval = ($fen | chessdb hugm-eval --verbose true --player-elo 1400)
let report = $eval.sensor_report

# 2. Concepts
let concepts = ($report.tactical.forks | each {|f| {
    name: "fork", severity: 240, elo_min: 1000,
    side: $f.attacker.color,
    data: { attacker: $f.attacker, targets: $f.targets }
}} | sort-by severity | reverse)

# 3. Coach input
let coach = { fen: $fen, player_elo: 1400, concepts: $concepts, scores: $report.aggregated }

# 4. System prompt
let sys = (open nu-agent/contracts/chess_coach.toml | get prompt.system)

# 5. Build body and save
{ model: "qwen/qwen3.6-35b-a3b", temperature: 0, messages: [
    { role: "system", content: $sys },
    { role: "user", content: ($coach | to json -r) }
]} | to json -r | save -f /tmp/coach_body.json

# 6. Call LLM via curl
print (curl -s -X POST http://172.19.224.1:1234/v1/chat/completions -H "Content-Type: application/json" -d @/tmp/coach_body.json | from json | get choices.0.message.content)
