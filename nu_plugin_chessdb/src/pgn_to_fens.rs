use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Record, Signature, Type, Value};

pub struct PgnToFens;

pub struct PgnScan;

pub struct PgnToBatch;

fn headers_value(items: &[(String, String)], span: nu_protocol::Span) -> Value {
    let rows = items
        .iter()
        .map(|(k, v)| {
            let mut rec = Record::new();
            rec.push("key", Value::string(k.clone(), span));
            rec.push("value", Value::string(v.clone(), span));
            Value::record(rec, span)
        })
        .collect();
    Value::list(rows, span)
}

fn scan_game_value(game: crate::core::ScanGameRow, span: nu_protocol::Span) -> Value {
    let mut rec = Record::new();
    rec.push("game_index", Value::int(game.game_index as i64, span));
    rec.push("white", Value::string(game.white, span));
    rec.push("black", Value::string(game.black, span));
    rec.push("result", Value::string(game.result, span));

    let moves = game
        .moves
        .into_iter()
        .map(|m| {
            let mut m_rec = Record::new();
            m_rec.push("from_hash", Value::string(m.from_hash, span));
            m_rec.push("move_int", Value::int(m.move_int as i64, span));
            m_rec.push("to_hash", Value::string(m.to_hash, span));
            m_rec.push("san", Value::string(m.san, span));
            m_rec.push("uci", Value::string(m.uci, span));
            Value::record(m_rec, span)
        })
        .collect();

    rec.push("moves", Value::list(moves, span));
    Value::record(rec, span)
}

impl PluginCommand for PgnScan {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb scan-pgn"
    }

    fn description(&self) -> &str {
        "Lightweight scan of a PGN string to extract structural move links and game results."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .input_output_types(vec![
                (Type::String, Type::List(Box::new(Type::Record(vec![].into())))),
                (Type::List(Box::new(Type::String)), Type::List(Box::new(Type::Record(vec![].into())))),
            ])
            .category(Category::Custom(crate::PLUGIN_CATEGORY.into()))
    }

    fn run(
        &self,
        _plugin: &Self::Plugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let input_value = input.into_value(call.head)?;
        let span = call.head;

        let mut all_values: Vec<Value> = Vec::new();

        match input_value {
            Value::String { val, .. } => {
                let games = crate::core::scan_pgn(&val, span)?;
                let values: Vec<Value> = games.into_iter().map(|g| scan_game_value(g, span)).collect();
                all_values.extend(values);
            }
            Value::List { vals, .. } => {
                for v in vals {
                    let s = v.as_str()?;
                    let games = crate::core::scan_pgn(s, span)?;
                    all_values.extend(games.into_iter().map(|g| scan_game_value(g, span)));
                }
            }
            _ => {
                return Err(LabeledError::new("Expected string or list of strings").with_label("invalid input", call.head));
            }
        }

        Ok(PipelineData::Value(Value::list(all_values, span), None))
    }
}

fn move_rows_value(rows: &[crate::core::MoveRow], span: nu_protocol::Span) -> Value {
    let rows = rows
        .iter()
        .map(|row| {
            let mut rec = Record::new();
            rec.push("game_index", Value::int(row.game_index as i64, span));
            rec.push("ply", Value::int(row.ply as i64, span));
            rec.push("move_number", Value::int(row.move_number as i64, span));
            rec.push("color", Value::string(row.color.clone(), span));
            rec.push("san", Value::string(row.san.clone(), span));
            rec.push("uci", Value::string(row.uci.clone(), span));
            rec.push("fen", Value::string(row.fen.clone(), span));
            rec.push("zobrist", Value::string(row.zobrist.clone(), span));
            Value::record(rec, span)
        })
        .collect();
    Value::list(rows, span)
}

fn batch_record_value(batch: crate::core::BatchSummary, span: nu_protocol::Span) -> Value {
    let games_count = batch.games.len() as i64;
    let positions_count = batch.positions.len() as i64;
    let unique_positions_count = batch.unique_positions.len() as i64;
    let collisions_count = batch.collisions.len() as i64;

    let games = batch
        .games
        .into_iter()
        .map(|game| {
            let mut rec = Record::new();
            rec.push("game_index", Value::int(game.game_index as i64, span));
            rec.push("source_game_id", Value::string(game.source_game_id, span));
            rec.push("headers", headers_value(&game.headers, span));
            rec.push("result", Value::string(game.result, span));
            rec.push("moves", move_rows_value(&game.moves, span));
            Value::record(rec, span)
        })
        .collect();

    let unique_positions = batch
        .unique_positions
        .into_iter()
        .map(|row| {
            let mut rec = Record::new();
            rec.push("zobrist", Value::string(row.zobrist, span));
            rec.push("fen", Value::string(row.fen, span));
            Value::record(rec, span)
        })
        .collect();

    let collisions = batch
        .collisions
        .into_iter()
        .map(|row| {
            let mut rec = Record::new();
            rec.push("zobrist", Value::string(row.zobrist, span));
            rec.push("fen", Value::string(row.fen, span));
            rec.push("occurrences", Value::int(row.occurrences as i64, span));
            rec.push(
                "game_indexes",
                Value::list(
                    row.game_indexes
                        .into_iter()
                        .map(|i| Value::int(i as i64, span))
                        .collect(),
                    span,
                ),
            );
            Value::record(rec, span)
        })
        .collect();

    let mut stats = Record::new();
    stats.push("games", Value::int(games_count, span));
    stats.push("positions", Value::int(positions_count, span));
    stats.push("unique_positions", Value::int(unique_positions_count, span));
    stats.push("collisions", Value::int(collisions_count, span));

    let mut rec = Record::new();
    rec.push("source", Value::string(batch.source, span));
    rec.push("games", Value::list(games, span));
    rec.push("positions", move_rows_value(&batch.positions, span));
    rec.push("unique_positions", Value::list(unique_positions, span));
    rec.push("collisions", Value::list(collisions, span));
    rec.push("stats", Value::record(stats, span));
    Value::record(rec, span)
}

impl PluginCommand for PgnToFens {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb pgn-to-fens"
    }

    fn description(&self) -> &str {
        "Parse a single-game PGN string and return a table of {game_index, ply, move_number, color, san, uci, fen, zobrist} for every move."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .input_output_types(vec![
                (Type::String, Type::List(Box::new(Type::Record(vec![].into())))),
                (Type::List(Box::new(Type::String)), Type::List(Box::new(Type::Record(vec![].into())))),
            ])
            .category(Category::Custom(crate::PLUGIN_CATEGORY.into()))
    }

    fn run(
        &self,
        _plugin: &Self::Plugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let input_value = input.into_value(call.head)?;
        let span = call.head;
        let mut all_rows: Vec<Value> = Vec::new();

        match input_value {
            Value::String { val, .. } => {
                let rows = crate::core::pgn_to_fens(&val, span)?;
                if let Value::List { vals, .. } = move_rows_value(&rows, span) {
                    all_rows.extend(vals);
                }
            }
            Value::List { vals, .. } => {
                for v in vals {
                    let s = v.as_str()?;
                    let rows = crate::core::pgn_to_fens(s, span)?;
                    if let Value::List { vals: inner, .. } = move_rows_value(&rows, span) {
                        all_rows.extend(inner);
                    }
                }
            }
            _ => {
                return Err(LabeledError::new("Expected string or list of strings").with_label("invalid input", call.head));
            }
        }

        Ok(PipelineData::Value(Value::list(all_rows, span), None))
    }
}

impl PluginCommand for PgnToBatch {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb pgn-to-batch"
    }

    fn description(&self) -> &str {
        "Parse a PGN string containing one or more games and return a record with {source, games, positions, unique_positions, collisions, stats}."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .input_output_types(vec![
                (Type::String, Type::Record(vec![].into())),
                (Type::List(Box::new(Type::String)), Type::List(Box::new(Type::Record(vec![].into())))),
            ])
            .category(Category::Custom(crate::PLUGIN_CATEGORY.into()))
    }

    fn run(
        &self,
        _plugin: &Self::Plugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let input_value = input.into_value(call.head)?;
        let span = call.head;

        match input_value {
            Value::String { val, .. } => {
                let batch = crate::core::pgn_to_batch_record(&val, span)?;
                Ok(PipelineData::Value(batch_record_value(batch, span), None))
            }
            Value::List { vals, .. } => {
                let mut recs: Vec<Value> = Vec::new();
                for v in vals {
                    let s = v.as_str()?;
                    let batch = crate::core::pgn_to_batch_record(s, span)?;
                    recs.push(batch_record_value(batch, span));
                }
                Ok(PipelineData::Value(Value::list(recs, span), None))
            }
            _ => Err(LabeledError::new("Expected string or list of strings").with_label("invalid input", call.head)),
        }
    }
}
