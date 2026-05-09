pub mod chess;
pub mod core;
pub mod pgn_to_fens;
pub mod zobrist;

use nu_plugin::Plugin;

/// Shared help-category string for all `chessdb *` plugin commands.
pub const PLUGIN_CATEGORY: &str = "chess";

pub struct ChessdbPlugin;

impl ChessdbPlugin {
    pub fn new() -> Self {
        Self
    }
}

impl Default for ChessdbPlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl Plugin for ChessdbPlugin {
    fn version(&self) -> String {
        env!("CARGO_PKG_VERSION").to_string()
    }

    // Keep a very small, focused command surface: PGN parsing + zobrist helper.
    fn commands(&self) -> Vec<Box<dyn nu_plugin::PluginCommand<Plugin = Self>>> {
        vec![
            Box::new(pgn_to_fens::PgnToBatch),
            Box::new(pgn_to_fens::PgnToFens),
            Box::new(pgn_to_fens::PgnScan),
            Box::new(zobrist::Zobrist),
        ]
    }
}
