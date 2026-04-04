use ./config.nu *

def eco-data [] {
  open ./data/eco.json
}

# Look up the ECO opening for a given FEN.
# Matches on the 4-field FEN prefix (board + side + castling + ep),
# ignoring halfmove clock and fullmove number.
# Returns the matching opening record, or null if none is found.
export def eco-lookup [fen: string] {
  let fen4 = ($fen | split row " " | first 4 | str join " ")
  let match = (eco-data | where fen == $fen4 | first -i 1)
  if ($match | is-empty) { null } else { $match | first }
}

# Enrich a table of positions with ECO opening classification.
# Expects the input table to have a `canonical_fen` column.
# Adds `eco_code` and `opening_name` columns to each row.
# Rows with no ECO match receive empty strings for those columns.
export def eco-classify [] {
  let openings = (eco-data)
  each { |row|
    let fen4 = ($row.canonical_fen | split row " " | first 4 | str join " ")
    let match = ($openings | where fen == $fen4 | first -i 1)
    if ($match | is-empty) {
      $row | insert eco_code "" | insert opening_name ""
    } else {
      $row | insert eco_code ($match | first | get eco_code) | insert opening_name ($match | first | get name)
    }
  }
}
