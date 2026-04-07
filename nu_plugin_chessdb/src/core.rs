use std::collections::BTreeMap;

use nu_protocol::{LabeledError, Span};
use pgn_reader::{BufferedReader, RawHeader, SanPlus, Skip, Visitor};
use shakmaty::{
    fen::Fen,
    san::San,
    uci::Uci,
    zobrist::{Zobrist64, ZobristHash},
    Bitboard, Chess, Color, EnPassantMode, Piece, Position, Role,
};

use crate::chess::fen_to_chess;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FenInfoData {
    pub fen: String,
    pub turn: String,
    pub castling: String,
    pub ep_square: String,
    pub halfmoves: i64,
    pub fullmoves: i64,
    pub material_white: i64,
    pub material_black: i64,
    pub material_diff: i64,
    pub is_check: bool,
    pub is_checkmate: bool,
    pub is_stalemate: bool,
    pub is_insufficient_material: bool,
    pub legal_move_count: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MoveRow {
    pub san: String,
    pub uci: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PgnMoveRow {
    pub game_index: u32,
    pub ply: u32,
    pub move_number: u32,
    pub color: String,
    pub san: String,
    pub uci: String,
    pub fen: String,
    pub zobrist: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BatchGameRow {
    pub game_index: u32,
    pub source_game_id: String,
    pub headers: Vec<(String, String)>,
    pub result: String,
    pub moves: Vec<PgnMoveRow>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BatchCollisionRow {
    pub zobrist: String,
    pub fen: String,
    pub occurrences: u32,
    pub game_indexes: Vec<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UniquePositionRow {
    pub zobrist: String,
    pub fen: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BatchSummary {
    pub source: String,
    pub games: Vec<BatchGameRow>,
    pub positions: Vec<PgnMoveRow>,
    pub unique_positions: Vec<UniquePositionRow>,
    pub collisions: Vec<BatchCollisionRow>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttackSummary {
    pub attacked_by_white: Vec<String>,
    pub attacked_by_black: Vec<String>,
    pub white_attack_count: i64,
    pub black_attack_count: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MobilitySummary {
    pub side_to_move: String,
    pub legal_move_count: i64,
    pub mobility_san: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckerSummary {
    pub side_to_move: String,
    pub is_check: bool,
    pub is_checkmate: bool,
    pub checker_squares: Vec<String>,
}

fn play_and_serialize(pos: Chess, mv: &shakmaty::Move) -> Result<String, LabeledError> {
    let new_pos = pos
        .play(mv)
        .map_err(|e| LabeledError::new(format!("Cannot play move: {e}")))?;
    Ok(Fen::from_position(new_pos, EnPassantMode::Legal).to_string())
}

fn side_to_move_string(pos: &Chess) -> String {
    match pos.turn() {
        Color::White => "white",
        Color::Black => "black",
    }
    .to_string()
}

fn castling_string(pos: &Chess) -> String {
    let cr = pos.castles();
    let mut s = String::new();
    if cr.has(Color::White, shakmaty::CastlingSide::KingSide) {
        s.push('K');
    }
    if cr.has(Color::White, shakmaty::CastlingSide::QueenSide) {
        s.push('Q');
    }
    if cr.has(Color::Black, shakmaty::CastlingSide::KingSide) {
        s.push('k');
    }
    if cr.has(Color::Black, shakmaty::CastlingSide::QueenSide) {
        s.push('q');
    }
    if s.is_empty() {
        s.push('-');
    }
    s
}

fn material_score(pos: &Chess, color: Color) -> i64 {
    let count = |role: Role| -> i64 { pos.board().by_piece(Piece { color, role }).count() as i64 };

    count(Role::Pawn)
        + count(Role::Knight) * 3
        + count(Role::Bishop) * 3
        + count(Role::Rook) * 5
        + count(Role::Queen) * 9
}

pub fn apply_san(fen_str: &str, san_str: &str, span: Span) -> Result<String, LabeledError> {
    let pos = fen_to_chess(fen_str, span)?;
    let san: San = san_str.parse().map_err(|e| {
        LabeledError::new(format!("Invalid SAN: {e}")).with_label("failed to parse SAN move", span)
    })?;

    let mv = san.to_move(&pos).map_err(|e| {
        LabeledError::new(format!("Illegal move: {e}"))
            .with_label("move is not legal in this position", span)
    })?;

    play_and_serialize(pos, &mv)
}

pub fn normalize_fen(fen_str: &str, span: Span) -> Result<String, LabeledError> {
    let fen: Fen = fen_str.parse().map_err(|e| {
        LabeledError::new(format!("Invalid FEN: {e}")).with_label("failed to parse FEN", span)
    })?;

    let pos: Chess = fen
        .into_position(shakmaty::CastlingMode::Standard)
        .map_err(|e| {
            LabeledError::new(format!("Invalid position: {e}"))
                .with_label("position is illegal", span)
        })?;

    Ok(Fen::from_position(pos, EnPassantMode::Legal).to_string())
}

pub fn apply_uci(fen_str: &str, uci_str: &str, span: Span) -> Result<String, LabeledError> {
    let pos = fen_to_chess(fen_str, span)?;
    let uci: Uci = uci_str.parse().map_err(|e| {
        LabeledError::new(format!("Invalid UCI move: {e}"))
            .with_label("failed to parse UCI move", span)
    })?;

    let mv = uci.to_move(&pos).map_err(|e| {
        LabeledError::new(format!("Illegal UCI move: {e}"))
            .with_label("move is not legal in this position", span)
    })?;

    play_and_serialize(pos, &mv)
}

pub fn uci_to_san(fen_str: &str, uci_str: &str, span: Span) -> Result<String, LabeledError> {
    let pos = fen_to_chess(fen_str, span)?;
    let uci: Uci = uci_str.parse().map_err(|e| {
        LabeledError::new(format!("Invalid UCI: {e}")).with_label("failed to parse UCI", span)
    })?;

    let mv = uci.to_move(&pos).map_err(|e| {
        LabeledError::new(format!("Illegal move: {e}"))
            .with_label("move is not legal in this position", span)
    })?;

    Ok(San::from_move(&pos, &mv).to_string())
}

pub fn san_to_uci(fen_str: &str, san_str: &str, span: Span) -> Result<String, LabeledError> {
    let pos = fen_to_chess(fen_str, span)?;
    let san: San = san_str.parse().map_err(|e| {
        LabeledError::new(format!("Invalid SAN: {e}")).with_label("failed to parse SAN", span)
    })?;

    let mv = san.to_move(&pos).map_err(|e| {
        LabeledError::new(format!("Illegal move: {e}"))
            .with_label("move is not legal in this position", span)
    })?;

    Ok(Uci::from_move(&mv, shakmaty::CastlingMode::Standard).to_string())
}

pub fn is_legal(fen_str: &str, move_str: &str, span: Span) -> Result<bool, LabeledError> {
    let pos = fen_to_chess(fen_str, span)?;

    Ok(if let Ok(san) = move_str.parse::<San>() {
        san.to_move(&pos).is_ok()
    } else if let Ok(uci) = move_str.parse::<Uci>() {
        uci.to_move(&pos).is_ok()
    } else {
        false
    })
}

pub fn fen_info(fen_str: &str, span: Span) -> Result<FenInfoData, LabeledError> {
    let pos = fen_to_chess(fen_str, span)?;

    let ep_square = pos
        .ep_square(shakmaty::EnPassantMode::Legal)
        .map(|sq| sq.to_string())
        .unwrap_or_else(|| "-".into());

    let halfmoves = pos.halfmoves() as i64;
    let fullmoves = pos.fullmoves().get() as i64;

    let material_white = material_score(&pos, Color::White);
    let material_black = material_score(&pos, Color::Black);

    Ok(FenInfoData {
        fen: fen_str.to_string(),
        turn: side_to_move_string(&pos),
        castling: castling_string(&pos),
        ep_square,
        halfmoves,
        fullmoves,
        material_white,
        material_black,
        material_diff: material_white - material_black,
        is_check: pos.is_check(),
        is_checkmate: pos.is_checkmate(),
        is_stalemate: pos.is_stalemate(),
        is_insufficient_material: pos.is_insufficient_material(),
        legal_move_count: pos.legal_moves().len() as i64,
    })
}

fn attacked_squares(pos: &Chess, attacker: Color) -> Vec<String> {
    let mut attacked = Bitboard::EMPTY;

    for sq in pos.board().by_color(attacker) {
        attacked |= pos.board().attacks_from(sq);
    }

    attacked.into_iter().map(|sq| sq.to_string()).collect()
}

pub fn attack_summary(fen_str: &str, span: Span) -> Result<AttackSummary, LabeledError> {
    let pos = fen_to_chess(fen_str, span)?;

    let white = attacked_squares(&pos, Color::White);
    let black = attacked_squares(&pos, Color::Black);

    let white_attack_count = white.len() as i64;
    let black_attack_count = black.len() as i64;

    Ok(AttackSummary {
        attacked_by_white: white,
        attacked_by_black: black,
        white_attack_count,
        black_attack_count,
    })
}

pub fn mobility_summary(fen_str: &str, span: Span) -> Result<MobilitySummary, LabeledError> {
    let pos = fen_to_chess(fen_str, span)?;
    let side_to_move = side_to_move_string(&pos);

    let mobility_san = pos
        .legal_moves()
        .iter()
        .map(|mv| San::from_move(&pos, mv).to_string())
        .collect::<Vec<_>>();

    Ok(MobilitySummary {
        side_to_move,
        legal_move_count: mobility_san.len() as i64,
        mobility_san,
    })
}

pub fn checker_summary(fen_str: &str, span: Span) -> Result<CheckerSummary, LabeledError> {
    let pos = fen_to_chess(fen_str, span)?;
    let side_to_move = side_to_move_string(&pos);

    let checker_squares = pos
        .checkers()
        .into_iter()
        .map(|sq| sq.to_string())
        .collect::<Vec<_>>();

    Ok(CheckerSummary {
        side_to_move,
        is_check: pos.is_check(),
        is_checkmate: pos.is_checkmate(),
        checker_squares,
    })
}

pub fn legal_moves(fen_str: &str, span: Span) -> Result<Vec<MoveRow>, LabeledError> {
    let pos = fen_to_chess(fen_str, span)?;

    Ok(pos
        .legal_moves()
        .iter()
        .map(|mv| MoveRow {
            san: San::from_move(&pos, mv).to_string(),
            uci: Uci::from_move(mv, shakmaty::CastlingMode::Standard).to_string(),
        })
        .collect())
}

struct GameVisitor {
    game_index: u32,
    headers: Vec<(String, String)>,
    pos: Chess,
    rows: Vec<PgnMoveRow>,
    ply: u32,
    error: Option<String>,
}

impl GameVisitor {
    fn new(game_index: u32, _span: Span) -> Self {
        Self {
            game_index,
            headers: Vec::new(),
            pos: Chess::default(),
            rows: Vec::new(),
            ply: 0,
            error: None,
        }
    }
}

impl Visitor for GameVisitor {
    type Result = Vec<PgnMoveRow>;

    fn header(&mut self, key: &[u8], value: RawHeader<'_>) {
        if let (Ok(key), Ok(value)) = (
            std::str::from_utf8(key),
            std::str::from_utf8(value.as_bytes()),
        ) {
            self.headers
                .push((key.to_string(), value.trim_matches('"').to_string()));
        }
    }
    fn end_headers(&mut self) -> Skip {
        Skip(false)
    }

    fn san(&mut self, san_plus: SanPlus) {
        if self.error.is_some() {
            return;
        }

        let san_str = san_plus.to_string();
        let bare = san_str.trim_end_matches(['+', '#']);

        let san: San = match bare.parse() {
            Ok(s) => s,
            Err(e) => {
                self.error = Some(format!("SAN parse error '{bare}': {e}"));
                return;
            }
        };

        let mv = match san.to_move(&self.pos) {
            Ok(m) => m,
            Err(e) => {
                self.error = Some(format!("Illegal move '{bare}': {e}"));
                return;
            }
        };

        let uci = Uci::from_move(&mv, shakmaty::CastlingMode::Standard).to_string();

        let new_pos = match self.pos.clone().play(&mv) {
            Ok(p) => p,
            Err(e) => {
                self.error = Some(format!("Play error: {e}"));
                return;
            }
        };

        let fen = Fen::from_position(new_pos.clone(), EnPassantMode::Legal).to_string();
        let zobrist: Zobrist64 = new_pos.zobrist_hash(EnPassantMode::Legal);
        let zobrist = format!("{:016x}", zobrist.0);
        let move_number = (self.ply / 2) + 1;
        let color = if self.ply % 2 == 0 { "white" } else { "black" };

        self.rows.push(PgnMoveRow {
            game_index: self.game_index,
            ply: self.ply,
            move_number,
            color: color.to_string(),
            san: san_str,
            uci,
            fen,
            zobrist,
        });

        self.pos = new_pos;
        self.ply += 1;
    }

    fn begin_variation(&mut self) -> Skip {
        Skip(true)
    }

    fn end_game(&mut self) -> Self::Result {
        std::mem::take(&mut self.rows)
    }
}

pub fn pgn_to_fens(pgn_str: &str, span: Span) -> Result<Vec<PgnMoveRow>, LabeledError> {
    let mut reader = BufferedReader::new(pgn_str.as_bytes());
    let mut visitor = GameVisitor::new(0, span);

    let rows = reader
        .read_game(&mut visitor)
        .map_err(|e| {
            LabeledError::new(format!("PGN parse error: {e}"))
                .with_label("failed to parse PGN", span)
        })?
        .unwrap_or_default();

    if let Some(err) = visitor.error {
        return Err(LabeledError::new(err).with_label("error during move replay", span));
    }

    Ok(rows)
}

pub fn pgn_to_batch_record(pgn_str: &str, span: Span) -> Result<BatchSummary, LabeledError> {
    let initial_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    let initial_pos: Chess = Chess::default();
    let initial_zobrist: Zobrist64 = initial_pos.zobrist_hash(EnPassantMode::Legal);
    let initial_hash = format!("{:016x}", initial_zobrist.0);

    let mut reader = BufferedReader::new(pgn_str.as_bytes());
    let mut games = Vec::new();
    let mut positions = Vec::new();
    // BTreeMap for unique positions: zobrist -> fen (insertion-ordered dedup, O(N log N))
    let mut unique_map: BTreeMap<String, String> = BTreeMap::new();
    unique_map.insert(initial_hash.clone(), initial_fen.to_string());
    let mut collisions: BTreeMap<String, BatchCollisionRow> = BTreeMap::new();
    let mut game_index: u32 = 0;

    loop {
        let mut visitor = GameVisitor::new(game_index, span);
        let game_rows = match reader.read_game(&mut visitor) {
            Ok(Some(rows)) => rows,
            Ok(None) => break,
            Err(e) => {
                return Err(LabeledError::new(format!("PGN parse error: {e}"))
                    .with_label("failed to parse PGN", span))
            }
        };

        if let Some(err) = visitor.error {
            return Err(LabeledError::new(err).with_label("error during move replay", span));
        }

        for row in &game_rows {
            unique_map
                .entry(row.zobrist.clone())
                .or_insert_with(|| row.fen.clone());

            let entry = collisions
                .entry(row.zobrist.clone())
                .or_insert(BatchCollisionRow {
                    zobrist: row.zobrist.clone(),
                    fen: row.fen.clone(),
                    occurrences: 0,
                    game_indexes: Vec::new(),
                });
            entry.occurrences += 1;
            if !entry.game_indexes.contains(&row.game_index) {
                entry.game_indexes.push(row.game_index);
            }
        }

        positions.extend(game_rows.clone());

        games.push(BatchGameRow {
            game_index,
            source_game_id: visitor
                .headers
                .iter()
                .find(|(k, _)| k == "Event")
                .map(|(_, v)| v.clone())
                .unwrap_or_else(|| format!("game-{game_index}")),
            headers: visitor.headers.clone(),
            result: visitor
                .headers
                .iter()
                .find(|(k, _)| k == "Result")
                .map(|(_, v)| v.clone())
                .unwrap_or_else(|| "*".into()),
            moves: game_rows,
        });

        game_index += 1;
    }

    let unique_positions: Vec<UniquePositionRow> = unique_map
        .into_iter()
        .map(|(zobrist, fen)| UniquePositionRow { zobrist, fen })
        .collect();

    let collisions: Vec<BatchCollisionRow> = collisions
        .into_values()
        .filter(|row| row.occurrences > 1)
        .collect();

    Ok(BatchSummary {
        source: "pgn".into(),
        games,
        positions,
        unique_positions,
        collisions,
    })
}

pub fn zobrist(fen_str: &str, as_int: bool, span: Span) -> Result<String, LabeledError> {
    let pos = fen_to_chess(fen_str, span)?;
    let hash: Zobrist64 = pos.zobrist_hash(EnPassantMode::Legal);
    let hash_value: u64 = hash.0;

    Ok(if as_int {
        hash_value.to_string()
    } else {
        format!("{:016x}", hash_value)
    })
}
