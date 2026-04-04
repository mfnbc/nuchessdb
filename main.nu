#!/usr/bin/env nu

plugin use shakmaty

use ./modules/cli.nu *

def main [...args] {
  run ($args | each { into string })
}
