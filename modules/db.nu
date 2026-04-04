use ./config.nu *
use ./query.nu *
use ./dynamic.nu *

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
  let db = (open $db_path)
  for stmt in $statements {
    $db | query db $stmt | ignore
  }
}

export def open-db [db_path: string] {
  open $db_path
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
  let columns = (open $db_path | query db "PRAGMA table_info(games)")
  let names = ($columns | get name)
  if (not ($names | any { |c| $c == "white_elo" })) {
    run-sql $db_path ["ALTER TABLE games ADD COLUMN white_elo INTEGER;"]
  }
  if (not ($names | any { |c| $c == "black_elo" })) {
    run-sql $db_path ["ALTER TABLE games ADD COLUMN black_elo INTEGER;"]
  }

  let _ = (refresh-critter-enrichment-queue)
  let _ = (refresh-dynamic-enrichment-queue)

  { database: $db_path, schema: $schema_path, status: "initialized" }
}
