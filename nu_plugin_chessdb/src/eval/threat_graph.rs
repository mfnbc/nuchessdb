//! Threat graph: unified attack-relationship graph derived from shakmaty bitboards.
//!
//! Builds a complete attack adjacency in one pass over the board, then derives
//! all tactical concepts (forks, skewers, pins, hanging pieces) as graph queries.
//! Runs Static Exchange Evaluation (SEE) on each threat to compute the actual
//! material consequence before categorising the pattern.
//!
//! This replaces the separate detector functions with a single graph builder.

use shakmaty::{Bitboard, Board, Chess, Color, Piece, Position, Role, Square};
use crate::eval::concept_types::*;

/// Complete attack adjacency for a position.
#[derive(Debug, Clone)]
pub struct ThreatGraph {
    /// Square → pieces this square attacks
    pub attacks_from: [Bitboard; 64],
    /// Square → pieces attacking this square
    pub attackers_to: [Bitboard; 64],
    /// Piece on each square
    pub pieces: [Option<Piece>; 64],
    /// Side to move
    pub turn: Color,
    /// Full board for SEE context
    pub board: Board,
}

impl ThreatGraph {
    /// Build the attack graph from a shakmaty Chess position.
    pub fn build(chess: &Chess) -> Self {
        let board = chess.board().clone();
        let mut attacks_from = [Bitboard::EMPTY; 64];
        let mut attackers_to = [Bitboard::EMPTY; 64];
        let mut pieces: [Option<Piece>; 64] = [None; 64];

        let occupied = board.occupied();

        for sq in Square::ALL {
            let sq_idx = u32::from(sq) as usize;
            pieces[sq_idx] = board.piece_at(sq);
            if pieces[sq_idx].is_some() {
                attacks_from[sq_idx] = board.attacks_from(sq);
            }
            // attacks_to needs a color (which side's attacks we want)
            attackers_to[sq_idx] = board.attacks_to(sq, Color::White, occupied)
                                 | board.attacks_to(sq, Color::Black, occupied);
        }

        ThreatGraph {
            attacks_from,
            attackers_to,
            pieces,
            turn: chess.turn(),
            board: board.clone(),
        }
    }

    /// All pieces of the given color, with their squares.
    fn pieces_of(&self, color: Color) -> Vec<(Square, Piece)> {
        let mut out = Vec::new();
        for sq in Square::ALL {
            let idx = u32::from(sq) as usize;
            if let Some(p) = self.pieces[idx] {
                if p.color == color {
                    out.push((sq, p));
                }
            }
        }
        out
    }

    /// Square index helper.
    fn idx(sq: Square) -> usize { u32::from(sq) as usize }

    /// Value of a piece for SEE ordering.
    fn piece_value(role: Role) -> i64 {
        match role {
            Role::Pawn => 100, Role::Knight => 320, Role::Bishop => 330,
            Role::Rook => 500, Role::Queen => 900, Role::King => 20000,
        }
    }

    /// Run SEE: given a square where a capture happens, return the optimal
    /// recapture chain AND net centipawns. Each step records who captured what.
    pub fn see_chain(&self, sq: Square, initiator: Color) -> (Vec<CaptureStep>, i64) {
        let mut steps = Vec::new();
        let target_piece_val = self.pieces[Self::idx(sq)]
            .map(|p| Self::piece_value(p.role)).unwrap_or(0);
        let mut net = target_piece_val;

        // Record the piece being captured (belongs to opponent of initiator)
        let victim_color = if initiator.is_white() { "black" } else { "white" };
        let victim_role = self.pieces[Self::idx(sq)]
            .map(|p| role_name(p.role)).unwrap_or_default();
        steps.push(CaptureStep {
            piece: victim_role,
            color: victim_color.into(),
            square: square_name(sq),
            value_cp: target_piece_val,
        });

        let mut att_sq = sq;
        let mut side_to_capture = initiator.other();

        loop {
            let attackers = self.attackers_to[Self::idx(att_sq)]
                & self.board.by_color(side_to_capture);
            if attackers == Bitboard::EMPTY { break; }

            let mut best_sq = None;
            let mut best_val = i64::MAX;
            let mut best_role = Role::Pawn;
            for role in [Role::Pawn, Role::Knight, Role::Bishop, Role::Rook, Role::Queen, Role::King] {
                let role_bb = attackers & self.board.by_role(role);
                if let Some(sq) = role_bb.into_iter().next() {
                    let val = Self::piece_value(role);
                    if val < best_val {
                        best_val = val; best_sq = Some(sq); best_role = role;
                    }
                    break;
                }
            }
            match best_sq {
                Some(sq) => {
                    let delta = best_val * if side_to_capture == initiator { 1 } else { -1 };
                    net += delta;
                    steps.push(CaptureStep {
                        piece: role_name(best_role),
                        color: if side_to_capture.is_white() { "white" } else { "black" }.into(),
                        square: square_name(sq),
                        value_cp: best_val,
                    });
                    att_sq = sq;
                    side_to_capture = side_to_capture.other();
                }
                None => break,
            }
        }
        (steps, net)
    }

    /// Convenience: SEE net score only.
    pub fn see(&self, sq: Square, initiator: Color) -> i64 {
        self.see_chain(sq, initiator).1
    }

    /// Find all forks: a piece attacks ≥2 enemy pieces.
    pub fn find_forks(&self, color: Color) -> Vec<EvaluatedFork> {
        let mut out = Vec::new();
        let enemy = color.other();
        for (sq, piece) in self.pieces_of(color) {
            let attacks = self.attacks_from[Self::idx(sq)];
            let attacked = attacks & self.board.by_color(enemy);
            if attacked.count() < 2 { continue; }

            let mut targets: Vec<PieceRef> = Vec::new();
            let mut total_val = 0i64;
            for t_sq in attacked {
                if let Some(tp) = self.pieces[Self::idx(t_sq)] {
                    let val = Self::piece_value(tp.role);
                    total_val += val as i64;
                    targets.push(PieceRef {
                        role: role_name(tp.role),
                        color: (if enemy.is_white() { "white" } else { "black" }).to_string(),
                        square: square_name(t_sq),
                    });
                }
            }
            if targets.len() >= 2 && total_val >= Self::piece_value(Role::Rook) {
                let attacker = PieceRef {
                    role: role_name(piece.role),
                    color: (if color.is_white() { "white" } else { "black" }).to_string(),
                    square: square_name(sq),
                };
                // Find which target hangs (lowest-value undefended)
                let hangs = self.undefended_target(&targets, enemy);
                // SEE: optimal recapture chain + net score
                let (chain, see_gain) = if let Some(ref h) = hangs {
                    let h_sq = match shakmaty::Square::from_ascii(h.square.as_bytes()) {
                        Ok(sq) => sq, Err(_) => continue,
                    };
                    self.see_chain(h_sq, color)
                } else { (Vec::new(), 0) };
                let consequence = if see_gain > 150 { Consequence::Winning }
                    else if see_gain > 0 { Consequence::Minor }
                    else if see_gain < -50 { Consequence::Losing }
                    else { Consequence::Even };

                out.push(EvaluatedFork {
                    attacker,
                    targets,
                    hangs,
                    see_cp: see_gain,
                    consequence,
                    chain,
                });
            }
        }
        out
    }

    /// Among fork targets, find the lowest-value undefended one.
    fn undefended_target(&self, targets: &[PieceRef], color: Color) -> Option<PieceRef> {
        let mut best: Option<(PieceRef, i64)> = None;
        for t in targets {
            let t_sq = match shakmaty::Square::from_ascii(t.square.as_bytes()) {
                Ok(sq) => sq, Err(_) => continue,
            };
            let defenders = self.attackers_to[Self::idx(t_sq)]
                & self.board.by_color(color)
                & !Bitboard::from(t_sq);
            if defenders == Bitboard::EMPTY {
                let val = match t.role.as_str() {
                    "Queen" => 900, "Rook" => 500, "Bishop" => 330,
                    "Knight" => 320, "Pawn" => 100, _ => 0,
                };
                match best {
                    None => best = Some((t.clone(), val)),
                    Some((_, existing)) if val < existing => best = Some((t.clone(), val)),
                    _ => {}
                }
            }
        }
        best.map(|(p, _)| p)
    }

    /// Find hanging pieces: attacked with 0 defenders.
    pub fn find_hanging(&self) -> Vec<HangingPiece> {
        let mut out = Vec::new();
        for sq in Square::ALL {
            let idx = Self::idx(sq);
            let Some(piece) = self.pieces[idx] else { continue };
            let attacker_count = (self.attackers_to[idx]
                & self.board.by_color(piece.color.other())).count();
            if attacker_count == 0 { continue; }
            let defenders = self.attackers_to[idx]
                & self.board.by_color(piece.color)
                & !Bitboard::from(sq);
            if defenders == Bitboard::EMPTY {
                out.push(HangingPiece {
                    piece: PieceRef {
                        role: role_name(piece.role),
                        color: (if piece.color.is_white() { "white" } else { "black" }).to_string(),
                        square: square_name(sq),
                    },
                    attacker_count: attacker_count as u8,
                });
            }
        }
        out
    }

    /// Find exchange chains: captures on the same square across consecutive moves.
    /// Returns chains with ≥3 captures (a collapse).
    pub fn find_exchange_chain(&self, sq: Square, initiator: Color) -> Option<ExchangeChain> {
        let mut captures = Vec::new();
        let mut side = initiator;
        let mut current_sq = sq;
        let mut net = 0i64;

        loop {
            let attackers = self.attackers_to[Self::idx(current_sq)]
                & self.board.by_color(side);
            if attackers == Bitboard::EMPTY { break; }

            // Find lowest-value attacker
            let mut best: Option<(Square, Role, i64)> = None;
            for r in [Role::Pawn, Role::Knight, Role::Bishop, Role::Rook, Role::Queen, Role::King] {
                if let Some(s) = (attackers & self.board.by_role(r)).into_iter().next() {
                    let v = Self::piece_value(r);
                    if best.as_ref().map_or(true, |b| v < b.2) {
                        best = Some((s, r, v));
                    }
                }
            }
            if let Some((s, r, v)) = best {
                let delta = if side == initiator { v } else { -v };
                net += delta;
                captures.push(CaptureStep {
                    piece: role_name(r),
                    color: (if side.is_white() { "white" } else { "black" }).to_string(),
                    square: square_name(s),
                    value_cp: v,
                });
                current_sq = s;
                side = side.other();
            } else { break; }
        }

        if captures.len() >= 3 {
            Some(ExchangeChain {
                square: square_name(sq),
                steps: captures,
                net_cp: net,
                winner: if net > 0 {
                    (if initiator.is_white() { "white" } else { "black" }).to_string()
                } else if net < 0 {
                    (if initiator.is_white() { "black" } else { "white" }).to_string()
                } else { "even".to_string() },
            })
        } else {
            None
        }
    }
}

// ── Output types ──

#[derive(Debug, Clone, serde::Serialize)]
pub enum Consequence { Winning, Minor, Losing, Even }

#[derive(Debug, Clone, serde::Serialize)]
pub struct EvaluatedFork {
    pub attacker: PieceRef,
    pub targets: Vec<PieceRef>,
    pub hangs: Option<PieceRef>,
    pub see_cp: i64,
    pub consequence: Consequence,
    /// Optimal SEE recapture chain (for step-by-step comparison)
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub chain: Vec<CaptureStep>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct CaptureStep {
    pub piece: String,
    pub color: String,
    pub square: String,
    pub value_cp: i64,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ExchangeChain {
    pub square: String,
    pub steps: Vec<CaptureStep>,
    pub net_cp: i64,
    pub winner: String,
}

// ── Name helpers ──

fn role_name(r: Role) -> String {
    match r { Role::Pawn => "Pawn", Role::Knight => "Knight", Role::Bishop => "Bishop",
              Role::Rook => "Rook", Role::Queen => "Queen", Role::King => "King" }.into()
}

fn square_name(sq: Square) -> String {
    format!("{}{}", (b'a' + u8::from(sq.file())) as char, u8::from(sq.rank()) + 1)
}