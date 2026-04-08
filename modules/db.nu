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
  let db = (open $db_path)
  try {
    $db | query db "BEGIN IMMEDIATE;" | ignore
    for stmt in ($statements | where { |stmt| not ($stmt | is-empty) }) {
      $db | query db $stmt | ignore
    }
    $db | query db "COMMIT;" | ignore
  } catch { |err|
    let _ = (try { $db | query db "ROLLBACK;" | ignore } catch { null })
    let msg = if ($err | columns | any { |c| $c == "msg" }) { $err.msg } else { $err | to text }
    error make { msg: $msg }
  }
}

# Verify that data/eco.json is present; error with recovery instructions if not.
def ensure-eco-data [] {
  let eco_path = "./data/eco.json"
  if not ($eco_path | path exists) {
    error make {
      msg: (
        "data/eco.json is missing.\n" +
        "It ships with the repository — restore it with:\n" +
        "  git checkout -- data/eco.json\n" +
        "Or re-clone the repository."
      )
    }
  }
}

export def init-db [] {
  let cfg = load-config
  let db_path = ($cfg.database.path)
  let schema_path = ($cfg.database.schema)
  let db_dir = ($db_path | path dirname)

  ensure-eco-data

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

  { database: $db_path, schema: $schema_path, status: "initialized", eco_data: "ok" }
}

export def clean-db [] {
  let cfg = load-config
  let db_path = ($cfg.database.path)

  if ($db_path | path exists) {
    rm $db_path
  }

  { database: $db_path, status: "removed" }
}
