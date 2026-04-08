use anyhow::{Context, Result};
use serde::Serialize;
use shakmaty::{attacks, fen::Fen, Bitboard, Chess, Color, File, Position, Rank, Role, Square};

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
    pub scaling: ScalarValue,
    pub drawishness: ScalarValue,
    pub override_: ScalarValue,
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

fn phase_split(value: i64, phase: u8) -> (i64, i64) {
    let bias = (i64::from(phase).saturating_sub(16).abs() * value.abs()) / 64;
    (value + bias, value - bias)
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

fn compute_phase(board: &shakmaty::Board) -> u8 {
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
    let stage = i64::from(phase);
    let opening = 32_i64;
    // Phase-dependent material adjustment coefficients, indexed by game phase (0..=32).
    // Each row: [unused0, unused1, unused2, unused3, unused4, bishop_pair, np_bonus, rp_penalty,
    //            bn_vs_rp, redundant_r, redundant_qr]
    // Columns 0–4 are legacy placeholders retained for index stability; they are never read.
    let coeff = [
        [0_i64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
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

    let mg = (white(Role::Queen, 3004)
        + white(Role::Rook, 1533)
        + white(Role::Bishop, 910)
        + white(Role::Knight, 875)
        + white(Role::Pawn, 298))
        - (black(Role::Queen, 3004)
            + black(Role::Rook, 1533)
            + black(Role::Bishop, 910)
            + black(Role::Knight, 875)
            + black(Role::Pawn, 298));

    let eg = (white(Role::Queen, 2090)
        + white(Role::Rook, 1018)
        + white(Role::Bishop, 708)
        + white(Role::Knight, 653)
        + white(Role::Pawn, 190))
        - (black(Role::Queen, 2090)
            + black(Role::Rook, 1018)
            + black(Role::Bishop, 708)
            + black(Role::Knight, 653)
            + black(Role::Pawn, 190));

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
    let blended = (mg * stage + eg * (opening - stage)) / opening + adjustments;

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
    terms.insert("bishop_pair".into(), serde_json::Value::from(bishop_pair));
    terms.insert("rp_penalty".into(), serde_json::Value::from(rp_penalty));
    terms.insert("np_bonus".into(), serde_json::Value::from(np_bonus));
    terms.insert("bn_vs_rp".into(), serde_json::Value::from(bn_vs_rp));
    terms.insert("redundant_r".into(), serde_json::Value::from(redundant_r));
    terms.insert("redundant_qr".into(), serde_json::Value::from(redundant_qr));
    terms.insert("adjustments".into(), serde_json::Value::from(adjustments));

    GroupValue {
        mg,
        eg,
        blended,
        terms,
    }
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
        if color.is_white() {
            if sq.rank() == Rank::Seventh {
                local += 30;
            } else if sq.rank() == Rank::Eighth {
                local += 13;
            } else if sq.rank() == Rank::Sixth {
                local += 13;
            }
        } else if sq.rank() == Rank::Second {
            local += 30;
        } else if sq.rank() == Rank::First {
            local += 13;
        } else if sq.rank() == Rank::Third {
            local += 13;
        }
        rook_score += local;
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

    let mut terms = serde_json::Map::new();
    terms.insert("knight".into(), serde_json::Value::from(knight_score));
    terms.insert("bishop".into(), serde_json::Value::from(bishop_score));
    terms.insert("rook".into(), serde_json::Value::from(rook_score));
    terms.insert("queen".into(), serde_json::Value::from(queen_score));
    terms.insert("phase".into(), serde_json::Value::from(phase as i64));
    (score, terms)
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
        blended: total,
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
        blended: total,
        terms,
    }
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

fn compute_groups(chess: &Chess, phase: u8, legal_move_count: usize) -> EvalGroups {
    let board = chess.board();
    let us = chess.turn();
    let them = us.other();
    let in_check = chess.is_check();

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
    let (pawn_mg, pawn_eg) = phase_split(pawn_total, phase);
    pawn_structure.mg = pawn_mg;
    pawn_structure.eg = pawn_eg;
    pawn_structure.blended = pawn_total;
    pawn_structure.terms = pawn_us_terms;
    pawn_structure
        .terms
        .insert("opp_total".into(), serde_json::Value::from(pawn_them));
    pawn_structure.terms.insert(
        "opp_terms".into(),
        serde_json::Value::Object(pawn_them_terms),
    );

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
    let (piece_mg, piece_eg) = phase_split(piece_total, phase);
    piece_activity.mg = piece_mg;
    piece_activity.eg = piece_eg;
    piece_activity.blended = piece_total;
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

    let mut king_safety_group = GroupValue::default();
    let (king_mg, king_eg) = phase_split(king_safety, phase);
    king_safety_group.mg = king_mg;
    king_safety_group.eg = king_eg;
    king_safety_group.blended = king_safety;
    king_safety_group
        .terms
        .insert("in_check".into(), serde_json::Value::from(in_check));

    let mut passed_pawns = GroupValue::default();
    let passed_total = passed_us - passed_them;
    let (passed_mg, passed_eg) = phase_split(passed_total, phase);
    passed_pawns.mg = passed_mg;
    passed_pawns.eg = passed_eg;
    passed_pawns.blended = passed_total;
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
    let (dev_mg, dev_eg) = phase_split(dev_total, phase);
    development.mg = dev_mg;
    development.eg = dev_eg;
    development.blended = dev_total;
    development
        .terms
        .insert("development_diff".into(), serde_json::Value::from(dev_diff));
    development
        .terms
        .insert("space_us".into(), serde_json::Value::from(dev_space_us));
    development
        .terms
        .insert("space_them".into(), serde_json::Value::from(dev_space_them));

    let vector_features = vector_features_score(board, us, phase);
    let strategic = strategic_score(board, us, legal_move_count, phase);

    let scaling_factor = win_chance_scale(board, &material);

    let mut groups = EvalGroups {
        material,
        pawn_structure,
        piece_activity,
        king_safety: king_safety_group,
        passed_pawns,
        development,
        vector_features,
        strategic,
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
    groups
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
    let final_score = sum_groups(&groups);
    let delta = engine_score.map(|score| final_score - score);
    let sum_groups_match = delta.map_or(true, |d| d == 0);

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
    })
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
}
