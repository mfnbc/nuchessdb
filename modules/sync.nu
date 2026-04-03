use ./config.nu *
use ./db.nu *
use ./import.nu *

def latest-chesscom-archive [username: string] {
  let archives = (http get $'https://api.chess.com/pub/player/($username)/games/archives')
  let url = ($archives.archives | last)

  if $url == null {
    error make { msg: $'no chess.com archives found for ($username)' }
  }

  $url
}

def save-archive-pgn [username: string, archive_url: string] {
  let archive_id = ($archive_url | split row "/" | last 2 | str join "-")
  let pgn_url = $'($archive_url)/pgn'
  let raw_pgn = (http get $pgn_url)
  let out_dir = $'./data/raw/chesscom/($username)'
  let out_file = $'($out_dir)/($archive_id).pgn'

  mkdir $out_dir
  $raw_pgn | save --force $out_file

  { archive_url: $archive_url, pgn_url: $pgn_url, file: $out_file }
}

def sync-chesscom-latest [username: string] {
  print $'sync: chesscom latest ($username)'
  let archive_url = (latest-chesscom-archive $username)
  let saved = (save-archive-pgn $username $archive_url)
  let imported = (import-games [$saved.file "chesscom"])

  { archive_url: $archive_url, saved: $saved, imported: $imported }
}

def sync-chesscom-all [username: string] {
  let archives = (http get $'https://api.chess.com/pub/player/($username)/games/archives')
  let total = ($archives.archives | length)

  $archives.archives
  | enumerate
  | each { |it|
      let archive_url = $it.item
      let n = ($it.index + 1)
      print $'sync: chesscom all ($username) ($n)/($total)'
      let saved = (save-archive-pgn $username $archive_url)
      let imported = (import-games [$saved.file "chesscom"])

      { archive_url: $archive_url, saved: $saved, imported: $imported }
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
      } else {
        { provider: $provider, mode: $mode, username: $username, archive: (sync-chesscom-latest $username) }
      }
    }
    _ => { error make { msg: $'unknown sync provider: ($provider)' } }
  }
}
