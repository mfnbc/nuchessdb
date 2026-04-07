/// Position encoder: converts a shakmaty Chess position to a 1024-element f32 feature vector.
///
/// Layout (total = 793 meaningful features, zero-padded to 1024):
///   0..768   piece-position one-hot (64 squares × 12 piece types)
///   768..775 game-state (4 castling + 1 en-passant + 1 side-to-move + 1 halfmove placeholder)
///   775..787 material balance (white/black count per piece type, 6×2 = 12)
///   787..791 king positional (white/black king file+rank, normalised 0..1, 4 features)
///   791..793 tactical summary (white/black piece count normalised, 2 features)
///   793..1024 zero padding
use shakmaty::{Chess, Color, Position, Role, Square};

pub const VECTOR_SIZE: usize = 1024;

/// Encode a position into a fixed-size feature vector.
pub fn encode_position(chess: &Chess) -> Vec<f32> {
    let mut features = vec![0.0f32; VECTOR_SIZE];
    let mut offset = 0;
    offset = encode_piece_positions(chess, &mut features, offset);
    offset = encode_game_state(chess, &mut features, offset);
    offset = encode_material_balance(chess, &mut features, offset);
    offset = encode_king_positional(chess, &mut features, offset);
    encode_tactical_summary(chess, &mut features, offset);
    features
}

/// 64 squares × 12 piece types (6 roles × 2 colors) = 768 features.
/// White pieces use indices 0..5, black pieces 6..11.
fn encode_piece_positions(chess: &Chess, features: &mut [f32], offset: usize) -> usize {
    let board = chess.board();
    for (sq_idx, sq) in Square::ALL.iter().enumerate() {
        if let Some(piece) = board.piece_at(*sq) {
            let role_idx = role_index(piece.role);
            let color_offset = if piece.color == Color::White { 0 } else { 6 };
            let feature_idx = offset + sq_idx * 12 + role_idx + color_offset;
            if feature_idx < features.len() {
                features[feature_idx] = 1.0;
            }
        }
    }
    offset + 768
}

/// 7 game-state features:
///   [0] white kingside castling
///   [1] white queenside castling
///   [2] black kingside castling
///   [3] black queenside castling
///   [4] en-passant available
///   [5] side to move (1.0 = white)
///   [6] halfmove clock placeholder (0.0)
fn encode_game_state(chess: &Chess, features: &mut [f32], offset: usize) -> usize {
    use shakmaty::{CastlingSide, Position};
    let castles = chess.castles();
    if offset + 7 <= features.len() {
        features[offset] = if castles.has(Color::White, CastlingSide::KingSide) {
            1.0
        } else {
            0.0
        };
        features[offset + 1] = if castles.has(Color::White, CastlingSide::QueenSide) {
            1.0
        } else {
            0.0
        };
        features[offset + 2] = if castles.has(Color::Black, CastlingSide::KingSide) {
            1.0
        } else {
            0.0
        };
        features[offset + 3] = if castles.has(Color::Black, CastlingSide::QueenSide) {
            1.0
        } else {
            0.0
        };
        features[offset + 4] = if chess.ep_square(shakmaty::EnPassantMode::Legal).is_some() {
            1.0
        } else {
            0.0
        };
        features[offset + 5] = if chess.turn() == Color::White {
            1.0
        } else {
            0.0
        };
        features[offset + 6] = 0.0; // halfmove clock not exposed directly; placeholder
    }
    offset + 7
}

/// 12 material-balance features: white count and black count for each of the 6 roles,
/// each normalised by dividing by 8.
fn encode_material_balance(chess: &Chess, features: &mut [f32], offset: usize) -> usize {
    let board = chess.board();
    let roles = [
        Role::Pawn,
        Role::Knight,
        Role::Bishop,
        Role::Rook,
        Role::Queen,
        Role::King,
    ];
    for (i, &role) in roles.iter().enumerate() {
        let white = (board.by_color(Color::White) & board.by_role(role)).count() as f32;
        let black = (board.by_color(Color::Black) & board.by_role(role)).count() as f32;
        let idx = offset + i * 2;
        if idx + 1 < features.len() {
            features[idx] = white / 8.0;
            features[idx + 1] = black / 8.0;
        }
    }
    offset + 12
}

/// 4 king-positional features: white king (file, rank) + black king (file, rank), each 0..1.
fn encode_king_positional(chess: &Chess, features: &mut [f32], offset: usize) -> usize {
    let board = chess.board();
    if offset + 4 <= features.len() {
        if let Some(wk) = board.king_of(Color::White) {
            features[offset] = u32::from(wk.file()) as f32 / 7.0;
            features[offset + 1] = u32::from(wk.rank()) as f32 / 7.0;
        }
        if let Some(bk) = board.king_of(Color::Black) {
            features[offset + 2] = u32::from(bk.file()) as f32 / 7.0;
            features[offset + 3] = u32::from(bk.rank()) as f32 / 7.0;
        }
    }
    offset + 4
}

/// 2 tactical-summary features: white piece count / 16 and black piece count / 16.
fn encode_tactical_summary(chess: &Chess, features: &mut [f32], offset: usize) -> usize {
    let board = chess.board();
    if offset + 2 <= features.len() {
        features[offset] = board.by_color(Color::White).count() as f32 / 16.0;
        features[offset + 1] = board.by_color(Color::Black).count() as f32 / 16.0;
    }
    offset + 2
}

fn role_index(role: Role) -> usize {
    match role {
        Role::Pawn => 0,
        Role::Knight => 1,
        Role::Bishop => 2,
        Role::Rook => 3,
        Role::Queen => 4,
        Role::King => 5,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use shakmaty::{fen::Fen, CastlingMode, Chess, Position};

    fn starting_chess() -> Chess {
        Fen::from_ascii(b"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
            .unwrap()
            .into_position(CastlingMode::Standard)
            .unwrap()
    }

    #[test]
    fn vector_length() {
        let chess = starting_chess();
        let v = encode_position(&chess);
        assert_eq!(v.len(), VECTOR_SIZE);
    }

    #[test]
    fn starting_position_has_nonzero_features() {
        let chess = starting_chess();
        let v = encode_position(&chess);
        assert!(v.iter().any(|&x| x > 0.0));
    }

    #[test]
    fn castling_rights_encoded() {
        let chess = starting_chess();
        let v = encode_position(&chess);
        // All 4 castling rights should be 1.0 at offset 768
        assert_eq!(v[768], 1.0); // white kingside
        assert_eq!(v[769], 1.0); // white queenside
        assert_eq!(v[770], 1.0); // black kingside
        assert_eq!(v[771], 1.0); // black queenside
    }

    #[test]
    fn side_to_move_white() {
        let chess = starting_chess();
        let v = encode_position(&chess);
        assert_eq!(v[773], 1.0); // side to move: white
    }
}
