use ./config.nu *
use ./db.nu *
use ./import.nu *

def sync-state-path [username: string] {
  $'./tmp/sync-progress-().nuon'
}

def default-sync-state [username: string] {
  {
    provider: 'chesscom'
    username: 
    completed_archives: []
    # missing_archives is now a list of records: { archive_id: string, retries: int }
    missing_archives: []
    current_archive: null
    updated_at: null
  }
}

def load-sync-state [username: string] {
  let path = (sync-state-path )
  if ($path | path exists) {
    let state = (open $path)
    {
      provider: ($state | get -o provider | default 'chesscom')
      username: ($state | get -o username | default $username)
      completed_archives: ($state | get -o completed_archives | default [])
      missing_archives: ($state | get -o missing_archives | default [])
      current_archive: ($state | get -o current_archive | default null)
      updated_at: ($state | get -o updated_at | default null)
    }
  } else {
    default-sync-state $username
  }
}

def save-sync-state [username: string, state: record] {
  let path = (sync-state-path $username)
  mkdir ($path | path dirname)
  $state | save --force $path
  $state
}

# Updates the sync state after an archive attempt.
# if imported is true, it moves the archive to completed.
# if imported is false, it increments retry count or stays in missing.
def update-sync-state [state: record, archive_id: string, imported: bool, now: string] {
  let current_completed = ($state.completed_archives | default [])
  let current_missing = ($state.missing_archives | default [])

  if $imported {
    let remaining_missing = ($current_missing | where { |a| 
      (if ($a | describe) == "string" { $a } else { $a.archive_id }) != $archive_id 
    })
    $state
    | upsert completed_archives ($current_completed | append $archive_id | uniq)
    | upsert missing_archives $remaining_missing
    | upsert current_archive null
    | upsert updated_at $now
  } else {
    # Check if already in missing_archives as a record
    let existing = ($current_missing | where { |a| (if ($a | describe) == "string" { $a } else { $a.archive_id }) == $archive_id } | first)
    let retries = if ($existing | is-empty) { 
        1 
    } else if ($existing | describe) == "string" {
        1
    } else {
        $existing.retries + 1
    }

    let other_missing = ($current_missing | where { |a| (if ($a | describe) == "string" { $a } else { $a.archive_id }) != $archive_id })
    let new_missing = ($other_missing | append { archive_id: $archive_id, retries: $retries })

    $state
    | upsert missing_archives $new_missing
    | upsert current_archive null
    | upsert updated_at $now
  }
}

export def clean-sync-cache [] {
  let raw_dir = './data/raw/chesscom'
  let progress_files = (glob './tmp/sync-progress-*.nuon')

  if ($raw_dir | path exists) {
    rm -r $raw_dir
  }

  if not ($progress_files | is-empty) {
    $progress_files | each { |path| rm $path }
  }

  { raw_removed: $raw_dir, progress_removed: $progress_files }
}

def load-chesscom-archives [username: string] {
  let fixture = ($env | get -o NUCHESSDB_TEST_ARCHIVES_JSON | default "")

  if not ($fixture | is-empty) {
    open $fixture
  } else {
    try { http get $'https://api.chess.com/pub/player/($username)/games/archives' } catch {
      print $'sync: chesscom archives unavailable for ($username), skipping'
      null
    }
  }
}

def latest-chesscom-archive [username: string] {
  let archives = (load-chesscom-archives $username)
  if $archives == null { return null }
  let url = ($archives.archives | last)
  if $url == null { error make { msg: $'no chess.com archives found for ($username)' } }
  $url
}

def save-archive-pgn [username: string, archive_url: string, force_download: bool = false] {
  let archive_id = ($archive_url | split row "/" | last 2 | str join "-")
  let out_dir = $'./data/raw/chesscom/($username)'
  let out_file = $'($out_dir)/($archive_id).pgn'

  if not $force_download and ($out_file | path exists) {
    print $'sync: using cached ($out_file)'
    return { archive_url: $archive_url, pgn_url: $'($archive_url)/pgn', file: $out_file, cached: true }
  }

  let fixture_mode = ($env | get -o NUCHESSDB_TEST_PGN_MODE | default "")
  if $fixture_mode == "fixture" or $fixture_mode == "fixture-ready" {
    let month = ($archive_url | split row "/" | last 2 | str join "/")
    let fixture = ($env | get -o NUCHESSDB_TEST_PGN_FIXTURE | default './test-fixtures/chesscom/hikaru-game.pgn')

    if $fixture_mode == "fixture" and $month == '2024/03' {
      print $'sync: chesscom archive ($archive_id) no pgn found, skipping'
      null
    } else {
      mkdir $out_dir
      open $fixture | save --force $out_file
      { archive_url: $archive_url, pgn_url: $'($archive_url)/pgn', file: $out_file, cached: false }
    }
  } else {
    let pgn_url = $'($archive_url)/pgn'
    let raw_pgn = (try { http get $pgn_url } catch {
      print $'sync: chesscom archive ($archive_id) no pgn found, skipping'
      null
    })

    if $raw_pgn == null { return null }

    mkdir $out_dir
    $raw_pgn | save --force $out_file
    { archive_url: $archive_url, pgn_url: $pgn_url, file: $out_file, cached: false }
  }
}

def sync-chesscom-latest [username: string] {
  print $'sync: chesscom latest ($username)'
  let archive_url = (latest-chesscom-archive $username)
  # Always force download for the latest month as it's likely incomplete
  let saved = (save-archive-pgn $username $archive_url true)

  if $saved == null {
    { archive_url: $archive_url, skipped: true, reason: 'no pgn found' }
  } else {
    let imported = (import-games [$saved.file "chesscom"])
    { archive_url: $archive_url, saved: $saved, imported: $imported }
  }
}

def sync-chesscom-all [username: string] {
  let archives = (load-chesscom-archives $username)

  if $archives == null {
    return { username: $username, skipped: [], imported: [], reason: 'archives unavailable' }
  }

  let total = ($archives.archives | length)
  mut state = (load-sync-state $username)
  mut results = []

  for it in ($archives.archives | enumerate) {
    let archive_url = $it.item
    let n = ($it.index + 1)
    let archive_id = ($archive_url | split row '/' | last 2 | str join '/')
    let is_last = ($n == $total)
    
    let completed = ($state.completed_archives | default [])
    let is_completed = ($completed | any { |a| $a == $archive_id })

    # Only skip if completed and NOT the latest month
    if $is_completed and not $is_last {
      print $'sync: chesscom all ($username) ($n)/($total) skip ($archive_id)'
      $results = ($results | append { archive_url: $archive_url, archive_id: $archive_id, skipped: true })
    } else {
      print $'sync: chesscom all ($username) ($n)/($total) import ($archive_id)'
      $state = ($state | upsert current_archive $archive_id)
      save-sync-state $username $state | ignore
      
      # Force download for the latest month
      let saved = (save-archive-pgn $username $archive_url $is_last)
      
      if $saved == null {
        $state = (update-sync-state $state $archive_id false ((date now) | into string))
        save-sync-state $username $state | ignore
        $results = ($results | append { archive_url: $archive_url, archive_id: $archive_id, skipped: true, reason: 'no pgn found' })
      } else {
        let imported = (import-games [$saved.file "chesscom"])
        $state = (update-sync-state $state $archive_id true ((date now) | into string))
        save-sync-state $username $state | ignore
        $results = ($results | append { archive_url: $archive_url, archive_id: $archive_id, skipped: false, saved: $saved, imported: $imported })
      }
    }
  }

  $results
}

def sync-chesscom-update [username: string] {
  mut state = (load-sync-state $username)
  let missing = ($state.missing_archives | default [])

  if ($missing | is-empty) {
    { username: $username, updated: [], skipped: [] }
  } else {
    mut updated_results = []
    mut skipped_results = []

    for entry in $missing {
      let archive_id = if ($entry | describe) == "string" { $entry } else { $entry.archive_id }
      let retries = if ($entry | describe) == "string" { 0 } else { $entry.retries }
      
      if $retries >= 3 {
        print $'sync: giving up on ($archive_id) after ($retries) retries'
        $skipped_results = ($skipped_results | append { archive_id: $archive_id, skipped: true, reason: 'max retries reached' })
        continue
      }

      let parts = ($archive_id | split row '/')
      if ($parts | length) != 2 {
        $skipped_results = ($skipped_results | append { archive_id: $archive_id, skipped: true, reason: 'invalid archive id' })
      } else {
        let archive_url = $'https://api.chess.com/pub/player/($username)/games/($parts.0)/($parts.1)'
        let saved = (save-archive-pgn $username $archive_url)

        if $saved == null {
          $state = (update-sync-state $state $archive_id false ((date now) | into string))
          save-sync-state $username $state | ignore
          $skipped_results = ($skipped_results | append { archive_id: $archive_id, archive_url: $archive_url, skipped: true, reason: 'no pgn found' })
        } else {
          let imported = (import-games [$saved.file "chesscom"])
          $state = (update-sync-state $state $archive_id true ((date now) | into string))
          save-sync-state $username $state | ignore
          $updated_results = ($updated_results | append { archive_id: $archive_id, archive_url: $archive_url, skipped: false, saved: $saved, imported: $imported })
        }
      }
    }

    { username: $username, updated: $updated_results, skipped: $skipped_results }
  }
}

export def sync-chesscom-status [username: string] {
  load-sync-state $username
}

export def sync-games [args: list<string>] {
  if ($args | is-empty) {
    error make { msg: "sync requires a provider and username" }
  }

  let provider = ($args | get 0)
  let mode = (if ($args | length) > 1 { $args | get 1 } else { "latest" })
  let username = (if ($args | length) > 2 { $args | get 2 } else { error make { msg: "sync requires a username" } })

  match $provider {
    "chesscom" => {
      init-db
      if $mode == "all" {
        print $'sync: chesscom all ($username)'
        { provider: $provider, mode: $mode, username: $username, archives: (sync-chesscom-all $username) }
      } else if $mode == "update" {
        print $'sync: chesscom update ($username)'
        { provider: $provider, mode: $mode, username: $username, archives: (sync-chesscom-update $username) }
      } else {
        { provider: $provider, mode: $mode, username: $username, archive: (sync-chesscom-latest $username) }
      }
    }
    _ => { error make { msg: $'unknown sync provider: ($provider)' } }
  }
}
