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

$env.NUCHESSDB_CONFIG          = $fixture_config
$env.NUCHESSDB_TEST_ARCHIVES_JSON = $fixture_archives
$env.NUCHESSDB_TEST_PGN_MODE   = 'fixture'
$env.NUCHESSDB_TEST_PGN_FIXTURE = $fixture_pgn
$env.NUCHESSDB_TEST_CRITTER_MODE = 'fixture'

# Fresh DB with a few games
clean-db | ignore
clean-sync-cache | ignore
init-db | ignore
sync-games ['chesscom' 'all' 'hikaru'] | ignore

# ---------------------------------------------------------------------------
# Run Phase 1 reports
# ---------------------------------------------------------------------------
let result = (generate-reports 1)

if $result.phase != 1 {
  error make { msg: $"Expected phase 1, got ($result.phase)" }
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
  "./reports/color-performance.md"
  "./reports/rating-bands.md"
  "./reports/time-control.md"
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
# Verify cache files were created
# ---------------------------------------------------------------------------
let expected_cache = [
  "./reports/.cache/color.nuon"
  "./reports/.cache/rating-bands.nuon"
  "./reports/.cache/time-control.nuon"
]

for f in $expected_cache {
  if not ($f | path exists) {
    error make { msg: $"Expected cache file not found: ($f)" }
  }
}

# ---------------------------------------------------------------------------
# Spot-check color-performance.md content
# ---------------------------------------------------------------------------
let color_md = (open --raw "./reports/color-performance.md")

if not ($color_md | str contains "# Color Performance") {
  error make { msg: "color-performance.md missing expected heading" }
}
if not ($color_md | str contains "| Color |") {
  error make { msg: "color-performance.md missing table header" }
}

# ---------------------------------------------------------------------------
# Spot-check color.nuon is parseable and has expected shape
# ---------------------------------------------------------------------------
let color_cache = (open "./reports/.cache/color.nuon")

if ($color_cache | is-empty) {
  error make { msg: "color.nuon cache is empty" }
}

let required_cols = [color total wins draws losses win_pct draw_pct loss_pct]
for col in $required_cols {
  if not ($color_cache | columns | any { |c| $c == $col }) {
    error make { msg: $"color.nuon missing expected column: ($col)" }
  }
}

# ---------------------------------------------------------------------------
# Verify re-running is idempotent (no errors on second run)
# ---------------------------------------------------------------------------
let result2 = (generate-reports 1)
if ($result2.reports | where status == "ok" | length) != ($result.reports | where status == "ok" | length) {
  error make { msg: "Second run of generate-reports produced different ok count" }
}

# Clean up report files so tests don't leave state behind
rm --force "./reports/color-performance.md"
rm --force "./reports/rating-bands.md"
rm --force "./reports/time-control.md"
rm --force "./reports/.cache/color.nuon"
rm --force "./reports/.cache/rating-bands.nuon"
rm --force "./reports/.cache/time-control.nuon"

print 'reports-phase1-test-ok'
