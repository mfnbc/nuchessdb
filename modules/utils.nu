export def sql-string [value: any] {
  if $value == null {
    "NULL"
  } else {
    let text = ($value | into string | str replace -a "'" "''")
    $"'($text)'"
  }
}

export def sql-int [value: any] {
  if $value == null {
    "NULL"
  } else {
    $value | into string
  }
}

export def bool-int [value: any] {
  if $value == null {
    "NULL"
  } else if $value {
    "1"
  } else {
    "0"
  }
}

# Split a list into non-overlapping chunks of at most chunk_size items.
export def chunks-of [chunk_size: int] {
  let rows = $in
  let total = ($rows | length)
  if $total == 0 { return [] }
  let num_chunks = (($total + $chunk_size - 1) // $chunk_size)
  seq 0 ($num_chunks - 1) | each { |i|
    $rows | skip ($i * $chunk_size) | first $chunk_size
  }
}
