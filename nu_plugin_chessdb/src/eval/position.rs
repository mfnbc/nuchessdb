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
    pub tactical: GroupValue,
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
            local += 25; // GUESS
        }
        if color.is_white() {
            if sq.rank() == Rank::Seventh {
                local += 30;
                rook_on_seventh += 1;
            } else if sq.rank() == Rank::Eighth {
                local += 13;
            } else if sq.rank() == Rank::Sixth {
                local += 13;
            }
        } else if sq.rank() == Rank::Second {
            local += 30;
            rook_on_seventh += 1;
        } else if sq.rank() == Rank::First {
            local += 13;
        } else if sq.rank() == Rank::Third {
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
            rook_score += 20; // GUESS
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

    let mut terms = serde_json::Map::new();
    terms.insert("knight".into(), serde_json::Value::from(knight_score));
    terms.insert("bishop".into(), serde_json::Value::from(bishop_score));
    terms.insert("rook".into(), serde_json::Value::from(rook_score));
    terms.insert("queen".into(), serde_json::Value::from(queen_score));
    terms.insert("phase".into(), serde_json::Value::from(phase as i64));
    terms.insert("open_files_controlled".into(), serde_json::Value::from(open_file_controlled));
    terms.insert("rook_on_seventh".into(), serde_json::Value::from(rook_on_seventh));
    terms.insert("doubled_rooks".into(), serde_json::Value::from(doubled_rooks));
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
        // piece weight guess (GUESS)
        let weight = if (Bitboard::from(sq) & board.by_role(Role::Queen)).any() {
            90
        } else if (Bitboard::from(sq) & board.by_role(Role::Rook)).any() {
            50
        } else if (Bitboard::from(sq) & board.by_role(Role::Bishop)).any() {
            35
        } else if (Bitboard::from(sq) & board.by_role(Role::Knight)).any() {
            30
        } else if (Bitboard::from(sq) & board.by_role(Role::Pawn)).any() {
            10
        } else {
            0
        };
        score += weight * closeness as i64 / 2;
    }
    score
}

fn detect_pins(board: &shakmaty::Board, color: Color) -> (i64, Option<(Square, Square, Square)>) {
    // returns (count, Some((pinning_piece_sq, pinned_piece_sq, king_sq))) as an example
    let king_sq = match board.king_of(color) {
        Some(sq) => sq,
        None => return (0, None),
    };
    let occ = board.occupied();
    let mut pins = 0_i64;
    let mut example: Option<(Square, Square, Square)> = None;

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
                if example.is_none() {
                    example = Some((s, blocker, king_sq));
                }
                break;
            }
        }
    }
    (pins, example)
}

fn detect_forks(board: &shakmaty::Board, color: Color) -> (i64, Option<(Square, Vec<Square>)>) {
    // returns (count, Some((attacker_sq, vec![target_sqs...])))
    let mut forks = 0_i64;
    let mut example: Option<(Square, Vec<Square>)> = None;
    let enemy_bb = board.by_color(color.other());
    for sq in board.by_color(color) {
        let attacks = board.attacks_from(sq);
        let attacked_pieces = attacks & enemy_bb;
        if attacked_pieces.count() < 2 {
            continue;
        }
        // sum values of attacked pieces (GUESS values)
        let mut sum = 0_i64;
        let mut targets: Vec<Square> = Vec::new();
        for (role, val) in [
            (Role::Queen, 900_i64),
            (Role::Rook, 500_i64),
            (Role::Bishop, 330_i64),
            (Role::Knight, 320_i64),
            (Role::Pawn, 100_i64),
        ] {
            let mask = attacked_pieces & board.by_role(role);
            for t in mask {
                sum += val;
                targets.push(t);
            }
        }
        // Count as fork when at least two pieces attacked and combined value above threshold
        if sum >= 500 || attacked_pieces.count() >= 3 {
            forks += 1;
            if example.is_none() {
                example = Some((sq, targets.clone()));
            }
        }
    }
    (forks, example)
}

fn detect_skewers(board: &shakmaty::Board, color: Color) -> (i64, Option<(Square, Square, Square)>) {
    // returns (count, Some((attacker_sq, front_sq, back_sq))) as example
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

    let mut example: Option<(Square, Square, Square)> = None;

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
                        if (board.by_color(enemy) & Bitboard::from(sq)).any() {
                            found.push(sq);
                        }
                        if (board.occupied() & Bitboard::from(sq)).any() {
                            // blocked by any piece
                        }
                        continue;
                    }
                }
                break;
            }

            if found.len() >= 2 {
                let val = |sq: Square| {
                    if (Bitboard::from(sq) & board.by_role(Role::Queen)).any() {
                        900
                    } else if (Bitboard::from(sq) & board.by_role(Role::Rook)).any() {
                        500
                    } else if (Bitboard::from(sq) & board.by_role(Role::Bishop)).any() {
                        330
                    } else if (Bitboard::from(sq) & board.by_role(Role::Knight)).any() {
                        320
                    } else if (Bitboard::from(sq) & board.by_role(Role::Pawn)).any() {
                        100
                    } else {
                        0
                    }
                };
                let v0 = val(found[0]);
                let v1 = val(found[1]);
                if v0 > v1 {
                    skewers += 1;
                    if example.is_none() {
                        example = Some((s, found[0], found[1]));
                    }
                }
            }
        }
    }
    (skewers, example)
}

fn detect_discovered(board: &shakmaty::Board, color: Color) -> (i64, Option<(Square, Square, Square)>) {
    // returns (count, Some((blocker_sq, slider_sq, target_sq))) example
    let occ = board.occupied();
    let mut discovered = 0_i64;
    let mut example: Option<(Square, Square, Square)> = None;
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
                if example.is_none() {
                    // pick one target square
                    if let Some(t) = newly.into_iter().next() {
                        example = Some((blocker, s, t));
                    }
                }
                break;
            }
        }
    }
    (discovered, example)
}

fn piece_square_name(board: &shakmaty::Board, sq: Square) -> String {
    // Return a short piece+square like "Nd5" or just square if no piece found.
    if let Some(piece) = board.piece_at(sq) {
        let letter = match piece.role {
            Role::Pawn => "P",
            Role::Knight => "N",
            Role::Bishop => "B",
            Role::Rook => "R",
            Role::Queen => "Q",
            Role::King => "K",
        };
        return format!("{}{}", letter, sq);
    }
    format!("{}", sq)
}

fn tactical_score(board: &shakmaty::Board, us: Color, phase: u8) -> GroupValue {
    let them = us.other();
    let (pins_us, pin_ex_us) = detect_pins(board, us);
    let (pins_them, pin_ex_them) = detect_pins(board, them);
    let (forks_us, fork_ex_us) = detect_forks(board, us);
    let (forks_them, fork_ex_them) = detect_forks(board, them);
    let (skewers_us, skewer_ex_us) = detect_skewers(board, us);
    let (skewers_them, skewer_ex_them) = detect_skewers(board, them);
    let (disc_us, disc_ex_us) = detect_discovered(board, us);
    let (disc_them, disc_ex_them) = detect_discovered(board, them);

    // GUESS base weights
    let base_w_pins = 50_i64;
    let base_w_forks = 80_i64;
    let base_w_skewers = 40_i64;
    let base_w_disc = 60_i64;

    // Phase scaling: more tactical emphasis in earlier/middlegame when phase is higher.
    // scale = (phase + 8) / 40 -> range approx 0.2..1.0 (integer math: multiply before dividing)
    let phase_factor_num = i64::from(phase) + 8; // numerator
    let phase_factor_den = 40_i64; // denominator

    let w_pins = base_w_pins * phase_factor_num / phase_factor_den;
    let w_forks = base_w_forks * phase_factor_num / phase_factor_den;
    let w_skewers = base_w_skewers * phase_factor_num / phase_factor_den;
    let w_disc = base_w_disc * phase_factor_num / phase_factor_den;

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

    // Examples (piece+square strings)
    if let Some((att, targets)) = fork_ex_us {
        let attacker = piece_square_name(board, att);
        let tnames: Vec<serde_json::Value> = targets.iter().map(|&t| serde_json::Value::from(piece_square_name(board, t))).collect();
        let mut map = serde_json::Map::new();
        map.insert("attacker".into(), serde_json::Value::from(attacker));
        map.insert("targets".into(), serde_json::Value::Array(tnames));
        terms.insert("fork_example_us".into(), serde_json::Value::Object(map));
    }
    if let Some((att, targets)) = fork_ex_them {
        let attacker = piece_square_name(board, att);
        let tnames: Vec<serde_json::Value> = targets.iter().map(|&t| serde_json::Value::from(piece_square_name(board, t))).collect();
        let mut map = serde_json::Map::new();
        map.insert("attacker".into(), serde_json::Value::from(attacker));
        map.insert("targets".into(), serde_json::Value::Array(tnames));
        terms.insert("fork_example_them".into(), serde_json::Value::Object(map));
    }
    if let Some((att, f, b)) = skewer_ex_us {
        let mut map = serde_json::Map::new();
        map.insert("attacker".into(), serde_json::Value::from(piece_square_name(board, att)));
        map.insert("front".into(), serde_json::Value::from(piece_square_name(board, f)));
        map.insert("back".into(), serde_json::Value::from(piece_square_name(board, b)));
        terms.insert("skewer_example_us".into(), serde_json::Value::Object(map));
    }
    if let Some((att, f, b)) = skewer_ex_them {
        let mut map = serde_json::Map::new();
        map.insert("attacker".into(), serde_json::Value::from(piece_square_name(board, att)));
        map.insert("front".into(), serde_json::Value::from(piece_square_name(board, f)));
        map.insert("back".into(), serde_json::Value::from(piece_square_name(board, b)));
        terms.insert("skewer_example_them".into(), serde_json::Value::Object(map));
    }
    if let Some((pinner, pinned, king)) = pin_ex_us {
        let mut map = serde_json::Map::new();
        map.insert("pinner".into(), serde_json::Value::from(piece_square_name(board, pinner)));
        map.insert("pinned".into(), serde_json::Value::from(piece_square_name(board, pinned)));
        map.insert("king".into(), serde_json::Value::from(piece_square_name(board, king)));
        terms.insert("pin_example_us".into(), serde_json::Value::Object(map));
    }
    if let Some((pinner, pinned, king)) = pin_ex_them {
        let mut map = serde_json::Map::new();
        map.insert("pinner".into(), serde_json::Value::from(piece_square_name(board, pinner)));
        map.insert("pinned".into(), serde_json::Value::from(piece_square_name(board, pinned)));
        map.insert("king".into(), serde_json::Value::from(piece_square_name(board, king)));
        terms.insert("pin_example_them".into(), serde_json::Value::Object(map));
    }
    if let Some((blocker, slider, target)) = disc_ex_us {
        let mut map = serde_json::Map::new();
        map.insert("blocker".into(), serde_json::Value::from(piece_square_name(board, blocker)));
        map.insert("slider".into(), serde_json::Value::from(piece_square_name(board, slider)));
        map.insert("target".into(), serde_json::Value::from(piece_square_name(board, target)));
        terms.insert("discovered_example_us".into(), serde_json::Value::Object(map));
    }
    if let Some((blocker, slider, target)) = disc_ex_them {
        let mut map = serde_json::Map::new();
        map.insert("blocker".into(), serde_json::Value::from(piece_square_name(board, blocker)));
        map.insert("slider".into(), serde_json::Value::from(piece_square_name(board, slider)));
        map.insert("target".into(), serde_json::Value::from(piece_square_name(board, target)));
        terms.insert("discovered_example_them".into(), serde_json::Value::Object(map));
    }

    GroupValue {
        mg,
        eg,
        blended,
        terms,
    }
}

fn detect_outposts(board: &shakmaty::Board, color: Color) -> (i64, Option<(Square, Role, Square)>) {
    // Detect outposts: own Knight/Bishop on an advanced square that is not attackable by opponent pawns
    // and is supported by an own pawn (preferred). Returns (count, example(attacker_sq, role, support_sq)).
    let mut count = 0_i64;
    let mut example: Option<(Square, Role, Square)> = None;
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

        if supported_by_pawn.is_some() {
            count += 1;
            if example.is_none() {
                example = Some((sq, board.piece_at(sq).unwrap().role, supported_by_pawn.unwrap()));
            }
        } else {
            // as a fallback, allow squares defended by other pieces
            let occ = board.occupied();
            if board.attacks_to(sq, color, occ).any() {
                count += 1;
                if example.is_none() {
                    example = Some((sq, board.piece_at(sq).unwrap().role, Square::E1));
                    // support square unknown; placeholder E1 (we will prefer pawn support in examples)
                }
            }
        }
    }

    (count, example)
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

    // Outpost detection: add as a piece activity term, with example context
    let (outposts_us, out_ex_us) = detect_outposts(board, us);
    let (outposts_them, out_ex_them) = detect_outposts(board, them);
    let outpost_weight = 40_i64; // GUESS
    let outpost_delta = outposts_us * outpost_weight - outposts_them * outpost_weight;
    piece_activity.blended += outpost_delta;
    piece_activity.terms.insert("outposts_us".into(), serde_json::Value::from(outposts_us));
    piece_activity.terms.insert("outposts_them".into(), serde_json::Value::from(outposts_them));
    if let Some((sq, role, support)) = out_ex_us {
        piece_activity.terms.insert("outpost_example_us".into(), serde_json::Value::from(format!("{} on {} supported by {}", match role { Role::Knight => "N", Role::Bishop => "B", _ => "?" }, sq, piece_square_name(board, support))));
    }
    if let Some((sq, role, support)) = out_ex_them {
        piece_activity.terms.insert("outpost_example_them".into(), serde_json::Value::from(format!("{} on {} supported by {}", match role { Role::Knight => "N", Role::Bishop => "B", _ => "?" }, sq, piece_square_name(board, support))));
    }

    let mut king_safety_group = GroupValue::default();
    let (king_mg, king_eg) = phase_split(king_safety, phase);
    king_safety_group.mg = king_mg;
    king_safety_group.eg = king_eg;
    // augment king safety with king tropism (GUESS weights)
    let tropism_us = king_tropism_score(board, us);
    let tropism_them = king_tropism_score(board, them);
    king_safety_group.blended = king_safety + (tropism_us - tropism_them);
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
    let tactical = tactical_score(board, us, phase);

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

pub fn render_structured_explanations(record: &PositionRecord) -> Vec<serde_json::Value> {
    let mut out: Vec<serde_json::Value> = Vec::new();
    let side = if record.side_to_move == "white" { "white" } else { "black" };
    let side_cap = if side == "white" { "White" } else { "Black" };

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
                if let Some(ex) = record.groups.tactical.terms.get("fork_example_us") {
                    details.insert("example".into(), ex.clone());
                }
                let phrase = if let Some(ex) = details.get("example").and_then(|v| v.as_str()) {
                    format!("{} has {} fork(s) detected (e.g. {}).", side_cap, n, ex)
                } else {
                    format!("{} has {} fork(s) detected.", side_cap, n)
                };
                out.push(make_obj("fork", "white", n, phrase, details));
            }
        }
    }

    // Skewers
    if let Some(val) = record.groups.tactical.terms.get("skewers_us") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                let mut details = serde_json::Map::new();
                if let Some(ex) = record.groups.tactical.terms.get("skewer_example_us") {
                    details.insert("example".into(), ex.clone());
                }
                let phrase = if let Some(ex) = details.get("example").and_then(|v| v.as_str()) {
                    format!("{} has {} skewer(s) detected (e.g. {}).", side_cap, n, ex)
                } else {
                    format!("{} has {} skewer(s) detected.", side_cap, n)
                };
                out.push(make_obj("skewer", "white", n, phrase, details));
            }
        }
    }

    // Pins
    if let Some(val) = record.groups.tactical.terms.get("pins_us") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                let mut details = serde_json::Map::new();
                if let Some(ex) = record.groups.tactical.terms.get("pin_example_us") {
                    details.insert("example".into(), ex.clone());
                }
                let phrase = if let Some(ex) = details.get("example").and_then(|v| v.as_str()) {
                    format!("{} has {} pin(s) (e.g. {}).", side_cap, n, ex)
                } else {
                    format!("{} has {} pin(s).", side_cap, n)
                };
                out.push(make_obj("pin", "white", n, phrase, details));
            }
        }
    }

    // Discovered
    if let Some(val) = record.groups.tactical.terms.get("discovered_us") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                let mut details = serde_json::Map::new();
                if let Some(ex) = record.groups.tactical.terms.get("discovered_example_us") {
                    details.insert("example".into(), ex.clone());
                }
                let phrase = if let Some(ex) = details.get("example").and_then(|v| v.as_str()) {
                    format!("{} has {} discovered-attack opportunity(ies) (e.g. {}).", side_cap, n, ex)
                } else {
                    format!("{} has {} discovered-attack opportunity(ies).", side_cap, n)
                };
                out.push(make_obj("discovered", "white", n, phrase, details));
            }
        }
    }

    // Outposts
    if let Some(val) = record.groups.piece_activity.terms.get("outposts_us") {
        if let Some(n) = val.as_i64() {
            if n > 0 {
                let mut details = serde_json::Map::new();
                if let Some(ex) = record.groups.piece_activity.terms.get("outpost_example_us") {
                    details.insert("example".into(), ex.clone());
                }
                let phrase = if let Some(ex) = details.get("example").and_then(|v| v.as_str()) {
                    format!("{} has {} outpost(s) (e.g. {}).", side_cap, n, ex)
                } else {
                    format!("{} has {} outpost(s).", side_cap, n)
                };
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
                if let Some(ex) = record.groups.tactical.terms.get("fork_example_us") {
                    // ex is now an object
                    if let Some(att) = ex.get("attacker").and_then(|v| v.as_str()) {
                        if let Some(targets) = ex.get("targets").and_then(|v| v.as_array()) {
                            let t_str = targets.iter().filter_map(|v| v.as_str()).collect::<Vec<_>>().join(", ");
                            out.push(format!("{} has {} fork(s) detected (e.g. {} -> {}) — check for immediate tactical threats or trade opportunities.", side, n, att, t_str));
                        } else {
                            out.push(format!("{} has {} fork(s) detected (e.g. {}) — check for immediate tactical threats or trade opportunities.", side, n, att));
                        }
                    } else if let Some(s) = ex.as_str() {
                        out.push(format!("{} has {} fork(s) detected (e.g. {}) — check for immediate tactical threats or trade opportunities.", side, n, s));
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
                if let Some(ex) = record.groups.tactical.terms.get("skewer_example_us") {
                    if let (Some(att), Some(front), Some(back)) = (ex.get("attacker").and_then(|v| v.as_str()), ex.get("front").and_then(|v| v.as_str()), ex.get("back").and_then(|v| v.as_str())) {
                        out.push(format!("{} has {} skewer(s) detected (e.g. {}: {} -> {}) — high-value piece may be attacked in-line.", side, n, att, front, back));
                    } else if let Some(s) = ex.as_str() {
                        out.push(format!("{} has {} skewer(s) detected (e.g. {}) — high-value piece may be attacked in-line.", side, n, s));
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
                if let Some(ex) = record.groups.tactical.terms.get("pin_example_us") {
                    if let (Some(pinner), Some(pinned), Some(king)) = (ex.get("pinner").and_then(|v| v.as_str()), ex.get("pinned").and_then(|v| v.as_str()), ex.get("king").and_then(|v| v.as_str())) {
                        out.push(format!("{} has {} pin(s) (e.g. {} pins {} to {}) — consider relieving pressure or trading pinned pieces.", side, n, pinner, pinned, king));
                    } else if let Some(s) = ex.as_str() {
                        out.push(format!("{} has {} pin(s) (e.g. {}) — consider relieving pressure or trading pinned pieces.", side, n, s));
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
                if let Some(ex) = record.groups.tactical.terms.get("discovered_example_us") {
                    if let (Some(blocker), Some(slider), Some(target)) = (ex.get("blocker").and_then(|v| v.as_str()), ex.get("slider").and_then(|v| v.as_str()), ex.get("target").and_then(|v| v.as_str())) {
                        out.push(format!("{} has {} discovered-attack opportunity(ies) (e.g. {} moves unveils {} attacking {}) — watch for moves that uncover attacks.", side, n, blocker, slider, target));
                    } else if let Some(s) = ex.as_str() {
                        out.push(format!("{} has {} discovered-attack opportunity(ies) (e.g. {}) — watch for moves that uncover attacks.", side, n, s));
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
                if let Some(ex) = record.groups.piece_activity.terms.get("outpost_example_us") {
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


