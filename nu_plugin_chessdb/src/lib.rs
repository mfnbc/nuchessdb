pub mod apply_san;
pub mod apply_uci;
pub mod attack_summary;
pub mod checker_summary;
pub mod chess;
pub mod core;
pub mod critter_eval_cmd;
pub mod encode_fen_cmd;
pub mod eval;
pub mod fen_info;
pub mod is_legal;
pub mod legal_moves;
pub mod mobility;
pub mod nnue_eval_cmd;
pub mod normalize_fen;
pub mod pgn_to_fens;
pub mod position_encoder;
pub mod san_to_uci;
pub mod uci_to_san;
pub mod zobrist;

use nu_plugin::Plugin;

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

    fn commands(&self) -> Vec<Box<dyn nu_plugin::PluginCommand<Plugin = Self>>> {
        vec![
            Box::new(apply_san::ApplySan),
            Box::new(apply_uci::ApplyUci),
            Box::new(attack_summary::AttackSummary),
            Box::new(checker_summary::CheckerSummary),
            Box::new(critter_eval_cmd::CritterEval),
            Box::new(encode_fen_cmd::EncodeFen),
            Box::new(fen_info::FenInfo),
            Box::new(is_legal::IsLegal),
            Box::new(legal_moves::LegalMoves),
            Box::new(mobility::Mobility),
            Box::new(nnue_eval_cmd::NnueEval),
            Box::new(normalize_fen::NormalizeFen),
            Box::new(pgn_to_fens::PgnToBatch),
            Box::new(pgn_to_fens::PgnToFens),
            Box::new(san_to_uci::SanToUci),
            Box::new(uci_to_san::UciToSan),
            Box::new(zobrist::Zobrist),
        ]
    }
}
