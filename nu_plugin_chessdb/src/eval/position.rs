use anyhow::{Context, Result};
use serde::Serialize;
use shakmaty::{attacks, fen::Fen, Bitboard, Chess, Color, File, Position, Rank, Role, Square};

use crate::eval::concept_types::*;
use crate::eval::sensor::{TacticalReport, PositionalReport, SensorReport, AggregatedScores, MaterialConceptReport};

// Configurable constants (GUESS values) collected here for easier tuning.
const TACTICAL_BASE_PINS: i64 = 50;
const TACTICAL_BASE_FORKS: i64 = 80;
const TACTICAL_BASE_SKEWERS: i64 = 40;
const TACTICAL_BASE_DISC: i64 = 60;
const PHASE_FACTOR_DEN: i64 = 40;

const ROOK_OPEN_FILE_BONUS: i64 = 25;
const DOUBLED_ROOK_BONUS: i64 = 20;
const ROOK_SEVENTH_BONUS: i64 = 30;

const OUTPOST_WEIGHT: i64 = 40;

// Tropism piece weights
const TROPISM_QUEEN: i64 = 90;
const TROPISM_ROOK: i64 = 50;
const TROPISM_BISHOP: i64 = 35;
const TROPISM_KNIGHT: i64 = 30;
const TROPISM_PAWN: i64 = 10;

// Piece values used for fork/skewer heuristics
const VAL_QUEEN: i64 = 900;
const VAL_ROOK: i64 = 500;
const VAL_BISHOP: i64 = 330;
const VAL_KNIGHT: i64 = 320;
const VAL_PAWN: i64 = 100;

// Pawn-structure default weights
const PAWN_MAJORITY_WEIGHT: i64 = 20;
const PAWN_BREAK_WEIGHT: i64 = 30;
const MINORITY_ATTACK_WEIGHT: i64 = 35;

// Mobility weight (per-square)
const PIECE_MOBILITY_WEIGHT: i64 = 5;

use once_cell::sync::Lazy;
use std::sync::RwLock;
use serde::Deserialize;

#[derive(Debug, Clone)]
pub struct Weights {
    pub tactical_base_pins: i64,
    pub tactical_base_forks: i64,
    pub tactical_base_skewers: i64,
    pub tactical_base_disc: i64,
    pub phase_factor_den: i64,
    pub rook_open_file_bonus: i64,
    pub doubled_rook_bonus: i64,
    pub rook_seventh_bonus: i64,
    pub outpost_weight: i64,
    pub tropism_queen: i64,
    pub tropism_rook: i64,
    pub tropism_bishop: i64,
    pub tropism_knight: i64,
    pub tropism_pawn: i64,
    pub val_queen: i64,
    pub val_rook: i64,
    pub val_bishop: i64,
    pub val_knight: i64,
    pub val_pawn: i64,
    pub pawn_majority_weight: i64,
    pub pawn_break_weight: i64,
    pub minority_attack_weight: i64,
    pub piece_mobility_weight: i64,
    pub phase_bias_material: i64,
    pub phase_bias_pawn_structure: i64,
    pub phase_bias_piece_activity: i64,
    pub phase_bias_king_safety: i64,
    pub phase_bias_passed_pawns: i64,
    pub phase_bias_development: i64,
    pub phase_bias_vector_features: i64,
    pub phase_bias_strategic: i64,
}

impl Default for Weights {
    fn default() -> Self {
        Weights {
            tactical_base_pins: TACTICAL_BASE_PINS,
            tactical_base_forks: TACTICAL_BASE_FORKS,
            tactical_base_skewers: TACTICAL_BASE_SKEWERS,
            tactical_base_disc: TACTICAL_BASE_DISC,
            phase_factor_den: PHASE_FACTOR_DEN,
            rook_open_file_bonus: ROOK_OPEN_FILE_BONUS,
            doubled_rook_bonus: DOUBLED_ROOK_BONUS,
            rook_seventh_bonus: ROOK_SEVENTH_BONUS,
            outpost_weight: OUTPOST_WEIGHT,
            tropism_queen: TROPISM_QUEEN,
            tropism_rook: TROPISM_ROOK,
            tropism_bishop: TROPISM_BISHOP,
            tropism_knight: TROPISM_KNIGHT,
            tropism_pawn: TROPISM_PAWN,
            val_queen: VAL_QUEEN,
            val_rook: VAL_ROOK,
            val_bishop: VAL_BISHOP,
            val_knight: VAL_KNIGHT,
            val_pawn: VAL_PAWN,
            pawn_majority_weight: PAWN_MAJORITY_WEIGHT,
            pawn_break_weight: PAWN_BREAK_WEIGHT,
            minority_attack_weight: MINORITY_ATTACK_WEIGHT,
            piece_mobility_weight: PIECE_MOBILITY_WEIGHT,
            phase_bias_material: 0,
            phase_bias_pawn_structure: 0,
            phase_bias_piece_activity: 0,
            phase_bias_king_safety: 0,
            phase_bias_passed_pawns: 0,
            phase_bias_development: 0,
            phase_bias_vector_features: 0,
            phase_bias_strategic: 0,
        }
    }
}

#[derive(Deserialize)]
struct PartialWeights {
    tactical_base_pins: Option<i64>,
    tactical_base_forks: Option<i64>,
    tactical_base_skewers: Option<i64>,
    tactical_base_disc: Option<i64>,
    phase_factor_den: Option<i64>,
    rook_open_file_bonus: Option<i64>,
    doubled_rook_bonus: Option<i64>,
    rook_seventh_bonus: Option<i64>,
    outpost_weight: Option<i64>,
    tropism_queen: Option<i64>,
    tropism_rook: Option<i64>,
    tropism_bishop: Option<i64>,
    tropism_knight: Option<i64>,
    tropism_pawn: Option<i64>,
    val_queen: Option<i64>,
    val_rook: Option<i64>,
    val_bishop: Option<i64>,
    val_knight: Option<i64>,
    val_pawn: Option<i64>,
    pawn_majority_weight: Option<i64>,
    pawn_break_weight: Option<i64>,
    minority_attack_weight: Option<i64>,
    piece_mobility_weight: Option<i64>,
    phase_bias_material: Option<i64>,
    phase_bias_pawn_structure: Option<i64>,
    phase_bias_piece_activity: Option<i64>,
    phase_bias_king_safety: Option<i64>,
    phase_bias_passed_pawns: Option<i64>,
    phase_bias_development: Option<i64>,
    phase_bias_vector_features: Option<i64>,
    phase_bias_strategic: Option<i64>,
}

static WEIGHTS: Lazy<RwLock<Weights>> = Lazy::new(|| RwLock::new(Weights::default()));

fn weights() -> Weights {
    WEIGHTS.read().expect("weights lock").clone()
}

/// Load weights from a JSON file and override defaults. Keys match struct field names.
pub fn set_weights_from_file(path: &str) -> Result<(), String> {
    let s = std::fs::read_to_string(path).map_err(|e| format!("could not read weights file: {}", e))?;
    let p: PartialWeights = serde_json::from_str(&s).map_err(|e| format!("could not parse weights JSON: {}", e))?;
    let mut w = WEIGHTS.write().map_err(|e| format!("lock error: {:?}", e))?;
    if let Some(v) = p.tactical_base_pins { w.tactical_base_pins = v }
    if let Some(v) = p.tactical_base_forks { w.tactical_base_forks = v }
    if let Some(v) = p.tactical_base_skewers { w.tactical_base_skewers = v }
    if let Some(v) = p.tactical_base_disc { w.tactical_base_disc = v }
    if let Some(v) = p.phase_factor_den { w.phase_factor_den = v }
    if let Some(v) = p.rook_open_file_bonus { w.rook_open_file_bonus = v }
    if let Some(v) = p.doubled_rook_bonus { w.doubled_rook_bonus = v }
    if let Some(v) = p.rook_seventh_bonus { w.rook_seventh_bonus = v }
    if let Some(v) = p.outpost_weight { w.outpost_weight = v }
    if let Some(v) = p.tropism_queen { w.tropism_queen = v }
    if let Some(v) = p.tropism_rook { w.tropism_rook = v }
    if let Some(v) = p.tropism_bishop { w.tropism_bishop = v }
    if let Some(v) = p.tropism_knight { w.tropism_knight = v }
    if let Some(v) = p.tropism_pawn { w.tropism_pawn = v }
    if let Some(v) = p.val_queen { w.val_queen = v }
    if let Some(v) = p.val_rook { w.val_rook = v }
    if let Some(v) = p.val_bishop { w.val_bishop = v }
    if let Some(v) = p.val_knight { w.val_knight = v }
    if let Some(v) = p.val_pawn { w.val_pawn = v }
    if let Some(v) = p.pawn_majority_weight { w.pawn_majority_weight = v }
    if let Some(v) = p.pawn_break_weight { w.pawn_break_weight = v }
    if let Some(v) = p.minority_attack_weight { w.minority_attack_weight = v }
    if let Some(v) = p.piece_mobility_weight { w.piece_mobility_weight = v }
    if let Some(v) = p.phase_bias_material { w.phase_bias_material = v }
    if let Some(v) = p.phase_bias_pawn_structure { w.phase_bias_pawn_structure = v }
    if let Some(v) = p.phase_bias_piece_activity { w.phase_bias_piece_activity = v }
    if let Some(v) = p.phase_bias_king_safety { w.phase_bias_king_safety = v }
    if let Some(v) = p.phase_bias_passed_pawns { w.phase_bias_passed_pawns = v }
    if let Some(v) = p.phase_bias_development { w.phase_bias_development = v }
    if let Some(v) = p.phase_bias_vector_features { w.phase_bias_vector_features = v }
    if let Some(v) = p.phase_bias_strategic { w.phase_bias_strategic = v }
    Ok(())
}

#[derive(Debug, Serialize)]
pub struct PositionRecord {
    pub fen: String,
    pub normalized_fen: String,
    pub side_to_move: String,
    pub phase: u8,
    pub final_score: i64,
    pub engine_score: Option<i64>,
    pub legal: LegalInfo,
    pub groups: EvalGroups,
    pub checks: Checks,
    pub sensor_report: SensorReport,
}

#[derive(Debug, Serialize)]
pub struct LegalInfo {
    pub is_legal: bool,
    pub is_check: bool,
    pub is_checkmate: bool,
    pub is_stalemate: bool,
    pub is_insufficient_material: bool,
    pub legal_move_count: usize,
}

#[derive(Debug, Serialize, Default)]
pub struct GroupValue {
    pub mg: i64,
    pub eg: i64,
    pub blended: i64,
    pub terms: serde_json::Map<String, serde_json::Value>,
}

#[derive(Debug, Serialize, Default)]
pub struct ScalarValue {
    pub value: i64,
    pub factor: i64,
}

#[derive(Debug, Serialize, Default)]
pub struct EvalGroups {
    pub material: GroupValue,
    pub pawn_structure: GroupValue,
    pub piece_activity: GroupValue,
    pub king_safety: GroupValue,
    pub passed_pawns: GroupValue,
    pub development: GroupValue,
    pub vector_features: GroupValue,
    pub strategic: GroupValue,
    pub tactical: GroupValue,
    pub scaling: ScalarValue,
    pub drawishness: ScalarValue,
    pub override_: ScalarValue,
    pub material_total: ScalarValue,
    pub positional_total: ScalarValue,
    pub tactical_total: ScalarValue,
}

#[derive(Debug, Serialize, Default)]
pub struct Checks {
    pub sum_groups: i64,
    pub matches_final: bool,
    pub delta: Option<i64>,
}

fn piece_count(board: &shakmaty::Board, color: Color, role: Role) -> i64 {
    (board.by_color(color) & board.by_role(role)).count() as i64
}

fn bitboard_count(bb: Bitboard) -> i64 {
    bb.count() as i64
}

fn biased_phase(phase: u8, bias: i64) -> u8 {
    ((phase as i64 + bias).clamp(0, 32)) as u8
}

fn phase_split(value: i64, phase: u8) -> (i64, i64) {
    let bias = (i64::from(phase).saturating_sub(16).abs() * value.abs()) / 64;
    (value + bias, value - bias)
}

/// Centralized phase blending: Critter's scale() function.
///   blended = (mg * phase + eg * (32 - phase)) / 32
/// At phase 32 (opening): blended ≈ mg (positional)
/// At phase 0  (endgame): blended ≈ eg (material)
fn blend(mg: i64, eg: i64, phase: u8) -> i64 {
    let p = phase as i64;
    (mg * p + eg * (32 - p)) / 32
}

fn count_on_home(board: &shakmaty::Board, color: Color, role: Role, home: Bitboard) -> i64 {
    (board.by_color(color) & board.by_role(role) & home).count() as i64
}

fn king_ring(board: &shakmaty::Board, color: Color) -> Bitboard {
    let Some(king_sq) = board.king_of(color) else {
        return Bitboard::EMPTY;
    };
    attacks::king_attacks(king_sq) | Bitboard::from(king_sq)
}

fn pawn_attack_mask(board: &shakmaty::Board, color: Color) -> Bitboard {
    let pawns = board.by_color(color) & board.by_role(Role::Pawn);
    let mut atk = Bitboard::EMPTY;
    for sq in pawns {
        atk |= attacks::pawn_attacks(color, sq);
    }
    atk
}

pub fn compute_phase(board: &shakmaty::Board) -> u8 {
    let white_minor = piece_count(board, Color::White, Role::Knight)
        + piece_count(board, Color::White, Role::Bishop);
    let black_minor = piece_count(board, Color::Black, Role::Knight)
        + piece_count(board, Color::Black, Role::Bishop);
    let white_major = 2 * piece_count(board, Color::White, Role::Rook)
        + 4 * piece_count(board, Color::White, Role::Queen);
    let black_major = 2 * piece_count(board, Color::Black, Role::Rook)
        + 4 * piece_count(board, Color::Black, Role::Queen);
    (white_minor + black_minor + white_major + black_major).min(32) as u8
}

fn material_score(board: &shakmaty::Board, phase: u8) -> GroupValue {
    // Phase-dependent material adjustment coefficients, indexed by game phase (0..=32).
    // Each row: [unused0, unused1, unused2, unused3, unused4, bishop_pair, np_bonus, rp_penalty,
    //            bn_vs_rp, redundant_r, redundant_qr]
    // Material table ported from Critter 1.6a (battle-tested engine values).
    // Columns: Q_val, R_val, B_val, N_val, P_val, bishop_pair, np_bonus,
    //          rp_penalty, bn_vs_rp, redundant_r, redundant_qr
    let coeff = [
        [3004, 1533, 910, 875, 298, 118, 13,  0, 13, 82, 41],
        [2964, 1515, 899, 864, 293, 117, 12, 1, 14, 81, 40],
        [2923, 1496, 888, 854, 289, 116, 12, 1, 16, 79, 40],
        [2882, 1477, 877, 843, 284, 114, 12, 2, 18, 78, 39],
        [2841, 1458, 866, 832, 280, 113, 12, 3, 19, 77, 38],
        [2800, 1439, 855, 821, 275, 112, 11, 3, 21, 76, 38],
        [2759, 1420, 844, 811, 271, 110, 11, 4, 22, 74, 37],
        [2719, 1402, 833, 800, 266, 109, 11, 4, 24, 73, 36],
        [2678, 1383, 822, 789, 262, 108, 10, 5, 26, 72, 36],
        [2653, 1367, 817, 783, 259, 106, 10, 5, 26, 70, 35],
        [2629, 1351, 812, 777, 256, 105, 10, 6, 27, 69, 35],
        [2604, 1336, 808, 770, 253, 103, 9, 6, 28, 68, 34],
        [2580, 1320, 803, 764, 250, 102, 9, 6, 29, 67, 33],
        [2555, 1304, 798, 758, 247, 101, 9, 7, 30, 65, 33],
        [2531, 1288, 793, 752, 244, 99, 8, 7, 30, 64, 32],
        [2506, 1273, 789, 746, 241, 98, 8, 7, 31, 63, 31],
        [2482, 1257, 784, 740, 238, 97, 8, 8, 32, 61, 31],
        [2457, 1241, 779, 733, 235, 95, 7, 8, 33, 60, 30],
        [2433, 1226, 774, 727, 232, 94, 7, 8, 34, 59, 29],
        [2408, 1210, 770, 721, 229, 93, 7, 9, 34, 58, 29],
        [2384, 1194, 765, 715, 226, 91, 6, 9, 35, 56, 28],
        [2359, 1178, 760, 709, 223, 90, 6, 9, 36, 55, 28],
        [2335, 1163, 755, 703, 220, 89, 6, 10, 37, 54, 27],
        [2310, 1147, 751, 696, 217, 87, 5, 10, 38, 52, 26],
        [2286, 1131, 746, 690, 214, 86, 5, 10, 38, 51, 26],
        [2261, 1117, 741, 686, 211, 85, 4, 11, 40, 50, 25],
        [2237, 1103, 736, 681, 208, 83, 4, 11, 42, 49, 24],
        [2212, 1089, 732, 676, 205, 82, 3, 11, 43, 47, 24],
        [2188, 1075, 727, 672, 202, 81, 3, 12, 45, 46, 23],
        [2163, 1061, 722, 667, 199, 79, 2, 12, 46, 45, 22],
        [2139, 1046, 717, 663, 196, 78, 1, 12, 48, 44, 22],
        [2115, 1032, 713, 658, 193, 77, 1, 12, 50, 42, 21],
        [2090, 1018, 708, 653, 190, 75, 0, 13, 51, 41, 20],
    ][phase as usize];

    let white = |role: Role, value: i64| piece_count(board, Color::White, role) * value;
    let black = |role: Role, value: i64| piece_count(board, Color::Black, role) * value;

    // mg = opening (phase 32) — positional play dominates, pieces worth less
    let mg = (white(Role::Queen, 2090)
        + white(Role::Rook, 1018)
        + white(Role::Bishop, 708)
        + white(Role::Knight, 653)
        + white(Role::Pawn, 190))
        - (black(Role::Queen, 2090)
            + black(Role::Rook, 1018)
            + black(Role::Bishop, 708)
            + black(Role::Knight, 653)
            + black(Role::Pawn, 190));

    // eg = endgame (phase 0) — material is decisive, pieces worth more
    let eg = (white(Role::Queen, 3004)
        + white(Role::Rook, 1533)
        + white(Role::Bishop, 910)
        + white(Role::Knight, 875)
        + white(Role::Pawn, 298))
        - (black(Role::Queen, 3004)
            + black(Role::Rook, 1533)
            + black(Role::Bishop, 910)
            + black(Role::Knight, 875)
            + black(Role::Pawn, 298));

    let bishop_pair = if piece_count(board, Color::White, Role::Bishop) >= 2 {
        coeff[5]
    } else {
        0
    } - if piece_count(board, Color::Black, Role::Bishop) >= 2 {
        coeff[5]
    } else {
        0
    };

    let rp_penalty = -((piece_count(board, Color::White, Role::Pawn) - 5)
        * piece_count(board, Color::White, Role::Rook)
        * coeff[7])
        + ((piece_count(board, Color::Black, Role::Pawn) - 5)
            * piece_count(board, Color::Black, Role::Rook)
            * coeff[7]);

    let np_bonus = ((piece_count(board, Color::White, Role::Pawn) - 5)
        * piece_count(board, Color::White, Role::Knight)
        * coeff[6])
        - ((piece_count(board, Color::Black, Role::Pawn) - 5)
            * piece_count(board, Color::Black, Role::Knight)
            * coeff[6]);

    let bn_vs_rp = if (piece_count(board, Color::White, Role::Knight)
        + piece_count(board, Color::White, Role::Bishop))
        != (piece_count(board, Color::Black, Role::Knight)
            + piece_count(board, Color::Black, Role::Bishop))
    {
        if (piece_count(board, Color::White, Role::Knight)
            + piece_count(board, Color::White, Role::Bishop))
            > (piece_count(board, Color::Black, Role::Knight)
                + piece_count(board, Color::Black, Role::Bishop))
        {
            coeff[8]
        } else {
            -coeff[8]
        }
    } else {
        0
    };

    let redundant_r = -if piece_count(board, Color::White, Role::Rook) >= 2 {
        coeff[9]
    } else {
        0
    } + if piece_count(board, Color::Black, Role::Rook) >= 2 {
        coeff[9]
    } else {
        0
    };

    let redundant_qr = -if piece_count(board, Color::White, Role::Queen)
        + piece_count(board, Color::White, Role::Rook)
        >= 2
    {
        coeff[10]
    } else {
        0
    } + if piece_count(board, Color::Black, Role::Queen)
        + piece_count(board, Color::Black, Role::Rook)
        >= 2
    {
        coeff[10]
    } else {
        0
    };

    let adjustments = bishop_pair + rp_penalty + np_bonus + bn_vs_rp + redundant_r + redundant_qr;
    let blended = blend(mg, eg, phase) + adjustments;

    let mut terms = serde_json::Map::new();
    terms.insert(
        "white_queens".into(),
        serde_json::Value::from(piece_count(board, Color::White, Role::Queen)),
    );
    terms.insert(
        "black_queens".into(),
        serde_json::Value::from(piece_count(board, Color::Black, Role::Queen)),
    );
    terms.insert(
        "white_rooks".into(),
        serde_json::Value::from(piece_count(board, Color::White, Role::Rook)),
    );
    terms.insert(
        "black_rooks".into(),
        serde_json::Value::from(piece_count(board, Color::Black, Role::Rook)),
    );
    terms.insert(
        "white_bishops".into(),
        serde_json::Value::from(piece_count(board, Color::White, Role::Bishop)),
    );
    terms.insert(
        "black_bishops".into(),
        serde_json::Value::from(piece_count(board, Color::Black, Role::Bishop)),
    );
    terms.insert(
        "white_knights".into(),
        serde_json::Value::from(piece_count(board, Color::White, Role::Knight)),
    );
    terms.insert(
        "black_knights".into(),
        serde_json::Value::from(piece_count(board, Color::Black, Role::Knight)),
    );
    terms.insert(
        "white_pawns".into(),
        serde_json::Value::from(piece_count(board, Color::White, Role::Pawn)),
    );
    terms.insert(
        "black_pawns".into(),
        serde_json::Value::from(piece_count(board, Color::Black, Role::Pawn)),
    );
    terms.insert("bishop_pair".into(), serde_json::Value::from(bishop_pair));
    terms.insert("rp_penalty".into(), serde_json::Value::from(rp_penalty));
    terms.insert("np_bonus".into(), serde_json::Value::from(np_bonus));
    terms.insert("bn_vs_rp".into(), serde_json::Value::from(bn_vs_rp));
    terms.insert("redundant_r".into(), serde_json::Value::from(redundant_r));
    terms.insert("redundant_qr".into(), serde_json::Value::from(redundant_qr));
    terms.insert("adjustments".into(), serde_json::Value::from(adjustments));

    GroupValue { mg, eg, blended, terms }
}

fn count_undeveloped(board: &shakmaty::Board, color: Color) -> i64 {
    let knight_home = color.fold_wb(
        Bitboard::from(Square::B1) | Bitboard::from(Square::G1),
        Bitboard::from(Square::B8) | Bitboard::from(Square::G8),
    );
    let bishop_home = color.fold_wb(
        Bitboard::from(Square::C1) | Bitboard::from(Square::F1),
        Bitboard::from(Square::C8) | Bitboard::from(Square::F8),
    );
    count_on_home(board, color, Role::Knight, knight_home)
        + count_on_home(board, color, Role::Bishop, bishop_home)
}

fn passed_pawn_mask(board: &shakmaty::Board, color: Color) -> Bitboard {
    let pawns = board.by_color(color) & board.by_role(Role::Pawn);
    let opp_pawns = board.by_color(color.other()) & board.by_role(Role::Pawn);
    let mut passed = Bitboard::EMPTY;
    for sq in pawns {
        let mut front_span = in_front(color, sq);
        if let Some(f) = sq.file().offset(-1) {
            front_span |= in_front(color, Square::from_coords(f, sq.rank()));
        }
        if let Some(f) = sq.file().offset(1) {
            front_span |= in_front(color, Square::from_coords(f, sq.rank()));
        }
        if (opp_pawns & front_span) == Bitboard::EMPTY {
            passed |= Bitboard::from(sq);
        }
    }
    passed
}

fn pawn_structure_score(
    board: &shakmaty::Board,
    color: Color,
    phase: u8,
) -> (i64, serde_json::Map<String, serde_json::Value>) {
    let own = board.by_color(color) & board.by_role(Role::Pawn);
    let opp = board.by_color(color.other()) & board.by_role(Role::Pawn);
    let mut score = 0;
    let mut isolated = 0;
    let mut doubled = 0;
    let mut candidate = 0;
    let mut weak = 0;
    let mut passed = 0;
    let mut chain = 0;
    let mut files = [false; 8];
    let step = if color.is_white() { 1 } else { -1 };

    let passed_bb = passed_pawn_mask(board, color);

    for sq in own {
        let file = sq.file();
        let rank = sq.rank();
        let idx = usize::from(u8::from(file));
        files[idx] = true;

        let file_bb = Bitboard::from(file);
        let adjacent_own = [file.offset(-1), file.offset(1)]
            .into_iter()
            .flatten()
            .map(Bitboard::from)
            .fold(Bitboard::EMPTY, |acc, bb| acc | (own & bb));
        let same_file_others = (own & file_bb) ^ Bitboard::from(sq);
        let open_file = (own | opp) & in_front(color, sq) == Bitboard::EMPTY;

        if adjacent_own == Bitboard::EMPTY {
            isolated += 1;
            score -= if open_file {
                if phase >= 16 {
                    28
                } else {
                    36
                }
            } else if phase >= 16 {
                20
            } else {
                28
            };
        }

        if same_file_others != Bitboard::EMPTY {
            doubled += 1;
            score -= if open_file {
                if phase >= 16 {
                    12
                } else {
                    16
                }
            } else if phase >= 16 {
                8
            } else {
                12
            };
        }

        let support_rank = if color.is_white() {
            rank.offset(-1)
        } else {
            rank.offset(1)
        };
        let support = [file.offset(-1), file.offset(1)]
            .into_iter()
            .flatten()
            .flat_map(|f| support_rank.map(|r| Bitboard::from(Square::from_coords(f, r))))
            .fold(Bitboard::EMPTY, |acc, bb| acc | (own & bb));
        if support != Bitboard::EMPTY {
            chain += 1;
        }

        let passed_here = (passed_bb & Bitboard::from(sq)) != Bitboard::EMPTY;

        if passed_here {
            passed += 1;
        } else {
            let mut own_ahead = 0;
            let mut opp_ahead = 0;
            for df in [-1, 1] {
                if let Some(f) = file.offset(df) {
                    let mut r = rank;
                    while let Some(next_r) = r.offset(step) {
                        r = next_r;
                        let bb = Bitboard::from(Square::from_coords(f, r));
                        if (own & bb) != Bitboard::EMPTY {
                            own_ahead += 1;
                        }
                        if (opp & bb) != Bitboard::EMPTY {
                            opp_ahead += 1;
                        }
                    }
                }
            }
            if own_ahead >= opp_ahead && own_ahead > 0 {
                candidate += 1;
                score += 6 + i64::from(phase) / 4;
            } else if adjacent_own == Bitboard::EMPTY && opp_ahead > 0 {
                weak += 1;
                score -= if phase >= 16 { 13 } else { 19 };
            }
        }
    }

    let islands = files
        .into_iter()
        .fold((0_i64, false), |(count, prev), cur| {
            let count = if cur && !prev { count + 1 } else { count };
            (count, cur)
        })
        .0;
    if islands > 1 {
        score -= (islands - 1) * 7;
    }

    if files.iter().all(|&has| has) {
        score -= 10;
    }

    let mut terms = serde_json::Map::new();
    terms.insert("isolated".into(), serde_json::Value::from(isolated));
    terms.insert("doubled".into(), serde_json::Value::from(doubled));
    terms.insert("candidate".into(), serde_json::Value::from(candidate));
    terms.insert("weak".into(), serde_json::Value::from(weak));
    terms.insert("chain".into(), serde_json::Value::from(chain));
    terms.insert(
        "open_files".into(),
        serde_json::Value::from(files.iter().filter(|&&has| has).count() as i64),
    );
    terms.insert("passed".into(), serde_json::Value::from(passed));
    terms.insert("islands".into(), serde_json::Value::from(islands));

    // --- Pawn-majority / flank counts ---
    let mut own_files_count = [0_i64; 8];
    let mut opp_files_count = [0_i64; 8];
    for f in 0..8 {
        let file_mask = Bitboard::from(File::new(f));
        let idx = f as usize;
        own_files_count[idx] = (own & file_mask).count() as i64;
        opp_files_count[idx] = (opp & file_mask).count() as i64;
    }
    let own_qs = own_files_count[0] + own_files_count[1] + own_files_count[2];
    let opp_qs = opp_files_count[0] + opp_files_count[1] + opp_files_count[2];
    let own_center = own_files_count[3] + own_files_count[4];
    let opp_center = opp_files_count[3] + opp_files_count[4];
    let own_ks = own_files_count[5] + own_files_count[6] + own_files_count[7];
    let opp_ks = opp_files_count[5] + opp_files_count[6] + opp_files_count[7];

    terms.insert("queenside_count".into(), serde_json::Value::from(own_qs));
    terms.insert("queenside_opp".into(), serde_json::Value::from(opp_qs));
    terms.insert("center_count".into(), serde_json::Value::from(own_center));
    terms.insert("center_opp".into(), serde_json::Value::from(opp_center));
    terms.insert("kingside_count".into(), serde_json::Value::from(own_ks));
    terms.insert("kingside_opp".into(), serde_json::Value::from(opp_ks));

    let w = weights();
    let maj_qs = own_qs - opp_qs;
    let maj_center = own_center - opp_center;
    let maj_ks = own_ks - opp_ks;
    score += maj_qs * w.pawn_majority_weight + maj_center * w.pawn_majority_weight + maj_ks * w.pawn_majority_weight;

    terms.insert(
        "majority_queenside".into(),
        serde_json::Value::from(if own_qs > opp_qs { 1 } else { 0 }),
    );
    terms.insert(
        "majority_center".into(),
        serde_json::Value::from(if own_center > opp_center { 1 } else { 0 }),
    );
    terms.insert(
        "majority_kingside".into(),
        serde_json::Value::from(if own_ks > opp_ks { 1 } else { 0 }),
    );

    // --- Pawn-break detection (simple passed-pawn creating pushes/captures) ---
    let mut break_count = 0_i64;
    let mut break_examples: Vec<serde_json::Value> = Vec::new();
    let opp_pawns_bb = board.by_color(color.other()) & board.by_role(Role::Pawn);
    for sq in own {
        let file = sq.file();
        let rank = sq.rank();
        // push one
        if let Some(next_rank) = if color.is_white() { rank.offset(1) } else { rank.offset(-1) } {
            let to = Square::from_coords(file, next_rank);
            if (board.occupied() & Bitboard::from(to)) == Bitboard::EMPTY {
                let front = in_front(color, to);
                if (opp_pawns_bb & front) == Bitboard::EMPTY {
                    break_count += 1;
                    let mut map = serde_json::Map::new();
                    map.insert("pawn".into(), serde_json::Value::from(piece_square_name(board, sq)));
                    map.insert("to".into(), serde_json::Value::from(to.to_string()));
                    map.insert("kind".into(), serde_json::Value::from("push"));
                    break_examples.push(serde_json::Value::Object(map));
                }
            }
        }
        // captures
        for df in [-1_i8, 1_i8] {
            if let Some(f) = file.offset(df as i32) {
                if let Some(next_rank) = if color.is_white() { rank.offset(1) } else { rank.offset(-1) } {
                    let to = Square::from_coords(f, next_rank);
                    if (board.by_color(color.other()) & Bitboard::from(to)).any() {
                        let front = in_front(color, to);
                        if (opp_pawns_bb & front) == Bitboard::EMPTY {
                            break_count += 1;
                            let mut map = serde_json::Map::new();
                            map.insert("pawn".into(), serde_json::Value::from(piece_square_name(board, sq)));
                            map.insert("to".into(), serde_json::Value::from(to.to_string()));
                            map.insert("kind".into(), serde_json::Value::from("capture"));
                            break_examples.push(serde_json::Value::Object(map));
                        }
                    }
                }
            }
        }
    }
    score += break_count * w.pawn_break_weight;
    terms.insert("pawn_breaks".into(), serde_json::Value::from(break_count));
    if !break_examples.is_empty() {
        terms.insert("pawn_break_examples".into(), serde_json::Value::Array(break_examples));
    }

    // --- Minority attack potential (advanced template + strength heuristic) ---
    let mut minority_flag = 0_i64;
    let mut minority_strength = 0_i64;
    let mut minority_examples: Vec<serde_json::Value> = Vec::new();
    if own_qs > opp_qs && opp_files_count[1] > 0 && (opp_files_count[0] > 0 || opp_files_count[2] > 0) {
        // compute simple vulnerability metrics
        let mut opp_pawns_on_qs = 0_i64;
        let mut opp_defended = 0_i64;
        let opp_color = color.other();
        for f in 0..3 {
            let file_mask = Bitboard::from(File::new(f));
            for sq in board.by_color(opp_color) & board.by_role(Role::Pawn) & file_mask {
                opp_pawns_on_qs += 1;
                // is this pawn defended by another opponent pawn?
                let def_by_pawn = (pawn_attack_mask(board, opp_color) & Bitboard::from(sq)).any();
                if def_by_pawn {
                    opp_defended += 1;
                }
            }
        }

        // candidate target squares for minority (b4, b5, c4, c5) — generic useful targets
        let targets = vec![Square::B4, Square::B5, Square::C4, Square::C5];
        let mut holes = 0_i64;
        let mut empty_targets: Vec<String> = Vec::new();
        for &t in &targets {
            if (board.occupied() & Bitboard::from(t)) == Bitboard::EMPTY {
                holes += 1;
                empty_targets.push(t.to_string());
            }
        }

        // strength heuristic: base diff scaled by vulnerabilities and holes
        let base = (own_qs - opp_qs).max(1);
        let vuln = (opp_pawns_on_qs - opp_defended).max(0);
        minority_strength = base * (1 + holes + vuln);

        minority_flag = 1;
        score += minority_strength * w.minority_attack_weight; // scale

        let mut m = serde_json::Map::new();
        m.insert("flank".into(), serde_json::Value::from("queenside"));
        m.insert("ours".into(), serde_json::Value::from(own_qs));
        m.insert("theirs".into(), serde_json::Value::from(opp_qs));
        m.insert("holes".into(), serde_json::Value::from(holes));
        m.insert("vulnerability".into(), serde_json::Value::from(vuln));
        m.insert(
            "targets".into(),
            serde_json::Value::Array(empty_targets.into_iter().map(serde_json::Value::from).collect()),
        );
        terms.insert("minority_attack_example".into(), serde_json::Value::Object(m.clone()));
        minority_examples.push(serde_json::Value::Object(m));
    }
    terms.insert("minority_attack".into(), serde_json::Value::from(minority_flag));
    terms.insert("minority_attack_strength".into(), serde_json::Value::from(minority_strength));
    if !minority_examples.is_empty() {
        terms.insert("minority_attack_examples".into(), serde_json::Value::Array(minority_examples));
    }

    (score, terms)
}

fn passed_pawn_score(
    board: &shakmaty::Board,
    color: Color,
) -> (i64, serde_json::Map<String, serde_json::Value>) {
    let mut score = 0;
    let mut count = 0;

    for sq in passed_pawn_mask(board, color) {
        count += 1;
        let rank = sq.rank();
        let advance = if color.is_white() {
            u32::from(rank)
        } else {
            7 - u32::from(rank)
        };
        score += 20 + i64::from(advance) * 12;
        if advance >= 4 {
            score += 18;
        }
        if advance >= 5 {
            score += 24;
        }
    }

    let mut terms = serde_json::Map::new();
    terms.insert("passed_count".into(), serde_json::Value::from(count));
    (score, terms)
}

// _phase is kept for potential future phase-dependent king safety tuning but is
// not currently used inside this function.
fn king_safety_score(board: &shakmaty::Board, color: Color, in_check: bool, _phase: u8) -> i64 {
    let king_sq = match board.king_of(color) {
        Some(sq) => sq,
        None => return 0,
    };

    let mut score = 0;
    if in_check {
        score -= 80;
    }

    let attackers = board.attacks_to(king_sq, color.other(), board.occupied());
    let danger = (attackers.count() as i64).pow(2).min(50);
    score -= danger * 5;

    let own_pawns = board.by_color(color) & board.by_role(Role::Pawn);
    let enemy_pawns = board.by_color(color.other()) & board.by_role(Role::Pawn);
    let file = king_sq.file();
    for df in -1..=1 {
        if let Some(f) = file.offset(df) {
            let mut shield_rank = if color.is_white() {
                Rank::First
            } else {
                Rank::Eighth
            };
            let mut storm_rank = shield_rank;
            for r in 0..8 {
                let rank = Rank::new(r as u32);
                let sq = Square::from_coords(f, rank);
                if (own_pawns & Bitboard::from(sq)) != Bitboard::EMPTY {
                    shield_rank = rank;
                }
                if (enemy_pawns & Bitboard::from(sq)) != Bitboard::EMPTY {
                    storm_rank = rank;
                    break;
                }
            }

            let shield = if color.is_white() {
                u8::from(shield_rank)
            } else {
                7 - u8::from(shield_rank)
            };
            let storm = if color.is_white() {
                u8::from(storm_rank)
            } else {
                7 - u8::from(storm_rank)
            };
            score += [77, 0, 13, 38, 51, 64, 64, 64][shield as usize];
            score += [13, 0, 90, 38, 13, 0, 0, 0][storm as usize];
        }
    }

    score
}

fn development_score(board: &shakmaty::Board, color: Color) -> i64 {
    const NOT_DEVELOPED: [i64; 16] = [
        0, 3, 10, 15, 25, 38, 51, 77, 69, 79, 89, 100, 115, 115, 115, 115,
    ];
    let undeveloped = count_undeveloped(board, color).min(15) as usize;
    -NOT_DEVELOPED[undeveloped]
}

fn development_space_score(board: &shakmaty::Board, color: Color, phase: u8) -> i64 {
    let own_pawns = board.by_color(color) & board.by_role(Role::Pawn);
    let enemy_pawn_attacks = pawn_attack_mask(board, color.other());
    let enemy_attacks = board.attacks_to(
        board.king_of(color).unwrap_or(if color.is_white() {
            Square::E1
        } else {
            Square::E8
        }),
        color.other(),
        board.occupied(),
    );
    let own_attacks = board.attacks_to(
        board.king_of(color.other()).unwrap_or(if color.is_white() {
            Square::E8
        } else {
            Square::E1
        }),
        color,
        board.occupied(),
    );

    let base_mask = Bitboard::from(Square::C4)
        | Bitboard::from(Square::D4)
        | Bitboard::from(Square::E4)
        | Bitboard::from(Square::F4)
        | Bitboard::from(Square::C5)
        | Bitboard::from(Square::D5)
        | Bitboard::from(Square::E5)
        | Bitboard::from(Square::F5);

    let safe = base_mask & !(own_pawns | enemy_pawn_attacks | (enemy_attacks & !own_attacks));
    let pawns = board.by_color(color) & board.by_role(Role::Pawn);
    let mut shifted = pawns;
    if color.is_white() {
        shifted |= shifted.shift(8);
        shifted |= shifted.shift(16);
    } else {
        shifted |= shifted.shift(-8);
        shifted |= shifted.shift(-16);
    }

    bitboard_count(safe) * i64::from(phase.max(1)) * (bitboard_count(shifted) + 1) / 8
}

fn in_front(color: Color, sq: Square) -> Bitboard {
    let sq_bb = Bitboard::from(sq);
    let (s1, s2, s4) = if color.is_white() {
        (8_i32, 16, 32)
    } else {
        (-8_i32, -16, -32)
    };
    let mut bb = sq_bb;
    bb |= bb.shift(s1);
    bb |= bb.shift(s2);
    bb |= bb.shift(s4);
    bb ^ sq_bb
}

fn piece_activity_score(
    board: &shakmaty::Board,
    color: Color,
    phase: u8,
    pawn_safe: Bitboard,
    king_ring_bb: Bitboard,
) -> (i64, serde_json::Map<String, serde_json::Value>) {
    let mut score = 0;
    let occupied = board.occupied();
    let enemy = board.by_color(color.other());
    let enemy_king = board.king_of(color.other());
    let w = weights();

    let mut knight_score = 0;
    for sq in board.by_color(color) & board.by_role(Role::Knight) {
        let atk = attacks::knight_attacks(sq);
        let mut local = 0;
        local += 15 * (atk & in_front(color, sq)).count() as i64;
        if (atk & king_ring_bb) != Bitboard::EMPTY {
            local += 10;
        }
        if (Bitboard::from(sq) & Bitboard::CENTER) != Bitboard::EMPTY {
            local += 8;
        }
        if (atk & pawn_safe & enemy.intersect(board.by_role(Role::Pawn))).any() {
            local += 9;
        }
        if let Some(ksq) = enemy_king {
            if (atk & Bitboard::from(ksq)) != Bitboard::EMPTY {
                local += 12;
            }
        }
        if (atk & enemy.intersect(board.by_role(Role::Rook) | board.by_role(Role::Queen))).any() {
            local += 10;
        }
        if (atk
            & board
                .by_color(color.other())
                .intersect(board.by_role(Role::Pawn)))
        .any()
        {
            local -= 13;
        }
        if (atk & board.by_color(color).intersect(board.by_role(Role::Pawn))).count() == 0 {
            local -= 18;
        }
        if color.is_white() {
            if sq.rank() == Rank::First {
                local -= 10;
            }
        } else if sq.rank() == Rank::Eighth {
            local -= 10;
        }
        knight_score += local;
    }

    let mut bishop_score = 0;
    for sq in board.by_color(color) & board.by_role(Role::Bishop) {
        let atk = attacks::bishop_attacks(sq, occupied);
        let mut local = 0;
        local += 12 * (atk & in_front(color, sq)).count() as i64;
        if (atk & king_ring_bb) != Bitboard::EMPTY {
            local += 13;
        }
        if (atk
            & board
                .by_color(color.other())
                .intersect(board.by_role(Role::Pawn)))
        .any()
        {
            local += 7;
        }
        if (atk
            & board
                .by_color(color.other())
                .intersect(board.by_role(Role::Knight)))
        .any()
        {
            local += 13;
        }
        if (atk
            & (board
                .by_color(color.other())
                .intersect(board.by_role(Role::Rook))
                | board
                    .by_color(color.other())
                    .intersect(board.by_role(Role::Queen))))
        .any()
        {
            local += 18;
        }
        if (atk
            & board
                .by_color(color.other())
                .intersect(board.by_role(Role::Pawn)))
        .any()
        {
            local -= 13;
        }
        if color.is_white() {
            if sq.rank() == Rank::First {
                local -= 13;
            }
        } else if sq.rank() == Rank::Eighth {
            local -= 13;
        }
        bishop_score += local;
    }

    let mut rook_score = 0;
    let mut open_file_controlled = 0;
    let mut rook_on_seventh = 0;
    for sq in board.by_color(color) & board.by_role(Role::Rook) {
        let atk = attacks::rook_attacks(sq, occupied);
        let mut local = 0;
        local += 5 * (atk & in_front(color, sq)).count() as i64;
        if (atk & king_ring_bb) != Bitboard::EMPTY {
            local += 8;
        }
        if (atk
            & board
                .by_color(color.other())
                .intersect(board.by_role(Role::Pawn)))
        .any()
        {
            local += 8;
        }
        if (atk
            & board
                .by_color(color.other())
                .intersect(board.by_role(Role::Knight) | board.by_role(Role::Bishop)))
        .any()
        {
            local += 13;
        }
        if (atk
            & board
                .by_color(color.other())
                .intersect(board.by_role(Role::Queen)))
        .any()
        {
            local += 13;
        }
        if (atk & board.by_color(color).intersect(board.by_role(Role::Pawn))).count() == 0 {
            local += 15;
        }
        // Identify open file: file has no pawns of either color
        let file_mask = Bitboard::from(sq.file());
        let pawns_on_file = (board.by_role(Role::Pawn) & file_mask).any();
        if !pawns_on_file {
            open_file_controlled += 1;
            local += w.rook_open_file_bonus; // configurable
        }
        if color.is_white() {
            if sq.rank() == Rank::Seventh {
                local += w.rook_seventh_bonus;
                rook_on_seventh += 1;
            } else if sq.rank() == Rank::Eighth || sq.rank() == Rank::Sixth {
                local += 13;
            }
        } else if sq.rank() == Rank::Second {
            local += w.rook_seventh_bonus;
            rook_on_seventh += 1;
        } else if sq.rank() == Rank::First || sq.rank() == Rank::Third {
            local += 13;
        }
        rook_score += local;
    }

    let mut doubled_rooks = 0;
    for f in 0..8 {
        let file_mask = Bitboard::from(File::new(f));
        let cnt = (board.by_color(color) & board.by_role(Role::Rook) & file_mask).count();
        if cnt >= 2 {
            doubled_rooks += 1;
            rook_score += w.doubled_rook_bonus; // configurable
        }
    }

    let mut queen_score = 0;
    for sq in board.by_color(color) & board.by_role(Role::Queen) {
        let atk = attacks::queen_attacks(sq, occupied);
        let mut local = 0;
        local += 5 * (atk & !board.by_color(color)).count() as i64 / 2;
        if (atk & king_ring_bb) != Bitboard::EMPTY {
            local += 13;
        }
        if color.is_white() {
            if sq.rank() == Rank::Seventh {
                local += 13;
            }
        } else if sq.rank() == Rank::Second {
            local += 13;
        }
        if let Some(ksq) = enemy_king {
            if (atk & Bitboard::from(ksq)) != Bitboard::EMPTY {
                local += 18;
            }
        }
        queen_score += local;
    }

    score += knight_score + bishop_score + rook_score + queen_score;

    // Mobility counters per piece (counts of attacked squares excluding own-occupied squares)
    let mut knight_mob = 0_i64;
    let mut bishop_mob = 0_i64;
    let mut rook_mob = 0_i64;
    let mut queen_mob = 0_i64;
    let mut pawn_mob = 0_i64;

    for sq in board.by_color(color) & board.by_role(Role::Knight) {
        knight_mob += (board.attacks_from(sq) & !board.by_color(color)).count() as i64;
    }
    for sq in board.by_color(color) & board.by_role(Role::Bishop) {
        bishop_mob += (board.attacks_from(sq) & !board.by_color(color)).count() as i64;
    }
    for sq in board.by_color(color) & board.by_role(Role::Rook) {
        rook_mob += (board.attacks_from(sq) & !board.by_color(color)).count() as i64;
    }
    for sq in board.by_color(color) & board.by_role(Role::Queen) {
        queen_mob += (board.attacks_from(sq) & !board.by_color(color)).count() as i64;
    }
    for sq in board.by_color(color) & board.by_role(Role::Pawn) {
        // pawn mobility: forward push if empty + captures
        let mut m = 0_i64;
        let file = sq.file();
        let rank = sq.rank();
        if let Some(nrank) = if color.is_white() { rank.offset(1) } else { rank.offset(-1) } {
            let to = Square::from_coords(file, nrank);
            if (board.occupied() & Bitboard::from(to)) == Bitboard::EMPTY {
                m += 1;
            }
        }
        for df in [-1_i8, 1_i8] {
            if let Some(f) = file.offset(df as i32) {
                if let Some(nrank) = if color.is_white() { rank.offset(1) } else { rank.offset(-1) } {
                    let to = Square::from_coords(f, nrank);
                    if (board.by_color(color.other()) & Bitboard::from(to)).any() {
                        m += 1;
                    }
                }
            }
        }
        pawn_mob += m;
    }
    let mobility_total = knight_mob + bishop_mob + rook_mob + queen_mob + pawn_mob;
    let w_mob = WEIGHTS.read().expect("weights lock").piece_mobility_weight;
    score += mobility_total * w_mob;

    let mut terms = serde_json::Map::new();
    terms.insert("knight".into(), serde_json::Value::from(knight_score));
    terms.insert("bishop".into(), serde_json::Value::from(bishop_score));
    terms.insert("rook".into(), serde_json::Value::from(rook_score));
    terms.insert("queen".into(), serde_json::Value::from(queen_score));
    terms.insert("phase".into(), serde_json::Value::from(phase as i64));
    terms.insert("open_files_controlled".into(), serde_json::Value::from(open_file_controlled));
    terms.insert("rook_on_seventh".into(), serde_json::Value::from(rook_on_seventh));
    terms.insert("doubled_rooks".into(), serde_json::Value::from(doubled_rooks));
    terms.insert("mobility_total".into(), serde_json::Value::from(mobility_total));
    terms.insert("mobility_knight".into(), serde_json::Value::from(knight_mob));
    terms.insert("mobility_bishop".into(), serde_json::Value::from(bishop_mob));
    terms.insert("mobility_rook".into(), serde_json::Value::from(rook_mob));
    terms.insert("mobility_queen".into(), serde_json::Value::from(queen_mob));
    terms.insert("mobility_pawn".into(), serde_json::Value::from(pawn_mob));
    (score, terms)
}

/// Tactical motif detectors and king tropism helpers (pins, forks, skewers, discovered, tropism)
fn chebyshev_distance(a: Square, b: Square) -> i64 {
    let df = (a.file() as i32 - b.file() as i32).abs() as i64;
    let dr = (a.rank() as i32 - b.rank() as i32).abs() as i64;
    df.max(dr)
}

fn king_tropism_score(board: &shakmaty::Board, color: Color) -> i64 {
    let enemy_king = match board.king_of(color.other()) {
        Some(sq) => sq,
        None => return 0,
    };
    let mut score = 0_i64;
    let w = weights();
    for sq in board.by_color(color) {
        // skip king itself
        if Some(sq) == board.king_of(color) {
            continue;
        }
        let dist = chebyshev_distance(sq, enemy_king);
        let closeness = 8 - dist; // 0..8
        if closeness <= 0 {
            continue;
        }
        // piece weight (configurable)
        let sq_bb = Bitboard::from(sq);
        let weight = if (sq_bb & board.by_role(Role::Queen)).any() {
            w.tropism_queen
        } else if (sq_bb & board.by_role(Role::Rook)).any() {
            w.tropism_rook
        } else if (sq_bb & board.by_role(Role::Bishop)).any() {
            w.tropism_bishop
        } else if (sq_bb & board.by_role(Role::Knight)).any() {
            w.tropism_knight
        } else if (sq_bb & board.by_role(Role::Pawn)).any() {
            w.tropism_pawn
        } else {
            0
        };
        score += weight * closeness / 2;
    }
    score
}

fn detect_pins(board: &shakmaty::Board, color: Color) -> (i64, Vec<(Square, Square, Square)>) {
    // returns (count, vec![(pinning_piece_sq, pinned_piece_sq, king_sq), ...])
    let king_sq = match board.king_of(color) {
        Some(sq) => sq,
        None => return (0, Vec::new()),
    };
    let occ = board.occupied();
    let mut pins = 0_i64;
    let mut examples: Vec<(Square, Square, Square)> = Vec::new();

    let sliders = board.by_color(color.other())
        & (board.by_role(Role::Rook) | board.by_role(Role::Bishop) | board.by_role(Role::Queen));

    for blocker in board.by_color(color) {
        let occ_minus = occ ^ Bitboard::from(blocker);
        for s in sliders {
            let s_bb = Bitboard::from(s);
            let is_rook = (s_bb & board.by_role(Role::Rook)).any();
            let is_bishop = (s_bb & board.by_role(Role::Bishop)).any();
            let is_queen = (s_bb & board.by_role(Role::Queen)).any();

            let mut before = Bitboard::EMPTY;
            let mut after = Bitboard::EMPTY;
            if is_rook || is_queen {
                before |= attacks::rook_attacks(s, occ);
                after |= attacks::rook_attacks(s, occ_minus);
            }
            if is_bishop || is_queen {
                before |= attacks::bishop_attacks(s, occ);
                after |= attacks::bishop_attacks(s, occ_minus);
            }

            let king_before = (before & Bitboard::from(king_sq)).any();
            let king_after = (after & Bitboard::from(king_sq)).any();
            if !king_before && king_after {
                pins += 1;
                examples.push((s, blocker, king_sq));
                break;
            }
        }
    }
    (pins, examples)
}

fn detect_forks(board: &shakmaty::Board, color: Color) -> (i64, Vec<(Square, Vec<Square>)>) {
    // returns (count, vec![(attacker_sq, vec![target_sqs...]), ...])
    let mut forks = 0_i64;
    let mut examples: Vec<(Square, Vec<Square>)> = Vec::new();
    let enemy_bb = board.by_color(color.other());
    for sq in board.by_color(color) {
        let attacks = board.attacks_from(sq);
        let attacked_pieces = attacks & enemy_bb;
        if attacked_pieces.count() < 2 {
            continue;
        }
        // sum values of attacked pieces (configurable values)
        let mut sum = 0_i64;
        let mut targets: Vec<Square> = Vec::new();
        let w = weights();
        for (role, val) in [
            (Role::Queen, w.val_queen),
            (Role::Rook, w.val_rook),
            (Role::Bishop, w.val_bishop),
            (Role::Knight, w.val_knight),
            (Role::Pawn, w.val_pawn),
        ] {
            let mask = attacked_pieces & board.by_role(role);
            for t in mask {
                sum += val;
                targets.push(t);
            }
        }
        // Count as fork when at least two pieces attacked and combined value above threshold
        if sum >= (w.val_rook) || attacked_pieces.count() >= 3 {
            forks += 1;
            examples.push((sq, targets.clone()));
        }
    }
    (forks, examples)
}

fn detect_skewers(board: &shakmaty::Board, color: Color) -> (i64, Vec<(Square, Square, Square)>) {
    // returns (count, vec![(attacker_sq, front_sq, back_sq), ...])
    let mut skewers = 0_i64;
    let enemy = color.other();
    let directions: &[(i8, i8)] = &[
        (1, 0),
        (-1, 0),
        (0, 1),
        (0, -1),
        (1, 1),
        (-1, 1),
        (1, -1),
        (-1, -1),
    ];

    let mut examples: Vec<(Square, Square, Square)> = Vec::new();

    for s in board.by_color(color) & (board.by_role(Role::Rook) | board.by_role(Role::Bishop) | board.by_role(Role::Queen)) {
        let s_bb = Bitboard::from(s);
        let is_rook = (s_bb & board.by_role(Role::Rook)).any();
        let is_bishop = (s_bb & board.by_role(Role::Bishop)).any();
        let is_queen = (s_bb & board.by_role(Role::Queen)).any();

        for (df, dr) in directions {
            // skip directions inappropriate for piece
            if !is_queen {
                if is_rook && *dr != 0 && *df != 0 {
                    continue;
                }
                if is_bishop && (*dr == 0 || *df == 0) {
                    continue;
                }
            }

            // walk the ray
            let mut found: Vec<Square> = Vec::new();
            let mut cur_file = s.file();
            let mut cur_rank = s.rank();
            loop {
                if let Some(nf) = cur_file.offset(*df as i32) {
                    if let Some(nr) = cur_rank.offset(*dr as i32) {
                        cur_file = nf;
                        cur_rank = nr;
                        let sq = Square::from_coords(cur_file, cur_rank);
                        let sq_bb = Bitboard::from(sq);
                        if (board.by_color(enemy) & sq_bb).any() {
                            found.push(sq);
                        }
                        if (board.occupied() & sq_bb).any() {
                            // blocked by any piece
                        }
                        continue;
                    }
                }
                break;
            }

            if found.len() >= 2 {
                let w = weights();
                let val = |sq: Square| {
                    if (Bitboard::from(sq) & board.by_role(Role::Queen)).any() {
                        w.val_queen
                    } else if (Bitboard::from(sq) & board.by_role(Role::Rook)).any() {
                        w.val_rook
                    } else if (Bitboard::from(sq) & board.by_role(Role::Bishop)).any() {
                        w.val_bishop
                    } else if (Bitboard::from(sq) & board.by_role(Role::Knight)).any() {
                        w.val_knight
                    } else if (Bitboard::from(sq) & board.by_role(Role::Pawn)).any() {
                        w.val_pawn
                    } else {
                        0
                    }
                };
                let v0 = val(found[0]);
                let v1 = val(found[1]);
                if v0 > v1 {
                    skewers += 1;
                    examples.push((s, found[0], found[1]));
                }
            }
        }
    }
    (skewers, examples)
}

fn detect_discovered(board: &shakmaty::Board, color: Color) -> (i64, Vec<(Square, Square, Square)>) {
    // returns (count, vec![(blocker_sq, slider_sq, target_sq), ...])
    let occ = board.occupied();
    let mut discovered = 0_i64;
    let mut examples: Vec<(Square, Square, Square)> = Vec::new();
    let enemy_bb = board.by_color(color.other());
    let sliders = board.by_color(color) & (board.by_role(Role::Rook) | board.by_role(Role::Bishop) | board.by_role(Role::Queen));

    for blocker in board.by_color(color) {
        let occ_minus = occ ^ Bitboard::from(blocker);
        for s in sliders {
            let s_bb = Bitboard::from(s);
            let is_rook = (s_bb & board.by_role(Role::Rook)).any();
            let is_bishop = (s_bb & board.by_role(Role::Bishop)).any();
            let is_queen = (s_bb & board.by_role(Role::Queen)).any();
            let mut before = Bitboard::EMPTY;
            let mut after = Bitboard::EMPTY;
            if is_rook || is_queen {
                before |= attacks::rook_attacks(s, occ);
                after |= attacks::rook_attacks(s, occ_minus);
            }
            if is_bishop || is_queen {
                before |= attacks::bishop_attacks(s, occ);
                after |= attacks::bishop_attacks(s, occ_minus);
            }
            let newly = (after & enemy_bb) & !before;
            if newly.any() {
                discovered += 1;
                // pick one target square as example
                if let Some(t) = newly.into_iter().next() {
                    examples.push((blocker, s, t));
                }
                break;
            }
        }
    }
    (discovered, examples)
}

fn piece_square_name(board: &shakmaty::Board, sq: Square) -> String {
    if let Some(piece) = board.piece_at(sq) {
        let letter = match piece.role {
            Role::Pawn => "P", Role::Knight => "N", Role::Bishop => "B",
            Role::Rook => "R", Role::Queen => "Q", Role::King => "K",
        };
        return format!("{}{}", letter, sq);
    }
    format!("{}", sq)
}

fn board_to_piece_ref(board: &shakmaty::Board, sq: Square) -> Option<PieceRef> {
    board.piece_at(sq).map(|p| PieceRef {
        role: match p.role {
            Role::Pawn => "Pawn", Role::Knight => "Knight", Role::Bishop => "Bishop",
            Role::Rook => "Rook", Role::Queen => "Queen", Role::King => "King",
        }.into(),
        color: if p.color == Color::White { "white" } else { "black" }.into(),
        square: sq.to_string(),
    })
}

/// For each fork, use shakmaty legal-move generation to determine which
/// target piece hangs (cannot escape the fork attacker). A piece hangs if
/// no legal move saves it from being captured.
fn simulate_fork_hangs(chess: &Chess, forks: &mut Vec<Fork>) {
    for fork in forks {
        let att_sq = match shakmaty::Square::from_ascii(fork.attacker.square.as_bytes()) {
            Ok(sq) => sq, Err(_) => continue,
        };
        let attacks_bb = chess.board().attacks_from(att_sq);

        // Determine the forked side's color from the targets
        let forked_color = if fork.targets.first()
            .map(|t| t.color.as_str() == "white").unwrap_or(false)
            { Color::White } else { Color::Black };

        // Only simulate when the forked side is to move (they can try to escape)
        // If it's the fork owner's turn, the fork was just created — the forked
        // side will get their chance to escape next.
        let moves = chess.legal_moves();

        for target in &fork.targets {
            let t_sq = match shakmaty::Square::from_ascii(target.square.as_bytes()) {
                Ok(sq) => sq, Err(_) => continue,
            };
            // Check if the piece can move to a square not attacked by the fork attacker.
            // Also count staying in place as "not escaping" (capture or blocking would
            // need deeper simulation — this is the 80% case).
            if chess.turn() == forked_color {
                let can_escape = moves.iter().any(|m| {
                    m.from() == Some(t_sq)
                    && (attacks_bb & shakmaty::Bitboard::from(m.to())) == shakmaty::Bitboard::EMPTY
                });
                if !can_escape {
                    fork.hangs = Some(target.clone());
                    break; // first hanging piece is the prediction
                }
            }
        }
    }
}

fn forks_to_typed(board: &shakmaty::Board, examples: &[(Square, Vec<Square>)]) -> Vec<Fork> {
    examples.iter().filter_map(|(att, targets)| {
        let attacker = board_to_piece_ref(board, *att)?;
        let targets: Vec<PieceRef> = targets.iter().filter_map(|t| board_to_piece_ref(board, *t)).collect();
        if targets.len() >= 2 { Some(Fork { attacker, targets, hangs: None }) } else { None }
    }).collect()
}

fn pins_to_typed(board: &shakmaty::Board, examples: &[(Square, Square, Square)]) -> Vec<Pin> {
    examples.iter().filter_map(|(att, pinned, king)| {
        let attacker = board_to_piece_ref(board, *att)?;
        let pinned_piece = board_to_piece_ref(board, *pinned)?;
        let shielded = board_to_piece_ref(board, *king)?;
        Some(Pin { attacker, pinned: pinned_piece, shielded, pin_type: PinType::Absolute })
    }).collect()
}

fn skewers_to_typed(board: &shakmaty::Board, examples: &[(Square, Square, Square)]) -> Vec<Skewer> {
    examples.iter().filter_map(|(att, front, behind)| {
        Some(Skewer {
            attacker: board_to_piece_ref(board, *att)?,
            front: board_to_piece_ref(board, *front)?,
            behind: board_to_piece_ref(board, *behind)?,
        })
    }).collect()
}

fn discovered_to_typed(board: &shakmaty::Board, examples: &[(Square, Square, Square)]) -> Vec<DiscoveredAttack> {
    examples.iter().filter_map(|(blocker, slider, target)| {
        Some(DiscoveredAttack {
            mover: board_to_piece_ref(board, *blocker)?,
            attacker: board_to_piece_ref(board, *slider)?,
            target: board_to_piece_ref(board, *target)?,
        })
    }).collect()
}

fn outposts_to_typed(board: &shakmaty::Board, examples: &[(Square, Role, Square)]) -> Vec<Outpost> {
    examples.iter().filter_map(|(sq, role, support)| {
        let piece = board_to_piece_ref(board, *sq)?;
        let support_ref = board_to_piece_ref(board, *support).unwrap_or(PieceRef {
            role: "Pawn".into(), color: "unknown".into(), square: "?".into(),
        });
        if matches!(role, Role::Knight | Role::Bishop) {
            Some(Outpost { piece, supported_by: support_ref })
        } else { None }
    }).collect()
}

// ── 1400 ELO extractors ──

fn extract_passed_pawns(board: &shakmaty::Board) -> Vec<PassedPawn> {
    let mut results = Vec::new();
    for color in [Color::White, Color::Black] {
        for sq in passed_pawn_mask(board, color) {
            let rank_idx = u32::from(sq.rank());
            let advance = if color.is_white() { rank_idx } else { 7 - rank_idx };
            let protected = board.attacks_to(sq, color, board.occupied()).any();
            results.push(PassedPawn {
                square: sq.to_string(), rank: advance as u8 + 2,
                color: if color.is_white() { "white" } else { "black" }.into(),
                is_protected: protected,
            });
        }
    }
    results
}

fn extract_open_files(board: &shakmaty::Board) -> Vec<OpenFile> {
    let mut results = Vec::new();
    for file in 0..8u32 {
        let f = File::new(file);
        for color in [Color::White, Color::Black] {
            let own_pawns = board.by_color(color) & board.by_role(Role::Pawn) & Bitboard::from(f);
            let opp_pawns = board.by_color(color.other()) & board.by_role(Role::Pawn) & Bitboard::from(f);
            let rook_count = (board.by_color(color) & board.by_role(Role::Rook) & Bitboard::from(f)).count() as u8;
            if rook_count > 0 && own_pawns.is_empty() {
                let is_open = opp_pawns.is_empty();
                results.push(OpenFile {
                    file: f.to_string(), rook_count,
                    color: if color.is_white() { "white" } else { "black" }.into(),
                });
                if is_open { break; }
            }
        }
    }
    results
}

fn extract_hanging_pieces(board: &shakmaty::Board) -> Vec<HangingPiece> {
    let mut results = Vec::new();
    let occupied = board.occupied();
    for color in [Color::White, Color::Black] {
        let opp = color.other();
        for sq in board.by_color(color) & !board.by_role(Role::King) {
            let attackers = board.attacks_to(sq, opp, occupied).count();
            let defenders = board.attacks_to(sq, color, occupied).count();
            if attackers > 0 && defenders == 0 {
                if let Some(piece) = board_to_piece_ref(board, sq) {
                    results.push(HangingPiece { piece, attacker_count: attackers as u8 });
                }
            }
        }
    }
    results
}

fn extract_king_exposure(board: &shakmaty::Board) -> Vec<KingExposure> {
    let mut results = Vec::new();
    for color in [Color::White, Color::Black] {
        let king_sq = match board.king_of(color) {
            Some(sq) => sq, None => continue,
        };
        let ring = attacks::king_attacks(king_sq) | Bitboard::from(king_sq);
        let attacker_count = (board.by_color(color.other()) & ring).count() as u8;
        let file = king_sq.file();
        let mut shelter_files = 0u8;
        for df in -1..=1 {
            if let Some(f) = file.offset(df) {
                let pawns = board.by_color(color) & board.by_role(Role::Pawn) & Bitboard::from(f);
                if pawns.any() { shelter_files += 1; }
            }
        }
        if attacker_count > 0 || shelter_files < 2 {
            results.push(KingExposure { color: if color.is_white() { "white" } else { "black" }.into(), shelter_files, attacker_count });
        }
    }
    results
}

fn extract_isolated_pawns(board: &shakmaty::Board) -> Vec<IsolatedPawn> {
    let mut results = Vec::new();
    for color in [Color::White, Color::Black] {
        for sq in board.by_color(color) & board.by_role(Role::Pawn) {
            let file = sq.file();
            let adjacent = [file.offset(-1), file.offset(1)]
                .into_iter()
                .flatten()
                .filter_map(|f| {
                    let bb = board.by_color(color) & board.by_role(Role::Pawn) & Bitboard::from(f);
                    if bb.any() { Some(()) } else { None }
                })
                .count();
            if adjacent == 0 {
                results.push(IsolatedPawn {
                    square: sq.to_string(),
                    color: if color.is_white() { "white" } else { "black" }.into(),
                });
            }
        }
    }
    results
}

fn extract_doubled_pawns(board: &shakmaty::Board) -> Vec<DoubledPawn> {
    let mut results = Vec::new();
    for color in [Color::White, Color::Black] {
        let pawns = board.by_color(color) & board.by_role(Role::Pawn);
        for file in 0..8u32 {
            let f = File::new(file);
            let count = (pawns & Bitboard::from(f)).count() as u8;
            if count > 1 {
                results.push(DoubledPawn {
                    file: f.to_string(), count,
                    color: if color.is_white() { "white" } else { "black" }.into(),
                });
            }
        }
    }
    results
}

fn extract_pawn_islands(board: &shakmaty::Board) -> Vec<PawnIsland> {
    let mut results = Vec::new();
    for color in [Color::White, Color::Black] {
        let pawns = board.by_color(color) & board.by_role(Role::Pawn);
        let mut files = Vec::new();
        let mut prev_had = false;
        let mut island_count = 0u8;
        for file in 0..8u32 {
            let f = File::new(file);
            let has = (pawns & Bitboard::from(f)).any();
            if has {
                files.push(f.to_string());
                if !prev_had {
                    island_count += 1;
                }
            }
            prev_had = has;
        }
        if island_count > 1 {
            results.push(PawnIsland {
                files, count: island_count,
                color: if color.is_white() { "white" } else { "black" }.into(),
            });
        }
    }
    results
}

fn extract_pawn_breaks(groups: &EvalGroups) -> Vec<PawnBreak> {
    let mut results = Vec::new();
    let break_examples = groups.pawn_structure.terms.get("pawn_break_examples");
    let opp_terms = groups.pawn_structure.terms.get("opp_terms")
        .and_then(|v| v.as_object());
    let opp_breaks = opp_terms.and_then(|o| o.get("pawn_break_examples"));

    // pawn_break_examples from the us side (for us pawns)
    if let Some(arr) = break_examples.and_then(|v| v.as_array()) {
        for ex in arr {
            if let (Some(pawn), Some(_to)) = (
                ex.get("pawn").and_then(|v| v.as_str()),
                ex.get("to").and_then(|v| v.as_str()),
            ) {
                results.push(PawnBreak { square: pawn.into(), color: "white".into() });
            }
        }
    }
    // opp pawn breaks
    if let Some(arr) = opp_breaks.and_then(|v| v.as_array()) {
        for ex in arr {
            if let (Some(pawn), Some(_to)) = (
                ex.get("pawn").and_then(|v| v.as_str()),
                ex.get("to").and_then(|v| v.as_str()),
            ) {
                results.push(PawnBreak { square: pawn.into(), color: "black".into() });
            }
        }
    }
    results
}

fn extract_minority_attack(groups: &EvalGroups) -> Option<MinorityAttack> {
    let minority_flag = groups.pawn_structure.terms.get("minority_attack")
        .and_then(|v| v.as_i64()).unwrap_or(0);
    if minority_flag == 0 { return None; }
    let strength = groups.pawn_structure.terms.get("minority_attack_strength")
        .and_then(|v| v.as_i64()).unwrap_or(0);
    Some(MinorityAttack { color: "white".into(), strength })
}

fn extract_development_info(board: &shakmaty::Board) -> Vec<DevelopmentInfo> {
    let mut results = Vec::new();
    for color in [Color::White, Color::Black] {
        let undeveloped = count_undeveloped(board, color);
        let space = development_space_score(board, color, compute_phase(board));
        if undeveloped > 0 || space < 0 {
            let pieces: Vec<PieceRef> = {
                let knight_home = color.fold_wb(
                    Bitboard::from(Square::B1) | Bitboard::from(Square::G1),
                    Bitboard::from(Square::B8) | Bitboard::from(Square::G8),
                );
                let bishop_home = color.fold_wb(
                    Bitboard::from(Square::C1) | Bitboard::from(Square::F1),
                    Bitboard::from(Square::C8) | Bitboard::from(Square::F8),
                );
                (board.by_color(color) & (board.by_role(Role::Knight) | board.by_role(Role::Bishop)) & (knight_home | bishop_home))
                    .into_iter()
                    .filter_map(|sq| board_to_piece_ref(board, sq))
                    .collect()
            };
            results.push(DevelopmentInfo {
                color: if color.is_white() { "white" } else { "black" }.into(),
                undeveloped_pieces: pieces,
                space_advantage: if color.is_white() { space } else { -space },
            });
        }
    }
    results
}

fn tactical_score(board: &shakmaty::Board, us: Color, phase: u8) -> (GroupValue, TacticalReport) {
    let them = us.other();
    let (pins_us, pin_ex_us) = detect_pins(board, us);
    let (pins_them, pin_ex_them) = detect_pins(board, them);
    let (forks_us, fork_ex_us) = detect_forks(board, us);
    let (forks_them, fork_ex_them) = detect_forks(board, them);
    let (skewers_us, skewer_ex_us) = detect_skewers(board, us);
    let (skewers_them, skewer_ex_them) = detect_skewers(board, them);
    let (disc_us, disc_ex_us) = detect_discovered(board, us);
    let (disc_them, disc_ex_them) = detect_discovered(board, them);

    // Tactical base weights (from configurable WEIGHTS)
    let phase_factor_num = i64::from(phase) + 8; // numerator
    let w_cfg = weights();

    let w_pins = w_cfg.tactical_base_pins * phase_factor_num / w_cfg.phase_factor_den;
    let w_forks = w_cfg.tactical_base_forks * phase_factor_num / w_cfg.phase_factor_den;
    let w_skewers = w_cfg.tactical_base_skewers * phase_factor_num / w_cfg.phase_factor_den;
    let w_disc = w_cfg.tactical_base_disc * phase_factor_num / w_cfg.phase_factor_den;

    let total_us = pins_us * w_pins + forks_us * w_forks + skewers_us * w_skewers + disc_us * w_disc;
    let total_them = pins_them * w_pins + forks_them * w_forks + skewers_them * w_skewers + disc_them * w_disc;
    let blended = total_us - total_them;
    let (mg, eg) = phase_split(blended, phase);

    let mut terms = serde_json::Map::new();
    terms.insert("pins_us".into(), serde_json::Value::from(pins_us));
    terms.insert("pins_them".into(), serde_json::Value::from(pins_them));
    terms.insert("forks_us".into(), serde_json::Value::from(forks_us));
    terms.insert("forks_them".into(), serde_json::Value::from(forks_them));
    terms.insert("skewers_us".into(), serde_json::Value::from(skewers_us));
    terms.insert("skewers_them".into(), serde_json::Value::from(skewers_them));
    terms.insert("discovered_us".into(), serde_json::Value::from(disc_us));
    terms.insert("discovered_them".into(), serde_json::Value::from(disc_them));
    terms.insert("total_us".into(), serde_json::Value::from(total_us));
    terms.insert("total_them".into(), serde_json::Value::from(total_them));

    // Examples (all collected) — insert plural arrays and a singular first-example for compatibility
    // Forks
    if !fork_ex_us.is_empty() {
        let arr: Vec<serde_json::Value> = fork_ex_us
            .iter()
            .map(|(att, targets)| {
                let attacker = piece_square_name(board, *att);
                let tnames: Vec<serde_json::Value> = targets.iter().map(|&t| serde_json::Value::from(piece_square_name(board, t))).collect();
                let mut map = serde_json::Map::new();
                map.insert("attacker".into(), serde_json::Value::from(attacker));
                map.insert("targets".into(), serde_json::Value::Array(tnames));
                serde_json::Value::Object(map)
            })
            .collect();
        terms.insert("fork_examples_us".into(), serde_json::Value::Array(arr.clone()))
            ;
        if let Some(first) = arr.first() {
            terms.insert("fork_example_us".into(), first.clone());
        }
    }
    if !fork_ex_them.is_empty() {
        let arr: Vec<serde_json::Value> = fork_ex_them
            .iter()
            .map(|(att, targets)| {
                let attacker = piece_square_name(board, *att);
                let tnames: Vec<serde_json::Value> = targets.iter().map(|&t| serde_json::Value::from(piece_square_name(board, t))).collect();
                let mut map = serde_json::Map::new();
                map.insert("attacker".into(), serde_json::Value::from(attacker));
                map.insert("targets".into(), serde_json::Value::Array(tnames));
                serde_json::Value::Object(map)
            })
            .collect();
        terms.insert("fork_examples_them".into(), serde_json::Value::Array(arr.clone()));
        if let Some(first) = arr.first() {
            terms.insert("fork_example_them".into(), first.clone());
        }
    }

    // Skewers
    if !skewer_ex_us.is_empty() {
        let arr: Vec<serde_json::Value> = skewer_ex_us
            .iter()
            .map(|(att, f, b)| {
                let mut map = serde_json::Map::new();
                map.insert("attacker".into(), serde_json::Value::from(piece_square_name(board, *att)));
                map.insert("front".into(), serde_json::Value::from(piece_square_name(board, *f)));
                map.insert("back".into(), serde_json::Value::from(piece_square_name(board, *b)));
                serde_json::Value::Object(map)
            })
            .collect();
        terms.insert("skewer_examples_us".into(), serde_json::Value::Array(arr.clone()));
        if let Some(first) = arr.first() {
            terms.insert("skewer_example_us".into(), first.clone());
        }
    }
    if !skewer_ex_them.is_empty() {
        let arr: Vec<serde_json::Value> = skewer_ex_them
            .iter()
            .map(|(att, f, b)| {
                let mut map = serde_json::Map::new();
                map.insert("attacker".into(), serde_json::Value::from(piece_square_name(board, *att)));
                map.insert("front".into(), serde_json::Value::from(piece_square_name(board, *f)));
                map.insert("back".into(), serde_json::Value::from(piece_square_name(board, *b)));
                serde_json::Value::Object(map)
            })
            .collect();
        terms.insert("skewer_examples_them".into(), serde_json::Value::Array(arr.clone()));
        if let Some(first) = arr.first() {
            terms.insert("skewer_example_them".into(), first.clone());
        }
    }

    // Pins
    if !pin_ex_us.is_empty() {
        let arr: Vec<serde_json::Value> = pin_ex_us
            .iter()
            .map(|(pinner, pinned, king)| {
                let mut map = serde_json::Map::new();
                map.insert("pinner".into(), serde_json::Value::from(piece_square_name(board, *pinner)));
                map.insert("pinned".into(), serde_json::Value::from(piece_square_name(board, *pinned)));
                map.insert("king".into(), serde_json::Value::from(piece_square_name(board, *king)));
                serde_json::Value::Object(map)
            })
            .collect();
        terms.insert("pin_examples_us".into(), serde_json::Value::Array(arr.clone()));
        if let Some(first) = arr.first() {
            terms.insert("pin_example_us".into(), first.clone());
        }
    }
    if !pin_ex_them.is_empty() {
        let arr: Vec<serde_json::Value> = pin_ex_them
            .iter()
            .map(|(pinner, pinned, king)| {
                let mut map = serde_json::Map::new();
                map.insert("pinner".into(), serde_json::Value::from(piece_square_name(board, *pinner)));
                map.insert("pinned".into(), serde_json::Value::from(piece_square_name(board, *pinned)));
                map.insert("king".into(), serde_json::Value::from(piece_square_name(board, *king)));
                serde_json::Value::Object(map)
            })
            .collect();
        terms.insert("pin_examples_them".into(), serde_json::Value::Array(arr.clone()));
        if let Some(first) = arr.first() {
            terms.insert("pin_example_them".into(), first.clone());
        }
    }

    // Discovered
    if !disc_ex_us.is_empty() {
        let arr: Vec<serde_json::Value> = disc_ex_us
            .iter()
            .map(|(blocker, slider, target)| {
                let mut map = serde_json::Map::new();
                map.insert("blocker".into(), serde_json::Value::from(piece_square_name(board, *blocker)));
                map.insert("slider".into(), serde_json::Value::from(piece_square_name(board, *slider)));
                map.insert("target".into(), serde_json::Value::from(piece_square_name(board, *target)));
                serde_json::Value::Object(map)
            })
            .collect();
        terms.insert("discovered_examples_us".into(), serde_json::Value::Array(arr.clone()));
        if let Some(first) = arr.first() {
            terms.insert("discovered_example_us".into(), first.clone());
        }
    }
    if !disc_ex_them.is_empty() {
        let arr: Vec<serde_json::Value> = disc_ex_them
            .iter()
            .map(|(blocker, slider, target)| {
                let mut map = serde_json::Map::new();
                map.insert("blocker".into(), serde_json::Value::from(piece_square_name(board, *blocker)));
                map.insert("slider".into(), serde_json::Value::from(piece_square_name(board, *slider)));
                map.insert("target".into(), serde_json::Value::from(piece_square_name(board, *target)));
                serde_json::Value::Object(map)
            })
            .collect();
        terms.insert("discovered_examples_them".into(), serde_json::Value::Array(arr.clone()));
        if let Some(first) = arr.first() {
            terms.insert("discovered_example_them".into(), first.clone());
        }
    }

    let report = TacticalReport {
        forks: {
            let mut v = forks_to_typed(board, &fork_ex_us);
            v.extend(forks_to_typed(board, &fork_ex_them));
            v
        },
        pins: {
            let mut v = pins_to_typed(board, &pin_ex_us);
            v.extend(pins_to_typed(board, &pin_ex_them));
            v
        },
        skewers: {
            let mut v = skewers_to_typed(board, &skewer_ex_us);
            v.extend(skewers_to_typed(board, &skewer_ex_them));
            v
        },
        discovered: {
            let mut v = discovered_to_typed(board, &disc_ex_us);
            v.extend(discovered_to_typed(board, &disc_ex_them));
            v
        },
        hanging: Vec::new(), // TODO: hanging piece detection
    };

    (GroupValue { mg, eg, blended, terms }, report)
}

fn detect_outposts(board: &shakmaty::Board, color: Color) -> (i64, Vec<(Square, Role, Square)>) {
    // Detect outposts: own Knight/Bishop on an advanced square that is not attackable by opponent pawns
    // and is supported by an own pawn (preferred). Returns (count, vec![(sq, role, support_sq), ...]).
    let mut count = 0_i64;
    let mut examples: Vec<(Square, Role, Square)> = Vec::new();
    let enemy_pawn_attacks = pawn_attack_mask(board, color.other());

    let pieces = board.by_color(color) & (board.by_role(Role::Knight) | board.by_role(Role::Bishop));

    for sq in pieces {
        // advanced condition: for white rank >= 4 (0-indexed >=3), for black rank <= 4
        let rank_idx = u32::from(sq.rank());
        if color.is_white() {
            if rank_idx < 3 {
                continue;
            }
        } else {
            if rank_idx > 4 {
                continue;
            }
        }

        // must not be attackable by enemy pawns
        if (enemy_pawn_attacks & Bitboard::from(sq)) != Bitboard::EMPTY {
            continue;
        }

        // check if supported by own pawn (preferred)
        let mut supported_by_pawn: Option<Square> = None;
        for p in board.by_color(color) & board.by_role(Role::Pawn) {
            if (attacks::pawn_attacks(color, p) & Bitboard::from(sq)).any() {
                supported_by_pawn = Some(p);
                break;
            }
        }

        if let Some(p_support) = supported_by_pawn {
            count += 1;
            if let Some(piece) = board.piece_at(sq) {
                examples.push((sq, piece.role, p_support));
            }
        } else {
            // as a fallback, allow squares defended by other pieces
            let occ = board.occupied();
            if board.attacks_to(sq, color, occ).any() {
                count += 1;
                if let Some(piece) = board.piece_at(sq) {
                    examples.push((sq, piece.role, Square::E1));
                }
                // support square unknown; placeholder E1 (we will prefer pawn support in examples)
            }
        }
    }

    (count, examples)
}

/// Center control score: presence and attacks on D4, D5, E4, E5 (centipawns).
fn center_control_score(board: &shakmaty::Board, color: Color) -> i64 {
    let center = [Square::D4, Square::D5, Square::E4, Square::E5];
    let occupied = board.occupied();
    let mut score = 0_i64;

    for &sq in &center {
        // Occupying a center square is worth more than just attacking it
        if (board.by_color(color) & Bitboard::from(sq)).any() {
            score += 20;
        }
        // Count attackers from this color (using attacks_to from the color's perspective)
        let attackers = board.attacks_to(sq, color, occupied);
        score += attackers.count() as i64 * 8;
    }
    score
}

/// Piece coordination: count own piece pairs within Manhattan distance ≤ 2.
fn piece_coordination_score(board: &shakmaty::Board, color: Color) -> i64 {
    let pieces = board.by_color(color);
    let mut score = 0_i64;
    let squares: Vec<Square> = pieces.into_iter().collect();
    for i in 0..squares.len() {
        for j in (i + 1)..squares.len() {
            let a = squares[i];
            let b = squares[j];
            let file_diff = (a.file() as i32 - b.file() as i32).unsigned_abs() as i64;
            let rank_diff = (a.rank() as i32 - b.rank() as i32).unsigned_abs() as i64;
            let manhattan = file_diff + rank_diff;
            if manhattan <= 2 {
                score += 5;
            }
        }
    }
    score
}

/// Tactical pressure: sliding pieces (R/Q on rank/file, B/Q on diagonal) aligned with enemy king.
fn tactical_pressure_score(board: &shakmaty::Board, color: Color) -> i64 {
    let enemy_king = match board.king_of(color.other()) {
        Some(sq) => sq,
        None => return 0,
    };
    let occupied = board.occupied();
    let mut score = 0_i64;

    // Rooks/Queens aligned on rank or file with enemy king
    for sq in board.by_color(color) & (board.by_role(Role::Rook) | board.by_role(Role::Queen)) {
        let reachable = attacks::rook_attacks(sq, occupied);
        if (reachable & Bitboard::from(enemy_king)).any() {
            score += 15;
        }
    }

    // Bishops/Queens aligned on diagonal with enemy king
    for sq in board.by_color(color) & (board.by_role(Role::Bishop) | board.by_role(Role::Queen)) {
        let reachable = attacks::bishop_attacks(sq, occupied);
        if (reachable & Bitboard::from(enemy_king)).any() {
            score += 12;
        }
    }

    score
}

/// Combined vector_features group (center_control + piece_coordination + tactical_pressure).
fn vector_features_score(board: &shakmaty::Board, color: Color, phase: u8) -> GroupValue {
    let cc_us = center_control_score(board, color);
    let cc_them = center_control_score(board, color.other());
    let pc_us = piece_coordination_score(board, color);
    let pc_them = piece_coordination_score(board, color.other());
    let tp_us = tactical_pressure_score(board, color);
    let tp_them = tactical_pressure_score(board, color.other());

    let center = cc_us - cc_them;
    let coordination = pc_us - pc_them;
    let pressure = tp_us - tp_them;
    let total = center + coordination + pressure;
    let (mg, eg) = phase_split(total, phase);

    let mut terms = serde_json::Map::new();
    terms.insert("center_control_us".into(), serde_json::Value::from(cc_us));
    terms.insert(
        "center_control_them".into(),
        serde_json::Value::from(cc_them),
    );
    terms.insert(
        "piece_coordination_us".into(),
        serde_json::Value::from(pc_us),
    );
    terms.insert(
        "piece_coordination_them".into(),
        serde_json::Value::from(pc_them),
    );
    terms.insert(
        "tactical_pressure_us".into(),
        serde_json::Value::from(tp_us),
    );
    terms.insert(
        "tactical_pressure_them".into(),
        serde_json::Value::from(tp_them),
    );

    GroupValue {
        mg,
        eg,
        blended: blend(mg, eg, phase),
        terms,
    }
}

/// Strategic evaluation: initiative, king-attack, safety, coordination.
/// Ported from chess-vector-engine/src/strategic_evaluator.rs (shakmaty translation).
fn strategic_score(
    board: &shakmaty::Board,
    us: Color,
    legal_move_count: usize,
    phase: u8,
) -> GroupValue {
    let them = us.other();
    let occupied = board.occupied();

    // --- initiative: mobility advantage + center control ---
    // Approximate opponent mobility by counting attacks on all squares from their pieces.
    let mut opp_mobility = 0i64;
    for sq in board.by_color(them) {
        opp_mobility += board.attacks_from(sq).count() as i64;
    }
    let our_moves = legal_move_count as i64;
    let mobility_advantage = our_moves - (opp_mobility / 3).max(1);
    let center = [Square::D4, Square::D5, Square::E4, Square::E5];
    let center_ctrl = center
        .iter()
        .filter(|&&sq| (board.by_color(us) & Bitboard::from(sq)).any())
        .count() as i64;
    let initiative = mobility_advantage * 2 + center_ctrl * 10;

    // --- attacking_bonus: pieces threatening enemy king area ---
    let enemy_king_area = board
        .king_of(them)
        .map(|ksq| attacks::king_attacks(ksq) | Bitboard::from(ksq))
        .unwrap_or(Bitboard::EMPTY);

    let mut attacking_pieces = 0i64;
    let mut controlled_king_sq = 0i64;
    for sq in board.by_color(us) {
        let piece_attacks = board.attacks_from(sq);
        if (piece_attacks & enemy_king_area).any() {
            attacking_pieces += 1;
        }
    }
    for sq in enemy_king_area {
        if board.attacks_to(sq, us, occupied).any() {
            controlled_king_sq += 1;
        }
    }
    let attacking_bonus = attacking_pieces * 10 + controlled_king_sq * 8;

    // --- safety_penalty: hanging our pieces + king exposure ---
    let mut hanging = 0i64;
    for sq in board.by_color(us) {
        let attacked = board.attacks_to(sq, them, occupied).any();
        if attacked {
            let defended = board
                .attacks_to(sq, us, occupied)
                .into_iter()
                .filter(|&def| def != sq)
                .count();
            if defended == 0 {
                hanging += 1;
            }
        }
    }
    let king_exposed = board
        .king_of(us)
        .map(|ksq| board.attacks_to(ksq, them, occupied).any())
        .unwrap_or(false);
    let safety_penalty = hanging * 40 + if king_exposed { 80 } else { 0 };

    // --- coordination_bonus: our pieces within attack range of each other ---
    let our_squares: Vec<Square> = board.by_color(us).into_iter().collect();
    let mut coordination = 0i64;
    for i in 0..our_squares.len() {
        for j in (i + 1)..our_squares.len() {
            let a = our_squares[i];
            let b = our_squares[j];
            // Pieces reachable from each other (one step of sliding/leaper attacks)
            let a_atk = board.attacks_from(a);
            if (a_atk & Bitboard::from(b)).any() {
                coordination += 5;
            }
        }
    }

    let total = initiative + attacking_bonus + coordination - safety_penalty;
    let (mg, eg) = phase_split(total, phase);

    let mut terms = serde_json::Map::new();
    terms.insert("initiative".into(), serde_json::Value::from(initiative));
    terms.insert(
        "attacking_bonus".into(),
        serde_json::Value::from(attacking_bonus),
    );
    terms.insert(
        "attacking_pieces".into(),
        serde_json::Value::from(attacking_pieces),
    );
    terms.insert(
        "controlled_king_sq".into(),
        serde_json::Value::from(controlled_king_sq),
    );
    terms.insert(
        "safety_penalty".into(),
        serde_json::Value::from(safety_penalty),
    );
    terms.insert("hanging".into(), serde_json::Value::from(hanging));
    terms.insert("king_exposed".into(), serde_json::Value::from(king_exposed));
    terms.insert("coordination".into(), serde_json::Value::from(coordination));

    GroupValue {
        mg,
        eg,
        blended: blend(mg, eg, phase),
        terms,
    }
}

/// Compute the chaos coefficient: how tactically unstable the position is.
/// Ranges from 0.0 (clean positional game) to 1.0 (multiple immediate threats).
/// Digital-switch sensors (forks, pins, checks) fire → chaos rises.
/// This gates the higher-tier analog sensors through the attenuation matrix.
fn chaos_coefficient(g: &EvalGroups) -> f64 {
    let t = &g.tactical.terms;
    let s = &g.strategic.terms;
    let ks = &g.king_safety.terms;

    let term_i64 = |key: &str| -> i64 {
        t.get(key).and_then(|v| v.as_i64()).unwrap_or(0)
    };

    let forks = term_i64("forks_us") + term_i64("forks_them");
    let pins = term_i64("pins_us") + term_i64("pins_them");
    let skewers = term_i64("skewers_us") + term_i64("skewers_them");
    // discovered attacks fire too broadly (even in opening) — excluded from chaos

    let in_check = ks.get("in_check").and_then(|v| v.as_bool()).unwrap_or(false);
    let hanging = s.get("hanging").and_then(|v| v.as_i64()).unwrap_or(0);
    let king_exposed = s.get("king_exposed")
        .and_then(|v| v.as_bool()).unwrap_or(false);

    let threat_count = (forks + pins + skewers + hanging) as f64;
    let chaos_base = threat_count * 0.15;
    let chaos_bonus = if in_check { 0.4 } else { 0.0 }
                    + if king_exposed { 0.3 } else { 0.0 };

    (chaos_base + chaos_bonus).min(1.0)
}

fn compute_aggregates(g: &mut EvalGroups) {
    use crate::eval::concepts::{SensorTier, attenuation};

    let chaos = chaos_coefficient(g);
    let chaos_i64 = (chaos * 100.0) as i64; // store as 0-100

    // Material: always active (Survival tier, attenuation = 1.0)
    let material = g.material.blended;
    g.material_total = ScalarValue { value: material, factor: chaos_i64 };

    // Positional: structural components with tier-specific attenuation
    fn compute_attenuated(value: i64, chaos: f64, tier: SensorTier) -> i64 {
        let att = attenuation(tier, chaos);
        (value as f64 * att).round() as i64
    }

    // Pawn structure and passed pawns: Positional tier (half-attenuated)
    let pawn = compute_attenuated(g.pawn_structure.blended, chaos, SensorTier::Positional);
    // Piece activity (outposts, rooks): Positional tier
    let activity = compute_attenuated(g.piece_activity.blended, chaos, SensorTier::Positional);
    // King safety: Positional tier 
    let king_safe = compute_attenuated(g.king_safety.blended, chaos, SensorTier::Positional);
    // Development: Positional tier
    let dev = compute_attenuated(g.development.blended, chaos, SensorTier::Positional);
    // Vector features (center control, coordination): Positional tier
    let vectors = compute_attenuated(g.vector_features.blended, chaos, SensorTier::Positional);
    // Strategic (initiative, minority attack): Strategic tier (fully attenuated)
    let strategic = compute_attenuated(g.strategic.blended, chaos, SensorTier::Strategic);
    // Passed pawns: Positional tier
    let passed = compute_attenuated(g.passed_pawns.blended, chaos, SensorTier::Positional);
    // Scaling and drawishness are meta-concepts, not attenuated
    let scaling = g.scaling.value;
    let drawishness = g.drawishness.value;
    let override_ = g.override_.value;

    let attenuated_positional = pawn + activity + king_safe + passed + dev + vectors + strategic
        + scaling + drawishness + override_;
    g.positional_total = ScalarValue { value: attenuated_positional, factor: chaos_i64 };

    // Tactical: Threat tier — always active (attenuation = 1.0)
    let tactical = g.tactical.blended;
    g.tactical_total = ScalarValue { value: tactical, factor: 0 };
}

fn sum_groups(groups: &EvalGroups) -> i64 {
    groups.material.blended
        + groups.pawn_structure.blended
        + groups.piece_activity.blended
        + groups.king_safety.blended
        + groups.passed_pawns.blended
        + groups.development.blended
        + groups.vector_features.blended
        + groups.strategic.blended
        + groups.tactical.blended
        + groups.scaling.value
        + groups.drawishness.value
        + groups.override_.value
}

fn win_chance_scale(board: &shakmaty::Board, _mi: &GroupValue) -> i64 {
    let count_white = piece_count(board, Color::White, Role::Pawn);
    let count_black = piece_count(board, Color::Black, Role::Pawn);
    let pawn_cnt = count_white.max(count_black);
    let wpieces = piece_count(board, Color::White, Role::Knight)
        + piece_count(board, Color::White, Role::Bishop)
        + piece_count(board, Color::White, Role::Rook)
        + piece_count(board, Color::White, Role::Queen);
    let bpieces = piece_count(board, Color::Black, Role::Knight)
        + piece_count(board, Color::Black, Role::Bishop)
        + piece_count(board, Color::Black, Role::Rook)
        + piece_count(board, Color::Black, Role::Queen);

    if wpieces == 0 && bpieces == 0 {
        return 128;
    }

    if piece_count(board, Color::White, Role::Queen) + piece_count(board, Color::Black, Role::Queen)
        == 2
    {
        return 112 + pawn_cnt.min(8);
    }

    if piece_count(board, Color::White, Role::Rook) + piece_count(board, Color::Black, Role::Rook)
        == 2
    {
        return 96 + pawn_cnt.min(8) * 2;
    }

    if piece_count(board, Color::White, Role::Bishop)
        + piece_count(board, Color::Black, Role::Bishop)
        == 2
    {
        return 88 + pawn_cnt.min(8) * 2;
    }

    128
}

fn draw_weight(board: &shakmaty::Board, color: Color) -> i64 {
    let our = board.by_color(color) & board.by_role(Role::Pawn);
    let their = board.by_color(color.other()) & board.by_role(Role::Pawn);
    let mut open = 0_i64;
    let mut all = 0_i64;

    for file in 0..8 {
        let file_mask = Bitboard::from(File::new(file));
        let has_our = (our & file_mask).any();
        let has_their = (their & file_mask).any();
        if has_our {
            all += 1;
        }
        if has_our && !has_their {
            open += 1;
        }
    }

    let open_file_mult = [6_i64, 5, 4, 3, 2, 1, 0, 0, 0];
    let pawn_count_mult = [6_i64, 5, 4, 3, 2, 1, 0, 0, 0];
    open_file_mult[open as usize] * pawn_count_mult[all as usize]
}

pub fn compute_groups(chess: &Chess, phase: u8, legal_move_count: usize) -> EvalGroups {
    let board = chess.board();
    let us = chess.turn();
    let them = us.other();
    let in_check = chess.is_check();

    let w = weights();
    let material = material_score(board, phase);
    let (pawn_us, pawn_us_terms) = pawn_structure_score(board, us, phase);
    let (pawn_them, pawn_them_terms) = pawn_structure_score(board, them, phase);
    let (passed_us, passed_us_terms) = passed_pawn_score(board, us);
    let (passed_them, passed_them_terms) = passed_pawn_score(board, them);
    let dev_diff = development_score(board, us) - development_score(board, them);
    let king_safety = king_safety_score(board, us, in_check, phase)
        - king_safety_score(board, them, false, phase);

    let mut pawn_structure = GroupValue::default();
    let pawn_total = pawn_us - pawn_them;
    let (pawn_mg, pawn_eg) = phase_split(pawn_total, biased_phase(phase, w.phase_bias_pawn_structure));
    pawn_structure.mg = pawn_mg;
    pawn_structure.eg = pawn_eg;
    pawn_structure.blended = blend(pawn_mg, pawn_eg, biased_phase(phase, w.phase_bias_pawn_structure));
    pawn_structure.terms = pawn_us_terms.clone();
    pawn_structure
        .terms
        .insert("opp_total".into(), serde_json::Value::from(pawn_them));
    pawn_structure.terms.insert(
        "opp_terms".into(),
        serde_json::Value::Object(pawn_them_terms.clone()),
    );

    // Synthesize per-color terms for concepts.rs extract_concepts
    for key in &["isolated", "doubled", "candidate", "weak", "chain", "passed", "islands",
                  "majority_queenside", "majority_center", "majority_kingside",
                  "minority_attack", "minority_attack_strength", "pawn_breaks"] {
        if let Some(v) = pawn_us_terms.get(*key) {
            pawn_structure.terms.insert(format!("{}_us", key).into(), v.clone());
        }
        if let Some(v) = pawn_them_terms.get(*key) {
            pawn_structure.terms.insert(format!("{}_them", key).into(), v.clone());
        }
    }
    // Synthesize aggregate majority counts
    let majority_us: i64 = ["majority_queenside", "majority_center", "majority_kingside"]
        .iter()
        .filter_map(|k| pawn_us_terms.get(*k).and_then(|v| v.as_i64()))
        .sum();
    let majority_them: i64 = ["majority_queenside", "majority_center", "majority_kingside"]
        .iter()
        .filter_map(|k| pawn_them_terms.get(*k).and_then(|v| v.as_i64()))
        .sum();
    pawn_structure.terms.insert("majority_us".into(), serde_json::Value::from(majority_us));
    pawn_structure.terms.insert("majority_them".into(), serde_json::Value::from(majority_them));

    let mut piece_activity = GroupValue::default();
    let (piece_us, piece_us_terms) = piece_activity_score(
        board,
        us,
        phase,
        !pawn_attack_mask(board, them),
        king_ring(board, us),
    );
    let (piece_them, piece_them_terms) = piece_activity_score(
        board,
        them,
        phase,
        !pawn_attack_mask(board, us),
        king_ring(board, them),
    );
    let piece_total = piece_us - piece_them;
    let (piece_mg, piece_eg) = phase_split(piece_total, biased_phase(phase, w.phase_bias_piece_activity));
    piece_activity.mg = piece_mg;
    piece_activity.eg = piece_eg;
    piece_activity.blended = blend(piece_mg, piece_eg, biased_phase(phase, w.phase_bias_piece_activity));
    piece_activity.terms = piece_us_terms;
    piece_activity.terms.insert(
        "legal_move_count".into(),
        serde_json::Value::from(legal_move_count as i64),
    );
    piece_activity
        .terms
        .insert("opp_total".into(), serde_json::Value::from(piece_them));
    piece_activity.terms.insert(
        "opp_terms".into(),
        serde_json::Value::Object(piece_them_terms),
    );

    // Outpost detection: add as a piece activity term, with example context
    let (outposts_us, out_ex_us) = detect_outposts(board, us);
    let (outposts_them, out_ex_them) = detect_outposts(board, them);
    let outpost_delta = outposts_us * w.outpost_weight - outposts_them * w.outpost_weight;
    piece_activity.blended += outpost_delta;
    piece_activity.terms.insert("outposts_us".into(), serde_json::Value::from(outposts_us));
    piece_activity.terms.insert("outposts_them".into(), serde_json::Value::from(outposts_them));

    // Insert all outpost examples (plural) and singular-first for compatibility
    if !out_ex_us.is_empty() {
        let arr: Vec<serde_json::Value> = out_ex_us
            .iter()
            .map(|(sq, role, support)| {
                let mut map = serde_json::Map::new();
                map.insert("square".into(), serde_json::Value::from(sq.to_string()));
                map.insert(
                    "role".into(),
                    serde_json::Value::from(match role { Role::Knight => "N", Role::Bishop => "B", _ => "?" }),
                );
                map.insert("support".into(), serde_json::Value::from(piece_square_name(board, *support)));
                serde_json::Value::Object(map)
            })
            .collect();
        piece_activity.terms.insert("outpost_examples_us".into(), serde_json::Value::Array(arr.clone()));
        if let Some((sq, role, support)) = out_ex_us.first() {
            piece_activity.terms.insert("outpost_example_us".into(), serde_json::Value::from(format!("{} on {} supported by {}", match role { Role::Knight => "N", Role::Bishop => "B", _ => "?" }, sq, piece_square_name(board, *support))));
        }
    }
    if !out_ex_them.is_empty() {
        let arr: Vec<serde_json::Value> = out_ex_them
            .iter()
            .map(|(sq, role, support)| {
                let mut map = serde_json::Map::new();
                map.insert("square".into(), serde_json::Value::from(sq.to_string()));
                map.insert(
                    "role".into(),
                    serde_json::Value::from(match role { Role::Knight => "N", Role::Bishop => "B", _ => "?" }),
                );
                map.insert("support".into(), serde_json::Value::from(piece_square_name(board, *support)));
                serde_json::Value::Object(map)
            })
            .collect();
        piece_activity.terms.insert("outpost_examples_them".into(), serde_json::Value::Array(arr.clone()));
        if let Some((sq, role, support)) = out_ex_them.first() {
            piece_activity.terms.insert("outpost_example_them".into(), serde_json::Value::from(format!("{} on {} supported by {}", match role { Role::Knight => "N", Role::Bishop => "B", _ => "?" }, sq, piece_square_name(board, *support))));
        }
    }

    let mut king_safety_group = GroupValue::default();
    let (king_mg, king_eg) = phase_split(king_safety, biased_phase(phase, w.phase_bias_king_safety));
    king_safety_group.mg = king_mg;
    king_safety_group.eg = king_eg;
    // augment king safety with king tropism (GUESS weights)
    let tropism_us = king_tropism_score(board, us);
    let tropism_them = king_tropism_score(board, them);
    king_safety_group.blended = blend(king_mg, king_eg, biased_phase(phase, w.phase_bias_king_safety))
        + (tropism_us - tropism_them);
    king_safety_group
        .terms
        .insert("in_check".into(), serde_json::Value::from(in_check));
    king_safety_group
        .terms
        .insert("tropism_us".into(), serde_json::Value::from(tropism_us));
    king_safety_group
        .terms
        .insert("tropism_them".into(), serde_json::Value::from(tropism_them));

    let mut passed_pawns = GroupValue::default();
    let passed_total = passed_us - passed_them;
    let (passed_mg, passed_eg) = phase_split(passed_total, biased_phase(phase, w.phase_bias_passed_pawns));
    passed_pawns.mg = passed_mg;
    passed_pawns.eg = passed_eg;
    passed_pawns.blended = blend(passed_mg, passed_eg, biased_phase(phase, w.phase_bias_passed_pawns));
    passed_pawns.terms = passed_us_terms;
    passed_pawns
        .terms
        .insert("opp_total".into(), serde_json::Value::from(passed_them));
    passed_pawns.terms.insert(
        "opp_terms".into(),
        serde_json::Value::Object(passed_them_terms),
    );

    let mut development = GroupValue::default();
    let dev_space_us = development_space_score(board, us, phase);
    let dev_space_them = development_space_score(board, them, phase);
    let dev_total = dev_diff + (dev_space_us - dev_space_them);
    let (dev_mg, dev_eg) = phase_split(dev_total, biased_phase(phase, w.phase_bias_development));
    development.mg = dev_mg;
    development.eg = dev_eg;
    development.blended = blend(dev_mg, dev_eg, biased_phase(phase, w.phase_bias_development));
    development
        .terms
        .insert("development_diff".into(), serde_json::Value::from(dev_diff));
    development
        .terms
        .insert("space_us".into(), serde_json::Value::from(dev_space_us));
    development
        .terms
        .insert("space_them".into(), serde_json::Value::from(dev_space_them));

    let vector_features = vector_features_score(board, us, biased_phase(phase, w.phase_bias_vector_features));
    let strategic = strategic_score(board, us, legal_move_count, biased_phase(phase, w.phase_bias_strategic));
    let (tactical, _tactical_report) = tactical_score(board, us, phase);

    let scaling_factor = win_chance_scale(board, &material);

    let mut groups = EvalGroups {
        material_total: ScalarValue::default(),
        positional_total: ScalarValue::default(),
        tactical_total: ScalarValue::default(),
        material,
        pawn_structure,
        piece_activity,
        king_safety: king_safety_group,
        passed_pawns,
        development,
        vector_features,
        strategic,
        tactical,
        scaling: ScalarValue {
            value: 0,
            factor: scaling_factor,
        },
        drawishness: ScalarValue::default(),
        override_: ScalarValue::default(),
    };

    let linear_total = sum_groups(&groups);
    groups.scaling.value = if linear_total > 0 {
        linear_total * (groups.scaling.factor - 128) / 128
    } else if linear_total < 0 {
        linear_total * (128 - groups.scaling.factor) / 128
    } else {
        0
    };
    let draw_delta = if linear_total > 0 {
        -(draw_weight(board, Color::White) * linear_total.min(256)) / 64
    } else if linear_total < 0 {
        (draw_weight(board, Color::Black) * (-linear_total).min(256)) / 64
    } else {
        0
    };
    groups.drawishness.value = draw_delta;
    compute_aggregates(&mut groups);
    groups
}

fn get_term_i64(terms: &serde_json::Map<String, serde_json::Value>, key: &str) -> i64 {
    terms.get(key).and_then(|v| v.as_i64()).unwrap_or(0)
}

fn build_material_balance(groups: &EvalGroups) -> Option<MaterialBalance> {
    let t = &groups.material.terms;
    let white = PieceCounts {
        queens: get_term_i64(t, "white_queens") as u8,
        rooks: get_term_i64(t, "white_rooks") as u8,
        bishops: get_term_i64(t, "white_bishops") as u8,
        knights: get_term_i64(t, "white_knights") as u8,
        pawns: get_term_i64(t, "white_pawns") as u8,
    };
    let black = PieceCounts {
        queens: get_term_i64(t, "black_queens") as u8,
        rooks: get_term_i64(t, "black_rooks") as u8,
        bishops: get_term_i64(t, "black_bishops") as u8,
        knights: get_term_i64(t, "black_knights") as u8,
        pawns: get_term_i64(t, "black_pawns") as u8,
    };
    let bishop_pair_white = get_term_i64(t, "white_bishops") >= 2;
    let bishop_pair_black = get_term_i64(t, "black_bishops") >= 2;
    let centipawns = groups.material_total.value;
    Some(MaterialBalance { white, black, centipawns, bishop_pair_white, bishop_pair_black })
}

pub fn build_sensor_report(board: &shakmaty::Board, fen: &str, groups: &EvalGroups, chess: &Chess, phase: u8) -> SensorReport {
    let us = chess.turn();
    let them = us.other();
    let (_, fork_ex_us) = detect_forks(board, us);
    let (_, fork_ex_them) = detect_forks(board, them);
    let (_, pin_ex_us) = detect_pins(board, us);
    let (_, pin_ex_them) = detect_pins(board, them);
    let (_, skewer_ex_us) = detect_skewers(board, us);
    let (_, skewer_ex_them) = detect_skewers(board, them);
    let (_, disc_ex_us) = detect_discovered(board, us);
    let (_, disc_ex_them) = detect_discovered(board, them);

    let tactical = TacticalReport {
        forks: { let mut v = forks_to_typed(board, &fork_ex_us); v.extend(forks_to_typed(board, &fork_ex_them)); simulate_fork_hangs(chess, &mut v); v },
        pins: { let mut v = pins_to_typed(board, &pin_ex_us); v.extend(pins_to_typed(board, &pin_ex_them)); v },
        skewers: { let mut v = skewers_to_typed(board, &skewer_ex_us); v.extend(skewers_to_typed(board, &skewer_ex_them)); v },
        discovered: { let mut v = discovered_to_typed(board, &disc_ex_us); v.extend(discovered_to_typed(board, &disc_ex_them)); v },
        hanging: extract_hanging_pieces(board),
    };

    let positional = PositionalReport {
        outposts: {
            let (_, out_ex_us) = detect_outposts(board, us);
            let (_, out_ex_them) = detect_outposts(board, them);
            let mut v = outposts_to_typed(board, &out_ex_us);
            v.extend(outposts_to_typed(board, &out_ex_them));
            v
        },
        open_files: extract_open_files(board),
        passed_pawns: extract_passed_pawns(board),
        doubled_pawns: extract_doubled_pawns(board),
        isolated_pawns: extract_isolated_pawns(board),
        pawn_islands: extract_pawn_islands(board),
        pawn_breaks: extract_pawn_breaks(groups),
        minority_attack: extract_minority_attack(groups),
        king_exposure: {
            let exposures = extract_king_exposure(board);
            if exposures.len() >= 2 {
                exposures.into_iter().max_by_key(|k| k.attacker_count)
            } else {
                exposures.into_iter().next()
            }
        },
        development: {
            let dev_infos = extract_development_info(board);
            let target_color = if us.is_white() { "white" } else { "black" };
            let dev_first = dev_infos.iter().find(|d| d.color == target_color);
            dev_first.cloned().or_else(|| dev_infos.first().cloned())
        },
    };

    let material = {
        let balance = build_material_balance(groups);
        MaterialConceptReport { balance, redundancy: Vec::new() }
    };

    // Build state_id from components before assembling SensorReport
    let state_id = {
        // Temporary SensorReport for state encoding only
        let tmp = SensorReport {
            fen: fen.to_string(), state_id: 0,
            material: material.clone(), tactical: tactical.clone(), positional: positional.clone(),
            aggregated: AggregatedScores::default(),
        };
        crate::eval::concepts::encode_state(&tmp, groups, phase).state_id
    };

    SensorReport {
        fen: fen.to_string(),
        state_id,
        material,
        tactical,
        positional,
        aggregated: AggregatedScores {
            material_cp: groups.material_total.value,
            positional_cp: groups.positional_total.value,
            tactical_cp: groups.tactical_total.value,
            total_cp: groups.material_total.value + groups.positional_total.value + groups.tactical_total.value,
            chaos: chaos_coefficient(groups),
        },
    }
}

pub fn analyze_fen(fen: &str) -> Result<PositionRecord> {
    analyze_fen_with_engine_score(fen, None)
}

pub fn analyze_fen_with_engine_score(
    fen: &str,
    engine_score: Option<i64>,
) -> Result<PositionRecord> {
    let parsed = Fen::from_ascii(fen.as_bytes()).context("invalid FEN")?;
    let chess: Chess = parsed
        .into_position(shakmaty::CastlingMode::Standard)
        .context("could not convert FEN to chess position")?;

    let normalized_fen =
        Fen::from_position(chess.clone(), shakmaty::EnPassantMode::Legal).to_string();
    let phase = compute_phase(chess.board());
    let legal_move_count = chess.legal_moves().len();
    let groups = compute_groups(&chess, phase, legal_move_count);
    let sensor_report = build_sensor_report(chess.board(), fen, &groups, &chess, phase);
    let final_score = sum_groups(&groups);
    let delta = engine_score.map(|score| final_score - score);
    let sum_groups_match = delta.map(|d| d == 0).unwrap_or(true);

    Ok(PositionRecord {
        fen: fen.to_string(),
        normalized_fen,
        side_to_move: chess.turn().fold_wb("white", "black").to_string(),
        phase,
        final_score,
        engine_score,
        legal: LegalInfo {
            is_legal: true,
            is_check: chess.is_check(),
            is_checkmate: chess.is_checkmate(),
            is_stalemate: chess.is_stalemate(),
            is_insufficient_material: chess.is_insufficient_material(),
            legal_move_count,
        },
        groups,
        checks: Checks {
            sum_groups: final_score,
            matches_final: sum_groups_match,
            delta,
        },
        sensor_report,
    })
}

pub fn render_structured_explanations(record: &PositionRecord) -> Vec<serde_json::Value> {
    let mut out: Vec<serde_json::Value> = Vec::new();
    let side_cap = if record.side_to_move == "white" { "White" } else { "Black" };

    // Helper to create an explanation object
    let make_obj = |kind: &str, side_str: &str, severity: i64, phrase: String, details: serde_json::Map<String, serde_json::Value>| -> serde_json::Value {
        let mut obj = serde_json::Map::new();
        obj.insert("kind".into(), serde_json::Value::from(kind));
        obj.insert("side".into(), serde_json::Value::from(side_str));
        obj.insert("severity".into(), serde_json::Value::from(severity));
        obj.insert("phrase".into(), serde_json::Value::from(phrase));
        obj.insert("details".into(), serde_json::Value::Object(details));
        serde_json::Value::Object(obj)
    };

    // Forks
    if let Some(val) = record.groups.tactical.terms.get("forks_us") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                let mut details = serde_json::Map::new();
                if let Some(exs) = record.groups.tactical.terms.get("fork_examples_us") {
                    details.insert("examples".into(), exs.clone());
                } else if let Some(ex) = record.groups.tactical.terms.get("fork_example_us") {
                    details.insert("examples".into(), serde_json::Value::Array(vec![ex.clone()]));
                }
                let phrase = details
                    .get("examples")
                    .and_then(|v| v.as_array())
                    .and_then(|arr| arr.first())
                    .and_then(|e| e.as_str())
                    .map(|s| format!("{} has {} fork(s) detected (e.g. {}).", side_cap, n, s))
                    .unwrap_or_else(|| format!("{} has {} fork(s) detected.", side_cap, n));
                out.push(make_obj("fork", "white", n, phrase, details));
            }
        }
    }

    // Skewers
    if let Some(val) = record.groups.tactical.terms.get("skewers_us") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                let mut details = serde_json::Map::new();
                if let Some(exs) = record.groups.tactical.terms.get("skewer_examples_us") {
                    details.insert("examples".into(), exs.clone());
                } else if let Some(ex) = record.groups.tactical.terms.get("skewer_example_us") {
                    details.insert("examples".into(), serde_json::Value::Array(vec![ex.clone()]));
                }
                let phrase = details
                    .get("examples")
                    .and_then(|v| v.as_array())
                    .and_then(|arr| arr.first())
                    .and_then(|e| e.as_str())
                    .map(|s| format!("{} has {} skewer(s) detected (e.g. {}).", side_cap, n, s))
                    .unwrap_or_else(|| format!("{} has {} skewer(s) detected.", side_cap, n));
                out.push(make_obj("skewer", "white", n, phrase, details));
            }
        }
    }

    // Pins
    if let Some(val) = record.groups.tactical.terms.get("pins_us") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                let mut details = serde_json::Map::new();
                if let Some(exs) = record.groups.tactical.terms.get("pin_examples_us") {
                    details.insert("examples".into(), exs.clone());
                } else if let Some(ex) = record.groups.tactical.terms.get("pin_example_us") {
                    details.insert("examples".into(), serde_json::Value::Array(vec![ex.clone()]));
                }
                let phrase = details
                    .get("examples")
                    .and_then(|v| v.as_array())
                    .and_then(|arr| arr.first())
                    .and_then(|e| e.as_str())
                    .map(|s| format!("{} has {} pin(s) (e.g. {}).", side_cap, n, s))
                    .unwrap_or_else(|| format!("{} has {} pin(s).", side_cap, n));
                out.push(make_obj("pin", "white", n, phrase, details));
            }
        }
    }

    // Discovered
    if let Some(val) = record.groups.tactical.terms.get("discovered_us") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                let mut details = serde_json::Map::new();
                if let Some(exs) = record.groups.tactical.terms.get("discovered_examples_us") {
                    details.insert("examples".into(), exs.clone());
                } else if let Some(ex) = record.groups.tactical.terms.get("discovered_example_us") {
                    details.insert("examples".into(), serde_json::Value::Array(vec![ex.clone()]));
                }
                let phrase = details
                    .get("examples")
                    .and_then(|v| v.as_array())
                    .and_then(|arr| arr.first())
                    .and_then(|e| e.as_str())
                    .map(|s| format!("{} has {} discovered-attack opportunity(ies) (e.g. {}).", side_cap, n, s))
                    .unwrap_or_else(|| format!("{} has {} discovered-attack opportunity(ies).", side_cap, n));
                out.push(make_obj("discovered", "white", n, phrase, details));
            }
        }
    }

    // Outposts
    if let Some(val) = record.groups.piece_activity.terms.get("outposts_us") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                let mut details = serde_json::Map::new();
                if let Some(exs) = record.groups.piece_activity.terms.get("outpost_examples_us") {
                    details.insert("examples".into(), exs.clone());
                } else if let Some(ex) = record.groups.piece_activity.terms.get("outpost_example_us") {
                    details.insert("examples".into(), serde_json::Value::Array(vec![ex.clone()]));
                }
                let phrase = details
                    .get("examples")
                    .and_then(|v| v.as_array())
                    .and_then(|arr| arr.first())
                    .and_then(|e| e.as_str())
                    .map(|s| format!("{} has {} outpost(s) (e.g. {}).", side_cap, n, s))
                    .unwrap_or_else(|| format!("{} has {} outpost(s).", side_cap, n));
                out.push(make_obj("outpost", "white", n, phrase, details));
            }
        }
    }

    // Rook activity examples
    if let Some(val) = record.groups.piece_activity.terms.get("open_files_controlled") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                let mut details = serde_json::Map::new();
                details.insert("count".into(), serde_json::Value::from(n));
                let phrase = format!("{} controls {} open file(s) with rooks.", side_cap, n);
                out.push(make_obj("rook_open_files", "white", n, phrase, details));
            }
        }
    }

    if out.is_empty() {
        let mut details = serde_json::Map::new();
        details.insert("msg".into(), serde_json::Value::from("none"));
        out.push(make_obj("none", "white", 0, "No immediate human-readable issues detected by static HUGM heuristics.".to_string(), details));
    }

    out
}

pub fn render_explanations(record: &PositionRecord) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let side = if record.side_to_move == "white" { "White" } else { "Black" };
    let opp = if side == "White" { "Black" } else { "White" };

    // Tactical explanations with examples when available
    if let Some(val) = record.groups.tactical.terms.get("forks_us") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                // try plural array first
                let first_example = record
                    .groups
                    .tactical
                    .terms
                    .get("fork_examples_us")
                    .and_then(|v| v.as_array())
                    .and_then(|arr| arr.first().cloned())
                    .or_else(|| record.groups.tactical.terms.get("fork_example_us").cloned());

                if let Some(ex) = first_example {
                    if let Some(att) = ex.get("attacker").and_then(|v| v.as_str()) {
                        if let Some(targets) = ex.get("targets").and_then(|v| v.as_array()) {
                            let t_str = targets.iter().filter_map(|v| v.as_str()).collect::<Vec<_>>().join(", ");
                            out.push(format!("{} has {} fork(s) detected (e.g. {} -> {}) — check for immediate tactical threats or trade opportunities.", side, n, att, t_str));
                        } else {
                            out.push(format!("{} has {} fork(s) detected (e.g. {}) — check for immediate tactical threats or trade opportunities.", side, n, att));
                        }
                    } else if let Some(s) = ex.as_str() {
                        out.push(format!("{} has {} fork(s) detected (e.g. {}) — check for immediate tactical threats or trade opportunities.", side, n, s));
                    } else {
                        out.push(format!("{} has {} fork(s) detected — check for immediate tactical threats or trade opportunities.", side, n));
                    }
                } else {
                    out.push(format!("{} has {} fork(s) detected — check for immediate tactical threats or trade opportunities.", side, n));
                }
            }
        }
    }
    if let Some(val) = record.groups.tactical.terms.get("skewers_us") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                let first_example = record
                    .groups
                    .tactical
                    .terms
                    .get("skewer_examples_us")
                    .and_then(|v| v.as_array())
                    .and_then(|arr| arr.first().cloned())
                    .or_else(|| record.groups.tactical.terms.get("skewer_example_us").cloned());
                if let Some(ex) = first_example {
                    if let (Some(att), Some(front), Some(back)) = (ex.get("attacker").and_then(|v| v.as_str()), ex.get("front").and_then(|v| v.as_str()), ex.get("back").and_then(|v| v.as_str())) {
                        out.push(format!("{} has {} skewer(s) detected (e.g. {}: {} -> {}) — high-value piece may be attacked in-line.", side, n, att, front, back));
                    } else if let Some(s) = ex.as_str() {
                        out.push(format!("{} has {} skewer(s) detected (e.g. {}) — high-value piece may be attacked in-line.", side, n, s));
                    } else {
                        out.push(format!("{} has {} skewer(s) detected — high-value piece may be attacked in-line.", side, n));
                    }
                } else {
                    out.push(format!("{} has {} skewer(s) detected — high-value piece may be attacked in-line.", side, n));
                }
            }
        }
    }
    if let Some(val) = record.groups.tactical.terms.get("pins_us") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                let first_example = record
                    .groups
                    .tactical
                    .terms
                    .get("pin_examples_us")
                    .and_then(|v| v.as_array())
                    .and_then(|arr| arr.first().cloned())
                    .or_else(|| record.groups.tactical.terms.get("pin_example_us").cloned());
                if let Some(ex) = first_example {
                    if let (Some(pinner), Some(pinned), Some(king)) = (ex.get("pinner").and_then(|v| v.as_str()), ex.get("pinned").and_then(|v| v.as_str()), ex.get("king").and_then(|v| v.as_str())) {
                        out.push(format!("{} has {} pin(s) (e.g. {} pins {} to {}) — consider relieving pressure or trading pinned pieces.", side, n, pinner, pinned, king));
                    } else if let Some(s) = ex.as_str() {
                        out.push(format!("{} has {} pin(s) (e.g. {}) — consider relieving pressure or trading pinned pieces.", side, n, s));
                    } else {
                        out.push(format!("{} has {} pin(s) — consider relieving pressure or trading pinned pieces.", side, n));
                    }
                } else {
                    out.push(format!("{} has {} pin(s) — consider relieving pressure or trading pinned pieces.", side, n));
                }
            }
        }
    }
    if let Some(val) = record.groups.tactical.terms.get("discovered_us") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                let first_example = record
                    .groups
                    .tactical
                    .terms
                    .get("discovered_examples_us")
                    .and_then(|v| v.as_array())
                    .and_then(|arr| arr.first().cloned())
                    .or_else(|| record.groups.tactical.terms.get("discovered_example_us").cloned());
                if let Some(ex) = first_example {
                    if let (Some(blocker), Some(slider), Some(target)) = (ex.get("blocker").and_then(|v| v.as_str()), ex.get("slider").and_then(|v| v.as_str()), ex.get("target").and_then(|v| v.as_str())) {
                        out.push(format!("{} has {} discovered-attack opportunity(ies) (e.g. {} moves unveils {} attacking {}) — watch for moves that uncover attacks.", side, n, blocker, slider, target));
                    } else if let Some(s) = ex.as_str() {
                        out.push(format!("{} has {} discovered-attack opportunity(ies) (e.g. {}) — watch for moves that uncover attacks.", side, n, s));
                    } else {
                        out.push(format!("{} has {} discovered-attack opportunity(ies) — watch for moves that uncover attacks.", side, n));
                    }
                } else {
                    out.push(format!("{} has {} discovered-attack opportunity(ies) — watch for moves that uncover attacks.", side, n));
                }
            }
        }
    }

    // Opponent tactical warnings
    if let Some(val) = record.groups.tactical.terms.get("forks_them") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                if let Some(ex) = record.groups.tactical.terms.get("fork_example_them") {
                    if let Some(att) = ex.get("attacker").and_then(|v| v.as_str()) {
                        if let Some(targets) = ex.get("targets").and_then(|v| v.as_array()) {
                            let t_str = targets.iter().filter_map(|v| v.as_str()).collect::<Vec<_>>().join(", ");
                            out.push(format!("{} has {} fork(s) (by opponent) (e.g. {} -> {}) — consider defensive resources.", opp, n, att, t_str));
                        } else {
                            out.push(format!("{} has {} fork(s) (by opponent) (e.g. {}) — consider defensive resources.", opp, n, att));
                        }
                    } else if let Some(s) = ex.as_str() {
                        out.push(format!("{} has {} fork(s) (by opponent) (e.g. {}) — consider defensive resources.", opp, n, s));
                    }
                } else {
                    out.push(format!("{} has {} fork(s) (by opponent) — consider defensive resources.", opp, n));
                }
            }
        }
    }

    // King safety / tropism
    if let Some(val) = record.groups.king_safety.terms.get("tropism_us") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                out.push(format!("{} pieces show tropism toward the opponent king (score = {}) — attacking chances exist.", side, n));
            }
        }
    }

    // Rook activity
    if let Some(val) = record.groups.piece_activity.terms.get("open_files_controlled") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                out.push(format!("{} controls {} open file(s) with rooks — good rook activity.", side, n));
            }
        }
    }
    if let Some(val) = record.groups.piece_activity.terms.get("rook_on_seventh") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                out.push(format!("{} has {} rook(s) on the 7th rank — strong pressure on enemy pawns and king.", side, n));
            }
        }
    }
    if let Some(val) = record.groups.piece_activity.terms.get("doubled_rooks") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                out.push(format!("{} has {} doubled-rook file(s) — potential for heavy-file pressure.", side, n));
            }
        }
    }

    // Pawn structure notes
    if let Some(val) = record.groups.pawn_structure.terms.get("isolated") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                out.push(format!("{} has {} isolated pawn(s) — structural weakness to address.", side, n));
            }
        }
    }
    if let Some(val) = record.groups.pawn_structure.terms.get("passed") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                out.push(format!("{} has {} passed pawn(s) — potential long-term advantage.", side, n));
            }
        }
    }

    // Outpost explanation
    if let Some(val) = record.groups.piece_activity.terms.get("outposts_us") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                let first_example = record
                    .groups
                    .piece_activity
                    .terms
                    .get("outpost_examples_us")
                    .and_then(|v| v.as_array())
                    .and_then(|arr| arr.first().cloned())
                    .or_else(|| record.groups.piece_activity.terms.get("outpost_example_us").cloned());
                if let Some(ex) = first_example {
                    if let Some(s) = ex.as_str() {
                        out.push(format!("{} has {} outpost(s) (e.g. {}) — strong squares often requiring specific plans to challenge.", side, n, s));
                    } else {
                        out.push(format!("{} has {} outpost(s) (e.g. <example>) — strong squares often requiring specific plans to challenge.", side, n));
                    }
                } else {
                    out.push(format!("{} has {} outpost(s) — strong squares often requiring specific plans to challenge.", side, n));
                }
            }
        }
    }

    // Development/space/initiative
    if let Some(val) = record.groups.development.terms.get("development_diff") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                out.push(format!("{} is ahead in development/space (diff = {}).", side, n));
            }
        }
    }
    if let Some(val) = record.groups.strategic.terms.get("initiative") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                out.push(format!("{} appears to have initiative ({}).", side, n));
            }
        }
    }

    if out.is_empty() {
        out.push("No immediate human-readable issues detected by static HUGM heuristics.".to_string());
    }

    out
}

#[cfg(test)]
mod tests {
    use super::analyze_fen;
    use super::analyze_fen_with_engine_score;

    #[test]
    fn parses_starting_position() {
        let record = analyze_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
            .expect("FEN should parse");
        assert_eq!(record.side_to_move, "white");
        assert!(record.legal.is_legal);
        assert!(!record.normalized_fen.is_empty());
    }

    #[test]
    fn handles_drawish_king_endgame() {
        let record = analyze_fen("8/8/8/8/8/7k/8/6K1 w - - 0 1").expect("FEN should parse");
        assert!(record.legal.is_insufficient_material || record.legal.is_stalemate);
        assert!(record.groups.drawishness.value <= 0);
    }

    #[test]
    fn handles_tactical_position() {
        let record =
            analyze_fen("r1bqkbnr/pppp1ppp/2n5/4p3/4P3/2N5/PPPP1PPP/R1BQKBNR w KQkq - 2 3")
                .expect("FEN should parse");
        assert!(record.phase > 0);
        assert!(record.legal.legal_move_count > 0);
    }

    #[test]
    fn compares_engine_score_when_provided() {
        let base = analyze_fen("8/8/8/8/8/7k/8/6K1 w - - 0 1").expect("FEN should parse");
        let record =
            analyze_fen_with_engine_score("8/8/8/8/8/7k/8/6K1 w - - 0 1", Some(base.final_score))
                .expect("FEN should parse");
        assert_eq!(record.engine_score, Some(base.final_score));
        assert!(record.checks.matches_final);
        assert_eq!(record.checks.delta, Some(0));
    }

    #[test]
    fn vector_features_present() {
        let record = analyze_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
            .expect("FEN should parse");
        assert!(record
            .groups
            .vector_features
            .terms
            .contains_key("center_control_us"));
        assert!(record
            .groups
            .vector_features
            .terms
            .contains_key("tactical_pressure_us"));
    }

    #[test]
    fn tactical_pins_detected() {
        // Black bishop on b4 pins white piece on d2 to king on e1
        let fen = "7k/8/8/8/1b6/8/3N4/4K3 w - - 0 1";
        let record = analyze_fen(fen).expect("FEN should parse");
        assert!(record.groups.tactical.terms.contains_key("pins_us"));
        let pins_us = record
            .groups
            .tactical
            .terms
            .get("pins_us")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        assert!(pins_us >= 1);
    }

    #[test]
    fn rook_open_file_terms() {
        // White rook on a1 with no pawns on file -> open file controlled
        let fen = "8/8/8/8/8/8/8/R3K2k w - - 0 1";
        let record = analyze_fen(fen).expect("FEN should parse");
        assert!(record
            .groups
            .piece_activity
            .terms
            .contains_key("open_files_controlled"));
        let open_files = record
            .groups
            .piece_activity
            .terms
            .get("open_files_controlled")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        assert!(open_files >= 1);
    }

    #[test]
    fn king_tropism_present() {
        // Ensure king_tropism term present in a normal position (non-zero phase)
        let record = analyze_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1").expect("FEN should parse");
        assert!(record.groups.king_safety.terms.contains_key("tropism_us"));
        let _ = record
            .groups
            .king_safety
            .terms
            .get("tropism_us")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
    }

    #[test]
    fn detects_skewer() {
        // White rook on a1 attacking black queen on a2 with black rook on a3 behind -> skewer
        let fen = "7k/8/8/8/8/r7/q7/R3K3 w - - 0 1";
        let record = analyze_fen(fen).expect("FEN should parse");
        let skewers_us = record
            .groups
            .tactical
            .terms
            .get("skewers_us")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        assert!(skewers_us >= 1);
    }

    #[test]
    fn detects_fork() {
        // White knight on d5 attacking black rook on b6 and black queen on f6
        let fen = "7k/8/1r3q2/3N4/8/8/8/4K3 w - - 0 1";
        let record = analyze_fen(fen).expect("FEN should parse");
        let forks_us = record
            .groups
            .tactical
            .terms
            .get("forks_us")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        assert!(forks_us >= 1);
    }

    #[test]
    fn detects_outpost() {
        // White knight on d5 supported by pawn on c4; no black pawn attacks d5
        let fen = "k7/8/8/3N4/2P5/8/8/4K3 w - - 0 1";
        let record = analyze_fen(fen).expect("FEN should parse");
        let outposts = record
            .groups
            .piece_activity
            .terms
            .get("outposts_us")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        assert!(outposts >= 1);
        // example string present
        let ex = record
            .groups
            .piece_activity
            .terms
            .get("outpost_example_us")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        assert!(!ex.is_empty());
    }
}


