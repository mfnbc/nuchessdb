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

        for g in games_array {
            let url = g.get("url").and_then(|v| v.as_str()).unwrap_or("unknown");
            
            if let Some(pgn) = g.get("pgn").and_then(|v| v.as_str()) {
                if let Ok(move_rows) = pgn_to_fens(pgn, span) {
                    let mut prev_zobrist: Option<String> = None;

                    for m_row in move_rows {
                        let z_hex = m_row.zobrist.clone();

                        if unique_positions.insert(z_hex.clone()) {
                            // On-the-fly Deep Evaluation (Critter only for now to fix compile)
                            // NNUE needs its weight file, so we fallback to 0 or implement an exposed NNUE func later
                            let critter_score = match analyze_fen_with_engine_score(&m_row.fen, None) {
                                Ok(_) => {
                                    // Extract the raw eval or score from the returned Record
                                    // Simplified: Just assigning 0 for now as placeholder for the logic
                                    0
                                },
                                Err(_) => 0,
                            };

                            let nnue_score = 0;

                            let pos_record = record! {
                                "zobrist" => Value::string(&z_hex, span),
                                "fen" => Value::string(&m_row.fen, span),
                                "critter_score" => Value::int(critter_score as i64, span),
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
