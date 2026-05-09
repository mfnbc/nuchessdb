use ./config.nu *
use ./db.nu *
use ./import.nu *

def sync-state-path [username: string] {
  $'./tmp/sync-progress-($username).nuon'
}

def default-sync-state [username: string] {
  {
    provider: 'chesscom',
    username: $username,
    completed_archives: [],
    missing_archives: [],
    current_archive: null,
    updated_at: null
  }
}

def load-sync-state [username: string] {
  let path = (sync-state-path $username)
  if ($path | path exists) {
    let state = (open $path)
    {
      provider: ($state | get -o provider | default 'chesscom'),
      username: ($state | get -o username | default $username),
      completed_archives: ($state | get -o completed_archives | default []),
      missing_archives: ($state | get -o missing_archives | default []),
      current_archive: ($state | get -o current_archive | default null),
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
    let remaining_missing = ($current_missing | where { |a| 
      (if ($a | describe) == "string" { $a } else { $a.archive_id }) != $archive_id 
    })
    $state
    | upsert completed_archives ($current_completed | append $archive_id | uniq)
    | upsert missing_archives $remaining_missing
    | upsert current_archive null
    | upsert updated_at $now
  } else {
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

def sync-chesscom-latest [username: string] {
  let archive_url = (latest-chesscom-archive $username)
  let saved = (save-archive-pgn $username $archive_url true)
  if $saved == null {
    { archive_url: $archive_url, skipped: true, reason: 'no pgn found' }
  } else {
    let imported = (import-pgn-file $saved.file "chesscom")
    { archive_url: $archive_url, saved: $saved, imported: $imported }
  }
}

def sync-chesscom-all [username: string] {
  let archives = (load-chesscom-archives $username)
  if $archives == null { return { username: $username, reason: 'archives unavailable' } }
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

    if $is_completed and not $is_last {
      $results = ($results | append { archive_url: $archive_url, archive_id: $archive_id, skipped: true })
    } else {
      print $'sync: chesscom all ($username) ($n)/($total) ($archive_id)'
      $state = ($state | upsert current_archive $archive_id)
      save-sync-state $username $state | ignore
      let saved = (save-archive-pgn $username $archive_url $is_last)
      if $saved == null {
        $state = (update-sync-state $state $archive_id false ((date now) | into string))
        save-sync-state $username $state | ignore
        $results = ($results | append { archive_url: $archive_url, archive_id: $archive_id, skipped: true, reason: 'no pgn found' })
      } else {
        let imported = (import-pgn-file $saved.file "chesscom")
        $state = (update-sync-state $state $archive_id true ((date now) | into string))
        save-sync-state $username $state | ignore
        $results = ($results | append { archive_url: $archive_url, archive_id: $archive_id, skipped: false, saved: $saved, imported: $imported })
      }
    }
  }
  $results
}

export def sync-games [args: list<string>] {
  let provider = ($args | get 0)
  let mode = (if ($args | length) > 1 { $args | get 1 } else { "latest" })
  let username = (if ($args | length) > 2 { $args | get 2 } else { "me" })
  init-db
  if $mode == "all" {
    { provider: $provider, mode: $mode, username: $username, archives: (sync-chesscom-all $username) }
  } else {
    { provider: $provider, mode: $mode, username: $username, archive: (sync-chesscom-latest $username) }
  }
}
