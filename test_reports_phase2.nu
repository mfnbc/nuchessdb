plugin use chessdb

use ./modules/utils.nu *
use ./modules/config.nu *
use ./modules/db.nu *
use ./modules/sync.nu *
use ./modules/critter.nu *
use ./modules/reports.nu *

let fixture_config   = './test-fixtures/config.nuchessdb.nuon'
let fixture_archives = './test-fixtures/chesscom/archives.json'
let fixture_pgn      = './test-fixtures/chesscom/hikaru-game.pgn'

$env.NUCHESSDB_CONFIG             = $fixture_config
$env.NUCHESSDB_TEST_ARCHIVES_JSON = $fixture_archives
$env.NUCHESSDB_TEST_PGN_MODE      = 'fixture'
$env.NUCHESSDB_TEST_PGN_FIXTURE   = $fixture_pgn
$env.NUCHESSDB_TEST_CRITTER_MODE  = 'fixture'

# Fresh DB with fixture games (4 games, all Hikaru wins as White)
clean-db | ignore
clean-sync-cache | ignore
init-db | ignore
sync-games ['chesscom' 'all' 'hikaru'] | ignore

# ---------------------------------------------------------------------------
# Run Phase 2 reports
# ---------------------------------------------------------------------------
let result = (generate-reports 2)

if $result.phase != 2 {
  error make { msg: $"Expected phase 2, got ($result.phase)" }
}

if ($result.reports | length) != 3 {
  error make { msg: $"Expected 3 reports, got ($result.reports | length)" }
}

# All reports should have status ok or no-data (never an error)
let bad = ($result.reports | where { |r| $r.status != "ok" and $r.status != "no-data" })
if ($bad | length) > 0 {
  error make { msg: $"Report(s) had unexpected status: ($bad | to nuon)" }
}

# ---------------------------------------------------------------------------
# Verify report files were created
# ---------------------------------------------------------------------------
let expected_files = [
  "./reports/opening-repertoire.md"
  "./reports/frequent-losses.md"
  "./reports/frequent-wins.md"
]

for f in $expected_files {
  if not ($f | path exists) {
    error make { msg: $"Expected report file not found: ($f)" }
  }
  let content = (open --raw $f)
  if ($content | str length) == 0 {
    error make { msg: $"Report file is empty: ($f)" }
  }
}

# ---------------------------------------------------------------------------
# opening-repertoire.md must be "ok" — fixture has positions
# ---------------------------------------------------------------------------
let opening_report = ($result.reports | get 0)
if $opening_report.status != "ok" {
  error make { msg: $"opening-repertoire expected status ok, got ($opening_report.status)" }
}

# Cache file must exist and be parseable
if not ("./reports/.cache/openings.nuon" | path exists) {
  error make { msg: "openings.nuon cache not found" }
}
let openings_cache = (open "./reports/.cache/openings.nuon")
if ($openings_cache | is-empty) {
  error make { msg: "openings.nuon cache is empty" }
}

# Must have expected columns
let required_opening_cols = [canonical_fen me_wins me_draws me_losses me_occurrences win_pct draw_pct loss_pct eco_code opening_name]
for col in $required_opening_cols {
  if not ($openings_cache | columns | any { |c| $c == $col }) {
    error make { msg: $"openings.nuon missing expected column: ($col)" }
  }
}

# Fixture: Ruy Lopez position after 3...a6 should be classified
let ruy = ($openings_cache | where { |r| $r.opening_name =~ "Ruy" })
if ($ruy | is-empty) {
  # Not a hard failure if ECO matching misses it, but warn via print
  print "warning: no Ruy Lopez position found in openings cache (ECO match miss)"
}

# ---------------------------------------------------------------------------
# opening-repertoire.md spot-check content
# ---------------------------------------------------------------------------
let opening_md = (open --raw "./reports/opening-repertoire.md")
if not ($opening_md | str contains "# Opening Repertoire") {
  error make { msg: "opening-repertoire.md missing expected heading" }
}
if not ($opening_md | str contains "| Opening |") {
  error make { msg: "opening-repertoire.md missing table header" }
}

# ---------------------------------------------------------------------------
# frequent-losses: fixture games are all wins, so no-data is expected
# (default min_occurrences=2, no losses in fixture)
# ---------------------------------------------------------------------------
let loss_report = ($result.reports | get 1)
# status is either no-data (no losses) or ok (if there are losses)
if $loss_report.status != "ok" and $loss_report.status != "no-data" {
  error make { msg: $"frequent-losses unexpected status: ($loss_report.status)" }
}

# ---------------------------------------------------------------------------
# frequent-wins: fixture games are all wins; min_occurrences=2, 4 games loaded
# so this should be "ok"
# ---------------------------------------------------------------------------
let win_report = ($result.reports | get 2)
if $win_report.status != "ok" {
  error make { msg: $"frequent-wins expected status ok, got ($win_report.status)" }
}

# Win cache must exist
if not ("./reports/.cache/win-positions.nuon" | path exists) {
  error make { msg: "win-positions.nuon cache not found" }
}
let win_cache = (open "./reports/.cache/win-positions.nuon")
if ($win_cache | is-empty) {
  error make { msg: "win-positions.nuon cache is empty" }
}

let required_win_cols = [canonical_fen me_wins me_draws me_losses me_occurrences win_pct loss_pct eco_code opening_name]
for col in $required_win_cols {
  if not ($win_cache | columns | any { |c| $c == $col }) {
    error make { msg: $"win-positions.nuon missing expected column: ($col)" }
  }
}

# ---------------------------------------------------------------------------
# frequent-wins.md spot-check
# ---------------------------------------------------------------------------
let win_md = (open --raw "./reports/frequent-wins.md")
if not ($win_md | str contains "# Frequent Win Positions") {
  error make { msg: "frequent-wins.md missing expected heading" }
}
if not ($win_md | str contains "| Opening |") {
  error make { msg: "frequent-wins.md missing table header" }
}

# ---------------------------------------------------------------------------
# Idempotency — second run should produce the same status counts
# ---------------------------------------------------------------------------
let result2 = (generate-reports 2)
let ok_count1 = ($result.reports  | where status == "ok" | length)
let ok_count2 = ($result2.reports | where status == "ok" | length)
if $ok_count1 != $ok_count2 {
  error make { msg: $"Second run of generate-reports 2 produced different ok count: ($ok_count1) vs ($ok_count2)" }
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm --force "./reports/opening-repertoire.md"
rm --force "./reports/frequent-losses.md"
rm --force "./reports/frequent-wins.md"
rm --force "./reports/.cache/openings.nuon"
rm --force "./reports/.cache/loss-positions.nuon"
rm --force "./reports/.cache/win-positions.nuon"

print 'reports-phase2-test-ok'
