#!/home/michael/.cargo/bin/nu

plugin use shakmaty

use ./modules/cli.nu *

def main [...args] {
  run $args
}
