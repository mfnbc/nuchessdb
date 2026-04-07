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

# Fresh DB with fixture games (4 games, all Hikaru wins as White, Ruy Lopez line)
clean-db | ignore
clean-sync-cache | ignore
init-db | ignore
sync-games ['chesscom' 'all' 'hikaru'] | ignore

# Populate critter evals using fixture stub (all-zero eval records)
critter-eval-queue 100 | ignore

# ---------------------------------------------------------------------------
# Without evals the report should return no-data (verify precondition first)
# by checking we actually have evals after the queue run
# ---------------------------------------------------------------------------
let cfg = load-config
let db  = $cfg.database.path
let eval_count = (open $db | query db "SELECT COUNT(*) AS n FROM position_critter_evals" | get 0.n)
if $eval_count == 0 {
  error make { msg: "No critter evals were inserted — cannot test Phase 3 report" }
}

# ---------------------------------------------------------------------------
# Run Phase 3 reports
# ---------------------------------------------------------------------------
let result = (generate-reports 3)

if $result.phase != 3 {
  error make { msg: $"Expected phase 3, got ($result.phase)" }
}

if ($result.reports | length) != 1 {
  error make { msg: $"Expected 1 report, got ($result.reports | length)" }
}

let rep = ($result.reports | get 0)
if $rep.status != "ok" and $rep.status != "no-data" {
  error make { msg: $"position-profiles had unexpected status: ($rep.status)" }
}

# ---------------------------------------------------------------------------
# Report file must exist and be non-empty
# ---------------------------------------------------------------------------
if not ("./reports/position-profiles.md" | path exists) {
  error make { msg: "reports/position-profiles.md not created" }
}
let md = (open --raw "./reports/position-profiles.md")
if ($md | str length) == 0 {
  error make { msg: "reports/position-profiles.md is empty" }
}

# ---------------------------------------------------------------------------
# If we got ok status, validate content and cache
# ---------------------------------------------------------------------------
if $rep.status == "ok" {
  # Heading check
  if not ($md | str contains "# Position Profiles") {
    error make { msg: "position-profiles.md missing heading" }
  }
  if not ($md | str contains "## Open vs Closed") {
    error make { msg: "position-profiles.md missing Open vs Closed section" }
  }
  if not ($md | str contains "## Tactical vs Strategic") {
    error make { msg: "position-profiles.md missing Tactical vs Strategic section" }
  }
  if not ($md | str contains "## Dynamic vs Positional") {
    error make { msg: "position-profiles.md missing Dynamic vs Positional section" }
  }
  if not ($md | str contains "## Top Evaluated Positions") {
    error make { msg: "position-profiles.md missing Top Evaluated Positions section" }
  }

  # Cache file
  if not ("./reports/.cache/profiles.nuon" | path exists) {
    error make { msg: "reports/.cache/profiles.nuon not created" }
  }
  let cache = (open "./reports/.cache/profiles.nuon")
  if ($cache | is-empty) {
    error make { msg: "profiles.nuon cache is empty" }
  }

  let required_cols = [canonical_fen final_score me_wins me_draws me_losses me_occurrences openness character tempo eco_code opening_name]
  for col in $required_cols {
    if not ($cache | columns | any { |c| $c == $col }) {
      error make { msg: $"profiles.nuon missing expected column: ($col)" }
    }
  }

  # Fixture: all evals are zero → openness = "Open", character = "Tactical", tempo = "Dynamic"
  let unexpected_openness  = ($cache | where openness  != "Open")
  let unexpected_character = ($cache | where character != "Tactical")
  let unexpected_tempo     = ($cache | where tempo     != "Dynamic")
  if ($unexpected_openness | length) > 0 {
    error make { msg: $"All fixture positions should classify as Open (all-zero eval), got: ($unexpected_openness | get openness | uniq | to nuon)" }
  }
  if ($unexpected_character | length) > 0 {
    error make { msg: $"All fixture positions should classify as Tactical (all-zero eval), got: ($unexpected_character | get character | uniq | to nuon)" }
  }
  if ($unexpected_tempo | length) > 0 {
    error make { msg: $"All fixture positions should classify as Dynamic (all-zero eval), got: ($unexpected_tempo | get tempo | uniq | to nuon)" }
  }

  # Ruy Lopez positions should appear (4 games × Ruy Lopez line)
  let positions = ($cache | length)
  if $positions < 1 {
    error make { msg: $"Expected at least 1 evaluated position, got ($positions)" }
  }
}

# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------
let result2 = (generate-reports 3)
let s1 = ($result.reports  | get 0 | get status)
let s2 = ($result2.reports | get 0 | get status)
if $s1 != $s2 {
  error make { msg: $"Second run produced different status: ($s1) vs ($s2)" }
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm --force "./reports/position-profiles.md"
rm --force "./reports/.cache/profiles.nuon"

print 'reports-phase3-test-ok'
