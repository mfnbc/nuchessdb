use ./config.nu *
use ./db.nu *
use ./import.nu *

def sync-state-path [username: string] {
  $'./tmp/sync-progress-($username).nuon'
}

def default-sync-state [username: string] {
  {
    provider: 'chesscom'
    username: $username
    completed_archives: []
    missing_archives: []
    current_archive: null
    updated_at: null
  }
}

def load-sync-state [username: string] {
  let path = (sync-state-path $username)
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

def update-sync-state [state: record, archive_id: string, imported: bool, now: string] {
  let current_completed = ($state.completed_archives | default [])
  let current_missing = ($state.missing_archives | default [])

  if $imported {
    let remaining_missing = ($current_missing | where { |a| $a != $archive_id })
    $state
    | upsert completed_archives ($current_completed | append $archive_id | uniq)
    | upsert missing_archives $remaining_missing
    | upsert current_archive null
    | upsert updated_at $now
  } else {
    $state
    | upsert missing_archives ($current_missing | append $archive_id | uniq)
    | upsert current_archive null
    | upsert updated_at $now
  }
}

def clear-chesscom-sync-state [username: string] {
  let state_path = (sync-state-path $username)
  let raw_dir = $'./data/raw/chesscom/($username)'

  if ($state_path | path exists) {
    rm $state_path
  }

  if ($raw_dir | path exists) {
    rm -r $raw_dir
  }

  { username: $username, state_removed: $state_path, raw_removed: $raw_dir }
}

export def clean-sync-cache [] {
  let raw_dir = './data/raw/chesscom'
  let progress_files = (glob './tmp/sync-progress-*.nuon')

  if ($raw_dir | path exists) {
    rm -r $raw_dir
  }

  if ($progress_files | is-empty) == false {
    $progress_files | each { |path| rm $path }
  }

  { raw_removed: $raw_dir, progress_removed: $progress_files }
}

def load-chesscom-archives [username: string] {
  let fixture = ($env | get -o NUCHESSDB_TEST_ARCHIVES_JSON | default "")

  if ($fixture | is-empty) == false {
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

  if $archives == null {
    return null
  }

  let url = ($archives.archives | last)

  if $url == null {
    error make { msg: $'no chess.com archives found for ($username)' }
  }

  $url
}

def save-archive-pgn [username: string, archive_url: string] {
  let fixture_mode = ($env | get -o NUCHESSDB_TEST_PGN_MODE | default "")

  if $fixture_mode == "fixture" or $fixture_mode == "fixture-ready" {
    let archive_id = ($archive_url | split row "/" | last 2 | str join "-")
    let month = ($archive_url | split row "/" | last 2 | str join "/")
    let out_dir = $'./data/raw/chesscom/($username)'
    let out_file = $'($out_dir)/($archive_id).pgn'
    let fixture = ($env | get -o NUCHESSDB_TEST_PGN_FIXTURE | default './test-fixtures/chesscom/hikaru-game.pgn')

    if $fixture_mode == "fixture" and $month == '2024/03' {
      print $'sync: chesscom archive ($archive_id) no pgn found, skipping'
      null
    } else {
      mkdir $out_dir
      open $fixture | save --force $out_file
      { archive_url: $archive_url, pgn_url: $'($archive_url)/pgn', file: $out_file }
    }
  } else {
  let archive_id = ($archive_url | split row "/" | last 2 | str join "-")
  let pgn_url = $'($archive_url)/pgn'
  let out_dir = $'./data/raw/chesscom/($username)'
  let out_file = $'($out_dir)/($archive_id).pgn'
  let raw_pgn = (try { http get $pgn_url } catch {
    print $'sync: chesscom archive ($archive_id) no pgn found, skipping'
    null
  })

  if $raw_pgn == null {
    return null
  }

  mkdir $out_dir
  $raw_pgn | save --force $out_file

  { archive_url: $archive_url, pgn_url: $pgn_url, file: $out_file }
  }
}

def sync-chesscom-latest [username: string] {
  print $'sync: chesscom latest ($username)'
  let archive_url = (latest-chesscom-archive $username)
  let saved = (save-archive-pgn $username $archive_url)

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
    let completed = ($state.completed_archives | default [])

    if ($completed | any { |a| $a == $archive_id }) {
      print $'sync: chesscom all ($username) ($n)/($total) skip ($archive_id)'
      $results = ($results | append { archive_url: $archive_url, archive_id: $archive_id, skipped: true })
    } else {
      print $'sync: chesscom all ($username) ($n)/($total) import ($archive_id)'
      $state = ($state | upsert current_archive $archive_id)
      save-sync-state $username $state | ignore
      let saved = (save-archive-pgn $username $archive_url)
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
  let state = (load-sync-state $username)
  let missing = ($state.missing_archives | default [])

  if ($missing | is-empty) {
    { username: $username, updated: [], skipped: [] }
  } else {
    let archives = ($missing | each { |archive_id|
      let parts = ($archive_id | split row '/')
      if ($parts | length) != 2 {
        { archive_id: $archive_id, skipped: true, reason: 'invalid archive id' }
      } else {
        let archive_url = $'https://api.chess.com/pub/player/($username)/games/($parts.0)/($parts.1)'
        let saved = (save-archive-pgn $username $archive_url)

        if $saved == null {
          { archive_id: $archive_id, archive_url: $archive_url, skipped: true, reason: 'no pgn found' }
        } else {
          let imported = (import-games [$saved.file "chesscom"])
          { archive_id: $archive_id, archive_url: $archive_url, skipped: false, saved: $saved, imported: $imported }
        }
      }
    })

    let remaining_missing = ($archives | where skipped == true | get archive_id)
    let completed = ($state.completed_archives | default [])
    let finished_state = (
      $state
      | upsert completed_archives ($completed | append ($archives | where skipped == false | get archive_id) | uniq)
      | upsert missing_archives $remaining_missing
      | upsert current_archive null
      | upsert updated_at (date now)
    )

    save-sync-state $username $finished_state | ignore
    { username: $username, updated: ($archives | where skipped == false), skipped: ($archives | where skipped == true) }
  }
}

export def sync-chesscom-status [username: string] {
  load-sync-state $username
}

export def sync-state-transition-demo [] {
  let base = (default-sync-state 'hikaru')
  let months = ['2024/01' '2024/02' '2024/03' '2024/04' '2024/05']
  let missing_months = ['2024/02' '2024/04']
  let stamp = '2026-04-05T00:00:00Z'

  mut after_scanning = $base
  for month in $months {
    let is_missing = ($missing_months | any { |m| $m == $month })
    $after_scanning = (update-sync-state $after_scanning $month (if $is_missing { false } else { true }) $stamp)
  }

  let after_retry = (update-sync-state $after_scanning '2024/02' true $stamp)

  {
    scanned: $after_scanning,
    retried: $after_retry,
  }
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
