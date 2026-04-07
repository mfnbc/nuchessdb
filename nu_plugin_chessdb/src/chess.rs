use nu_protocol::{LabeledError, Span};
use shakmaty::{fen::Fen, Chess};

pub fn fen_to_chess(fen_str: &str, span: Span) -> Result<Chess, LabeledError> {
    let fen: Fen = fen_str.parse().map_err(|e| {
        LabeledError::new(format!("Invalid FEN: {e}")).with_label("failed to parse FEN", span)
    })?;

    fen.into_position(shakmaty::CastlingMode::Standard)
        .map_err(|e| {
            LabeledError::new(format!("Invalid position: {e}"))
                .with_label("position is illegal", span)
        })
}
