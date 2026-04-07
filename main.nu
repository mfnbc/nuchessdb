#!/usr/bin/env nu

plugin use chessdb

use ./modules/cli.nu *

def main [...args] {
  run ($args | each { into string })
}
