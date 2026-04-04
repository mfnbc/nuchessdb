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
