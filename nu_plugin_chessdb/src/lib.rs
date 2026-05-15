pub mod chess;
pub mod core;
// critter_eval_cmd removed — undifferentiated alias for hugm-eval (BUG-7)
pub mod hugm_eval_cmd;
pub mod eval;
pub mod pgn_to_fens;
pub mod position_encoder;
pub mod process_corpus;
pub mod dataset_builder_cmd;
pub mod nnue_eval_cmd;
pub mod coach_derive_cmd;
pub mod utils;
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

    // Small, focused command surface including the evaluations
    fn commands(&self) -> Vec<Box<dyn nu_plugin::PluginCommand<Plugin = Self>>> {
        vec![
            Box::new(hugm_eval_cmd::HugmEval),
            // critter-eval removed — use hugm-eval instead
            Box::new(pgn_to_fens::PgnToBatch),
            Box::new(pgn_to_fens::PgnToFens),
            Box::new(pgn_to_fens::PgnScan),
            Box::new(process_corpus::ProcessCorpus),
            Box::new(dataset_builder_cmd::DatasetBuilder),
            Box::new(nnue_eval_cmd::NnueEval),
            Box::new(coach_derive_cmd::DeriveCoachSignals),
            Box::new(zobrist::Zobrist),
        ]
    }
}
