use serde::Serialize;

/// Reference to a piece on the board — human-readable, no bitboards.
#[derive(Debug, Clone, Serialize)]
pub struct PieceRef {
    pub role: String,     // "Knight", "Bishop", "Rook", "Queen", "Pawn", "King"
    pub color: String,    // "white", "black"
    pub square: String,   // "d5", "e4", "a1"
}

impl PieceRef {
    pub fn notation(&self) -> String {
        let role_char = match self.role.as_str() {
            "Knight" => "N", "Bishop" => "B", "Rook" => "R",
            "Queen" => "Q", "King" => "K", _ => "",
        };
        format!("{}{}", role_char, self.square)
    }
}

// ── Tactical concepts ──

#[derive(Debug, Clone, Serialize)]
pub struct Fork {
    pub attacker: PieceRef,
    pub targets: Vec<PieceRef>,
    /// The target that cannot escape — proven by legal-move simulation.
    /// If set, shakmaty confirmed no legal move saves this piece from
    /// the fork attacker, making it a predicted hanging piece.
    pub hangs: Option<PieceRef>,
}

#[derive(Debug, Clone, Serialize)]
pub enum PinType { Absolute, Relative }

#[derive(Debug, Clone, Serialize)]
pub struct Pin {
    pub attacker: PieceRef,
    pub pinned: PieceRef,
    pub shielded: PieceRef,
    pub pin_type: PinType,
}

#[derive(Debug, Clone, Serialize)]
pub struct Skewer {
    pub attacker: PieceRef,
    pub front: PieceRef,
    pub behind: PieceRef,
}

#[derive(Debug, Clone, Serialize)]
pub struct DiscoveredAttack {
    pub mover: PieceRef,
    pub attacker: PieceRef,
    pub target: PieceRef,
}

#[derive(Debug, Clone, Serialize)]
pub struct HangingPiece {
    pub piece: PieceRef,
    pub attacker_count: u8,
}

// ── Positional concepts ──

#[derive(Debug, Clone, Serialize)]
pub struct Outpost {
    pub piece: PieceRef,
    pub supported_by: PieceRef,
}

#[derive(Debug, Clone, Serialize)]
pub struct OpenFile {
    pub file: String,
    pub rook_count: u8,
    pub color: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct PassedPawn {
    pub square: String,
    pub rank: u8,
    pub color: String,
    pub is_protected: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct PawnIsland {
    pub files: Vec<String>,
    pub count: u8,
    pub color: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct KingExposure {
    pub color: String,
    pub shelter_files: u8,
    pub attacker_count: u8,
}

#[derive(Debug, Clone, Serialize)]
pub struct DoubledPawn {
    pub file: String,
    pub count: u8,
    pub color: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct IsolatedPawn {
    pub square: String,
    pub color: String,
}

// ── Material concepts ──

#[derive(Debug, Clone, Serialize, Default)]
pub struct PieceCounts {
    pub queens: u8,
    pub rooks: u8,
    pub bishops: u8,
    pub knights: u8,
    pub pawns: u8,
}

#[derive(Debug, Clone, Serialize)]
pub struct MaterialBalance {
    pub white: PieceCounts,
    pub black: PieceCounts,
    pub centipawns: i64,
    pub bishop_pair_white: bool,
    pub bishop_pair_black: bool,
}

// ── Development concepts ──

#[derive(Debug, Clone, Serialize)]
pub struct DevelopmentInfo {
    pub color: String,
    pub undeveloped_pieces: Vec<PieceRef>,
    pub space_advantage: i64,
}

// ── Other concepts ──

#[derive(Debug, Clone, Serialize)]
pub struct PawnBreak {
    pub square: String,
    pub color: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct MinorityAttack {
    pub color: String,
    pub strength: i64,
}

/// A ranked concept extracted from a SensorReport.
/// This is what the Concept Filter layer produces for the LLM Coach.
#[derive(Debug, Clone, Serialize)]
pub struct RankedConcept {
    pub name: String,
    pub severity: i64,
    pub elo_min: i32,
    pub data: serde_json::Value,
}
