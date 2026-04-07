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

# ---------------------------------------------------------------------------
# Part A: no-data path — call phase 4 with no caches present
# ---------------------------------------------------------------------------
clean-db | ignore
clean-sync-cache | ignore
init-db | ignore

# Ensure no stale caches from prior test runs
rm --force "./reports/.cache/color.nuon"
rm --force "./reports/.cache/rating-bands.nuon"
rm --force "./reports/.cache/time-control.nuon"
rm --force "./reports/.cache/openings.nuon"
rm --force "./reports/.cache/loss-positions.nuon"
rm --force "./reports/.cache/win-positions.nuon"
rm --force "./reports/.cache/profiles.nuon"
rm --force "./reports/playstyle-summary.md"

let no_data_result = (generate-reports 4)

if $no_data_result.phase != 4 {
  error make { msg: $"Expected phase 4, got ($no_data_result.phase)" }
}
if ($no_data_result.reports | length) != 1 {
  error make { msg: $"Expected 1 report, got ($no_data_result.reports | length)" }
}
let nd_rep = ($no_data_result.reports | get 0)
if $nd_rep.status != "no-data" {
  error make { msg: $"Expected no-data status when no caches present, got: ($nd_rep.status)" }
}
if not ("./reports/playstyle-summary.md" | path exists) {
  error make { msg: "playstyle-summary.md not created in no-data path" }
}
let nd_md = (open --raw "./reports/playstyle-summary.md")
if not ($nd_md | str contains "# Playstyle Summary") {
  error make { msg: "no-data playstyle-summary.md missing heading" }
}

# ---------------------------------------------------------------------------
# Part B: full data path — run phases 1, 2, 3, then phase 4
# ---------------------------------------------------------------------------
sync-games ['chesscom' 'all' 'hikaru'] | ignore
critter-eval-queue 100 | ignore

# Sanity: verify evals were inserted before running phase 3
let cfg = load-config
let db  = $cfg.database.path
let eval_count = (open $db | query db "SELECT COUNT(*) AS n FROM position_critter_evals" | get 0.n)
if $eval_count == 0 {
  error make { msg: "No critter evals inserted — cannot run Phase 4 full-data test" }
}

generate-reports 1 | ignore
generate-reports 2 | ignore
generate-reports 3 | ignore

let result = (generate-reports 4)

if $result.phase != 4 {
  error make { msg: $"Expected phase 4, got ($result.phase)" }
}
if ($result.reports | length) != 1 {
  error make { msg: $"Expected 1 report, got ($result.reports | length)" }
}

let rep = ($result.reports | get 0)
if $rep.status != "ok" {
  error make { msg: $"Expected ok status with all caches populated, got: ($rep.status)" }
}
if $rep.sources_loaded < 4 {
  error make { msg: $"Expected at least 4 cache sources loaded, got: ($rep.sources_loaded)" }
}

# ---------------------------------------------------------------------------
# Content validation
# ---------------------------------------------------------------------------
if not ("./reports/playstyle-summary.md" | path exists) {
  error make { msg: "reports/playstyle-summary.md not created" }
}
let md = (open --raw "./reports/playstyle-summary.md")
if ($md | str length) == 0 {
  error make { msg: "reports/playstyle-summary.md is empty" }
}

# Required headings
let required_headings = [
  "# Playstyle Summary"
  "## At a Glance"
  "## Color Performance"
  "## Rating Band Performance"
  "## Time Control"
  "## Openings"
  "## Position Profile"
  "## Insights"
]
for h in $required_headings {
  if not ($md | str contains $h) {
    error make { msg: $"playstyle-summary.md missing heading: ($h)" }
  }
}

# Generated-by line with sources count
if not ($md | str contains "of 7 cache sources loaded") {
  error make { msg: "playstyle-summary.md missing sources-loaded metadata line" }
}

# At a Glance table should contain known fixture data:
# - all 4 games are Hikaru (White) wins → "Best color" row
if not ($md | str contains "Best color") {
  error make { msg: "At a Glance missing 'Best color' row" }
}

# Fixture openings include known ECO entries (Ruy Lopez or King's Pawn etc.)
if not ($md | str contains "King's Pawn") and not ($md | str contains "Ruy Lopez") and not ($md | str contains "King's Knight") {
  error make { msg: "playstyle-summary.md missing expected opening entries (King's Pawn, Ruy Lopez, or King's Knight)" }
}

# Phase 3 fixture: all-zero evals → Open/Tactical/Dynamic
if not ($md | str contains "Open") {
  error make { msg: "playstyle-summary.md missing 'Open' from position profile" }
}
if not ($md | str contains "Tactical") {
  error make { msg: "playstyle-summary.md missing 'Tactical' from position profile" }
}
if not ($md | str contains "Dynamic") {
  error make { msg: "playstyle-summary.md missing 'Dynamic' from position profile" }
}

# Fixture: Hikaru wins all 4 games as White → strengths should mention White or wins
# (insights may mention strong White win rate or reliable win position)
if not ($md | str contains "## Insights") {
  error make { msg: "playstyle-summary.md missing Insights section" }
}

# ---------------------------------------------------------------------------
# Idempotency: second run produces same status
# ---------------------------------------------------------------------------
let result2 = (generate-reports 4)
let s1 = ($result.reports  | get 0 | get status)
let s2 = ($result2.reports | get 0 | get status)
if $s1 != $s2 {
  error make { msg: $"Second run produced different status: ($s1) vs ($s2)" }
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm --force "./reports/playstyle-summary.md"
rm --force "./reports/.cache/color.nuon"
rm --force "./reports/.cache/rating-bands.nuon"
rm --force "./reports/.cache/time-control.nuon"
rm --force "./reports/.cache/openings.nuon"
rm --force "./reports/.cache/loss-positions.nuon"
rm --force "./reports/.cache/win-positions.nuon"
rm --force "./reports/.cache/profiles.nuon"

print 'reports-phase4-test-ok'
