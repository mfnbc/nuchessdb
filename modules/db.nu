use ./config.nu *

def ensure-sqlite-file [db_path: string] {
  let exists = ($db_path | path exists)

  if $exists {
    let kind = (try { open $db_path | describe } catch { "" })

    if $kind != "SQLiteDatabase" {
      stor open
      stor export --file-name $db_path
    }
  } else {
    stor open
    stor export --file-name $db_path
  }
}

def split-sql-statements [sql_text: string] {
  $sql_text
  | split row ";"
  | each { |stmt| $stmt | str trim }
  | where { |stmt| not ($stmt | is-empty) }
  | each { |stmt| $stmt + ";" }
}

export def run-sql [db_path: string, statements: list<string>] {
  for stmt in $statements {
    open $db_path | query db $stmt | ignore
  }
}

export def init-db [] {
  let cfg = load-config
  let db_path = ($cfg.database.path)
  let schema_path = ($cfg.database.schema)
  let db_dir = ($db_path | path dirname)

  mkdir $db_dir
  ensure-sqlite-file $db_path

  let schema = (open $schema_path)
  let statements = (split-sql-statements $schema)
  run-sql $db_path $statements

  { database: $db_path, schema: $schema_path, status: "initialized" }
}
