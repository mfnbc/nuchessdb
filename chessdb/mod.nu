# chessdb.nu — chess database and coaching platform
#
# Usage:
#   use chessdb *
#   chess-init
#   chess-sync <chess.com-username>
#   chess-derive <username>
#   chess-profile <username>
#   chess-profile <username> | to json -r
#
# All commands accept --db <path> to override the default ./chess.db.
# The nu_plugin_chessdb plugin must be registered before use:
#   plugin add nu_plugin_chessdb/target/release/nu_plugin_chessdb

export use db.nu      [chess-init chess-status chess-seed-openings]
export use sync.nu    [chess-sync chess-recent chess-review chess-explore]
export use derive.nu  [chess-derive chess-validate]
export use profile.nu [
    chess-profile
    chess-profile-tactical
    chess-profile-precision
    chess-profile-position
    chess-profile-opening
]
