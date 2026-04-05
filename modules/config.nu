export def load-config [] {
  let path = ($env | get -o NUCHESSDB_CONFIG | default './config/nuchessdb.nuon')
  open $path
}
