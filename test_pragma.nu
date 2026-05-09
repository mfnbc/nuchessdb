let db = "data/test.sqlite"
if ("data/test.sqlite" | path exists) { rm "data/test.sqlite" }
stor open
stor export --file-name $db
let conn = (open $db)
print "Testing PRAGMA..."
$conn | query db "PRAGMA foreign_keys = ON;" | ignore
print "PRAGMA success"
$conn | query db "CREATE TABLE test (id INTEGER PRIMARY KEY);" | ignore
print "Table creation success"
