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

export def sync-games [args: list<string>] {
  if ($args | is-empty) {
    error make { msg: "sync requires a provider and username" }
  }

  let provider = ($args | get 0)
  let username = (if ($args | length) > 1 { $args | get 1 } else { error make { msg: "sync requires a username" } })

  match $provider {
    "chesscom" => {
      init-db
      let archive_url = (latest-chesscom-archive $username)
      let saved = (save-archive-pgn $username $archive_url)
      let imported = (import-games [$saved.file "chesscom"])

      { provider: $provider, username: $username, archive_url: $archive_url, saved: $saved, imported: $imported }
    }
    _ => { error make { msg: $'unknown sync provider: ($provider)' } }
  }
}
