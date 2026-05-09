use nu_plugin::{EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Signature, Type, Value, record};
use serde_json::Value as JsonValue;
use std::collections::HashSet;

use crate::ChessdbPlugin;
use crate::PLUGIN_CATEGORY;
use crate::core::pgn_to_fens;
use crate::eval::analyze_fen_with_engine_score;

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
        let mut out_positions = Vec::new();
        let mut out_moves = Vec::new();

        let mut unique_positions = HashSet::new();

        let username: Option<String> = call.get_flag("username")?;

        for g in games_array {
            let url = g.get("url").and_then(|v| v.as_str()).unwrap_or("unknown");
            
            // Extract the result relative to the user
            let mut result_str = "unknown".to_string();
            let mut platform = "unknown".to_string();
            let mut white_name = "".to_string();
            let mut black_name = "".to_string();
            let mut white_elo = 0;
            let mut black_elo = 0;
            let mut played_at = "unknown".to_string();
            let mut time_control = "unknown".to_string();
            let mut eco = "unknown".to_string();
            let mut opening = "unknown".to_string();

            if let Some(uname) = &username {
                white_name = g.get("white").and_then(|w| w.get("username")).and_then(|v| v.as_str()).unwrap_or("").to_string();
                black_name = g.get("black").and_then(|b| b.get("username")).and_then(|v| v.as_str()).unwrap_or("").to_string();
                
                if white_name.eq_ignore_ascii_case(uname) {
                    result_str = g.get("white").and_then(|w| w.get("result")).and_then(|v| v.as_str()).unwrap_or("unknown").to_string();
                } else if black_name.eq_ignore_ascii_case(uname) {
                    result_str = g.get("black").and_then(|b| b.get("result")).and_then(|v| v.as_str()).unwrap_or("unknown").to_string();
                }

                platform = if url.contains("chess.com") { "chesscom".to_string() } else { "lichess".to_string() };
                white_elo = g.get("white").and_then(|w| w.get("rating")).and_then(|v| v.as_i64()).unwrap_or(0);
                black_elo = g.get("black").and_then(|b| b.get("rating")).and_then(|v| v.as_i64()).unwrap_or(0);
                time_control = g.get("time_control").and_then(|v| v.as_str()).unwrap_or("").to_string();
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
                    let mut prev_zobrist: Option<String> = None;

                    for m_row in move_rows {
                        let z_hex = m_row.zobrist.clone();

                        if unique_positions.insert(z_hex.clone()) {
                            // On-the-fly Deep Evaluation
                            let (critter_score, critter_json) = match analyze_fen_with_engine_score(&m_row.fen, None) {
                                Ok(rec) => {
                                    // Serialize the entire decomposed struct to JSON
                                    let json_str = serde_json::to_string(&rec).unwrap_or_else(|_| "{}".to_string());
                                    (rec.final_score, json_str)
                                },
                                Err(_) => (0, "{}".to_string()),
                            };

                            let nnue_score = 0; // To be mapped when NNUE bulk interface is ready

                            let pos_record = record! {
                                "zobrist" => Value::string(&z_hex, span),
                                "fen" => Value::string(&m_row.fen, span),
                                "critter_score" => Value::int(critter_score as i64, span),
                                "critter_json" => Value::string(&critter_json, span),
                                "nnue_score" => Value::int(nnue_score as i64, span),
                            };
                            out_positions.push(Value::record(pos_record, span));
                        }

                        if let Some(ref prev_z) = prev_zobrist {
                            let move_record = record! {
                                "game_id" => Value::string(url, span),
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
                "source_id" => Value::string(url, span),
                "platform" => Value::string(platform, span),
                "white" => Value::string(white_name, span),
                "black" => Value::string(black_name, span),
                "white_elo" => Value::int(white_elo as i64, span),
                "black_elo" => Value::int(black_elo as i64, span),
                "result" => Value::string(result_str, span),
                "played_at" => Value::string(played_at, span),
                "time_control" => Value::string(time_control, span),
                "eco" => Value::string(eco, span),
                "opening" => Value::string(opening, span),
                "raw_json" => Value::string(g.to_string(), span),
            };
            out_games.push(Value::record(game_record, span));
        }

        let final_record = record! {
            "games" => Value::list(out_games, span),
            "positions" => Value::list(out_positions, span),
            "moves" => Value::list(out_moves, span),
        };

        Ok(PipelineData::Value(Value::record(final_record, span), None))
    }
}
