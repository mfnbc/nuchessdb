use nu_plugin::{EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Signature, Type, Value, record};
use serde_json::Value as JsonValue;
use std::collections::HashSet;
use chrono::DateTime;

use crate::ChessdbPlugin;
use crate::PLUGIN_CATEGORY;
use crate::core::pgn_to_fens;
use crate::eval::analyze_fen_with_engine_score;

struct PendingPos {
    zobrist: String,
    fen: String,
    board_pieces: String,
    hugm_score: i64,
    hugm_eval_arr: String,
    state_id: u16,
}

/// Lightweight FEN entry collected during game parsing.
/// Evaluated in batch after all games are parsed.
struct FenToEval {
    zobrist: String,
    fen: String,
    board_pieces: String,
}

pub struct ProcessCorpus;

impl PluginCommand for ProcessCorpus {
    type Plugin = ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb process-corpus"
    }

    fn description(&self) -> &str {
        "Takes a JSON array of games, parses PGNs into structured DataFrames (games, positions, moves)."
    }

    fn signature(&self) -> Signature {
        Signature::build(PluginCommand::name(self))
            .input_output_type(Type::String, Type::Any)
            .named(
                "username",
                nu_protocol::SyntaxShape::String,
                "The username of the player to determine result relative to them",
                Some('u')
            )
            .category(Category::Custom(PLUGIN_CATEGORY.to_string()))
    }

    fn run(
        &self,
        _plugin: &Self::Plugin,
        _engine: &nu_plugin::EngineInterface,
        call: &EvaluatedCall,
        input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let span = call.head;
        let input_str = input.into_value(span)?.into_string()?;

        let json_data: JsonValue = serde_json::from_str(&input_str).map_err(|e| {
            LabeledError::new(format!("Failed to parse JSON: {}", e))
        })?;

        let games_array = match json_data.as_array() {
            Some(arr) => arr,
            None => return Err(LabeledError::new("Input must be a JSON array")),
        };

        let mut out_games = Vec::new();
        let mut out_moves = Vec::new();

        // Phase 1: collect FENs during game parsing (no evaluation yet)
        let mut fens_to_eval: Vec<FenToEval> = Vec::new();
        let mut unique_positions = HashSet::new();

        let username: Option<String> = call.get_flag("username")?;
        for g in games_array {
            let url = g.get("url").and_then(|v| v.as_str()).unwrap_or("unknown");
            let mut game_id_int: i64 = 0;
            let mut source_game_id: String = url.to_string();
            if let Some(last_slash) = url.rfind('/') {
                let tail = &url[last_slash+1..];
                // try parse as integer for game_id_int, but always keep source_game_id as string
                if let Ok(parsed_id) = tail.parse::<i64>() {
                    game_id_int = parsed_id;
                    source_game_id = tail.to_string();
                } else {
                    source_game_id = tail.to_string();
                }
            }
            // prefer explicit id field if present
            if let Some(id_str) = g.get("id").and_then(|v| v.as_str()) {
                if !id_str.is_empty() {
                    source_game_id = id_str.to_string();
                }
            }
            
            // Extract the result relative to the user
            let mut result_str = "unknown".to_string();
            let platform = if url.contains("chess.com") { "chesscom".to_string() } else { "lichess".to_string() };
            let white_name = g.get("white").and_then(|w| w.get("username")).and_then(|v| v.as_str()).unwrap_or("").to_string();
            let black_name = g.get("black").and_then(|b| b.get("username")).and_then(|v| v.as_str()).unwrap_or("").to_string();
            let white_elo = g.get("white").and_then(|w| w.get("rating")).and_then(|v| v.as_i64()).unwrap_or(0);
            let black_elo = g.get("black").and_then(|b| b.get("rating")).and_then(|v| v.as_i64()).unwrap_or(0);
            let mut played_at = "unknown".to_string();
            let time_control = g.get("time_control").and_then(|v| v.as_str()).unwrap_or("unknown").to_string();
            let mut eco = "unknown".to_string();
            let mut opening = "unknown".to_string();

            // Extract played_at from known fields (chess.com: end_time in seconds, lichess: lastMoveAt in ms or createdAt)
            if let Some(end_time) = g.get("end_time").and_then(|v| v.as_i64()) {
                if end_time > 0 {
                    if let Some(dt) = DateTime::from_timestamp(end_time, 0) {
                        played_at = dt.format("%Y-%m-%dT%H:%M:%SZ").to_string();
                    }
                }
            } else if let Some(last_move_at) = g.get("lastMoveAt").and_then(|v| v.as_i64()) {
                if last_move_at > 0 {
                    let secs = last_move_at / 1000;
                    if let Some(dt) = DateTime::from_timestamp(secs, 0) {
                        played_at = dt.format("%Y-%m-%dT%H:%M:%SZ").to_string();
                    }
                }
            } else if let Some(created_at) = g.get("createdAt").and_then(|v| v.as_i64()) {
                let secs = if created_at > 1_000_000_000_000 { created_at / 1000 } else { created_at };
                if let Some(dt) = DateTime::from_timestamp(secs, 0) {
                    played_at = dt.format("%Y-%m-%dT%H:%M:%SZ").to_string();
                }
            } else if let Some(played_str) = g.get("played_at").and_then(|v| v.as_str()) {
                played_at = played_str.to_string();
            }

            // If username provided, compute result relative to that username; otherwise store generic result field if available
            if let Some(uname) = &username {
                if white_name.eq_ignore_ascii_case(uname) {
                    result_str = g.get("white").and_then(|w| w.get("result")).and_then(|v| v.as_str()).unwrap_or("unknown").to_string();
                } else if black_name.eq_ignore_ascii_case(uname) {
                    result_str = g.get("black").and_then(|b| b.get("result")).and_then(|v| v.as_str()).unwrap_or("unknown").to_string();
                }
            } else {
                result_str = g.get("result").and_then(|v| v.as_str()).unwrap_or("unknown").to_string();
            }

            if let Some(pgn) = g.get("pgn").and_then(|v| v.as_str()) {
                // simple extraction for opening
                if let Some(eco_start) = pgn.find("[ECO \"") {
                    let eco_sub = &pgn[eco_start+6..];
                    if let Some(eco_end) = eco_sub.find("\"]") {
                        eco = eco_sub[..eco_end].to_string();
                    }
                }
                if let Some(eco_url) = g.get("eco").and_then(|v| v.as_str()) {
                    if let Some(last_slash) = eco_url.rfind('/') {
                        opening = eco_url[last_slash+1..].to_string();
                    }
                }
                if let Ok(move_rows) = pgn_to_fens(pgn, span) {
                    let initial_zobrist = "463b96181691fc9c".to_string();
                    if unique_positions.insert(initial_zobrist.clone()) {
                        fens_to_eval.push(FenToEval {
                            zobrist: initial_zobrist.clone(),
                            fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1".to_string(),
                            board_pieces: "rnbqkbnrppppppppPPPPPPPPRNBQKBNR".to_string(),
                        });
                    }
                    let mut prev_zobrist: Option<String> = Some(initial_zobrist);

                    for m_row in move_rows {
                        let z_hex = m_row.zobrist.clone();

                        if unique_positions.insert(z_hex.clone()) {
                            let board_pieces: String = m_row.fen.chars().take_while(|c| *c != ' ').filter(|c| c.is_alphabetic()).collect();
                            fens_to_eval.push(FenToEval {
                                zobrist: z_hex.clone(),
                                fen: m_row.fen.clone(),
                                board_pieces,
                            });
                        }

                        if let Some(ref prev_z) = prev_zobrist {
                            let move_record = record! {
                                "game_id" => Value::int(game_id_int, span),
                                "position_id" => Value::string(prev_z, span),
                                "next_position_id" => Value::string(&z_hex, span),
                                "ply" => Value::int(m_row.ply as i64, span),
                                "move_number" => Value::int(m_row.move_number as i64, span),
                                "color" => Value::string(&m_row.color, span),
                                "san" => Value::string(&m_row.san, span),
                                "uci" => Value::string(&m_row.uci, span),
                            };
                            out_moves.push(Value::record(move_record, span));
                        }

                        prev_zobrist = Some(z_hex);
                    }
                }
            }

            let game_record = record! {
                "game_id" => Value::int(game_id_int, span),
                "source" => Value::string(platform, span),
                "source_game_id" => Value::string(source_game_id, span),
                "white" => Value::string(white_name, span),
                "black" => Value::string(black_name, span),
                "white_elo" => Value::int(white_elo, span),
                "black_elo" => Value::int(black_elo, span),
                "result" => Value::string(result_str, span),
                "played_at" => Value::string(played_at, span),
                "time_control" => Value::string(time_control, span),
                "eco" => Value::string(eco, span),
                "opening" => Value::string(opening, span),
            };
            out_games.push(Value::record(game_record, span));
        }


        // Phase 2: batch-evaluate all unique FENs in parallel (Rayon)
        use rayon::prelude::*;
        let eval_results: Vec<PendingPos> = fens_to_eval
            .par_iter()
            .map(|fe| {
                let (hugm_score, hugm_eval_arr, state_id) =
                    match analyze_fen_with_engine_score(&fe.fen, None) {
                        Ok(rec) => {
                            let sid = rec.sensor_report.state_id;
                            let arr = vec![
                                rec.groups.material.blended,
                                rec.groups.pawn_structure.blended,
                                rec.groups.piece_activity.blended,
                                rec.groups.king_safety.blended,
                                rec.groups.passed_pawns.blended,
                                rec.groups.development.blended,
                                rec.groups.vector_features.blended,
                                rec.groups.strategic.blended,
                                rec.groups.scaling.value,
                                rec.groups.drawishness.value,
                                rec.groups.override_.value,
                            ];
                            let json_str =
                                serde_json::to_string(&arr).unwrap_or_else(|_| "[]".to_string());
                            (rec.final_score, json_str, sid)
                        }
                        Err(_) => (0, "[]".to_string(), 0u16),
                    };
                PendingPos {
                    zobrist: fe.zobrist.clone(),
                    fen: fe.fen.clone(),
                    board_pieces: fe.board_pieces.clone(),
                    hugm_score,
                    hugm_eval_arr,
                    state_id,
                }
            })
            .collect();

        // Phase 3: materialize out_positions
        let mut out_positions = Vec::new();
        for p in eval_results.into_iter() {
            let pos_record = record! {
                "zobrist" => Value::string(&p.zobrist, span),
                "fen" => Value::string(&p.fen, span),
                "board_pieces" => Value::string(p.board_pieces, span),
                "hugm_score" => Value::int(p.hugm_score, span),
                "hugm_eval_arr" => Value::string(&p.hugm_eval_arr, span),
                "state_id" => Value::int(p.state_id as i64, span),
            };
            out_positions.push(Value::record(pos_record, span));
        }

        let final_record = record! {
            "games" => Value::list(out_games, span),
            "positions" => Value::list(out_positions, span),
            "moves" => Value::list(out_moves, span),
        };

        Ok(PipelineData::Value(Value::record(final_record, span), None))
    }
}