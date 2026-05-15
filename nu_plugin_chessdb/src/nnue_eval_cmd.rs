use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

use nu_plugin::{EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Signature, Type, Value};

use crate::ChessdbPlugin;
use crate::PLUGIN_CATEGORY;

pub struct NnueEval;

impl PluginCommand for NnueEval {
    type Plugin = ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb nnue-eval"
    }

    fn description(&self) -> &str {
        "Evaluate chess positions using Stockfish NNUE. Accepts a FEN string or list of FEN strings."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .input_output_types(vec![
                (Type::String, Type::Record(vec![].into())),
                (
                    Type::List(Box::new(Type::String)),
                    Type::List(Box::new(Type::Record(vec![].into()))),
                ),
            ])
            .category(Category::Custom(PLUGIN_CATEGORY.into()))
    }

    fn run(
        &self,
        _plugin: &Self::Plugin,
        _engine: &nu_plugin::EngineInterface,
        call: &EvaluatedCall,
        input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let span = call.head;
        let input_value = input.into_value(span)?;

        let fens: Vec<String> = match input_value {
            Value::String { val, .. } => vec![val],
            Value::List { vals, .. } => vals
                .iter()
                .filter_map(|v| v.as_str().ok().map(|s| s.to_string()))
                .collect(),
            _ => {
                return Err(LabeledError::new("Expected a FEN string or list of FEN strings")
                    .with_label("invalid input type", span))
            }
        };

        if fens.is_empty() {
            return Ok(PipelineData::Value(Value::list(vec![], span), None));
        }

        let stockfish_bin =
            std::env::var("STOCKFISH_BIN").unwrap_or_else(|_| "/usr/sbin/stockfish".to_string());

        let mut child = Command::new(&stockfish_bin)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| {
                LabeledError::new(format!(
                    "cannot spawn Stockfish ({}): {}",
                    stockfish_bin, e
                ))
            })?;

        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| LabeledError::new("no stdin for stockfish"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| LabeledError::new("no stdout for stockfish"))?;
        let mut reader = BufReader::new(stdout);

        // UCI init
        writeln!(stdin, "uci").map_err(|e| LabeledError::new(format!("write error: {e}")))?;
        stdin.flush().map_err(|e| LabeledError::new(format!("flush error: {e}")))?;
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).map_err(|e| LabeledError::new(format!("read error: {e}")))?;
            if line.trim() == "uciok" { break; }
        }

        // Enable NNUE
        writeln!(stdin, "setoption name Use NNUE value true").map_err(|e| LabeledError::new(format!("write error: {e}")))?;
        writeln!(stdin, "isready").map_err(|e| LabeledError::new(format!("write error: {e}")))?;
        stdin.flush().map_err(|e| LabeledError::new(format!("flush error: {e}")))?;
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).map_err(|e| LabeledError::new(format!("read error: {e}")))?;
            if line.trim() == "readyok" { break; }
        }

        let mut results: Vec<Value> = Vec::with_capacity(fens.len());

        for fen in &fens {
            let fen_clean = fen.trim();
            writeln!(stdin, "position fen {fen_clean}").map_err(|e| LabeledError::new(format!("write error: {e}")))?;
            writeln!(stdin, "eval").map_err(|e| LabeledError::new(format!("write error: {e}")))?;
            stdin.flush().map_err(|e| LabeledError::new(format!("flush error: {e}")))?;

            let mut score_cp: Option<i64> = None;
            let mut lines_read = 0usize;
            loop {
                if lines_read >= 100 {
                    eprintln!("Warning: no Final eval for FEN after 100 lines (fen={}...)", &fen_clean[..fen_clean.len().min(40)]);
                    break;
                }
                let mut line = String::new();
                reader.read_line(&mut line).map_err(|e| LabeledError::new(format!("read error: {e}")))?;
                lines_read += 1;
                if line.starts_with("Final evaluation") {
                    score_cp = parse_eval_line(&line);
                    break;
                }
            }

            let score = score_cp.unwrap_or(0);
            let record = nu_protocol::record! {
                "fen" => Value::string(fen, span),
                "nnue_score" => Value::int(score, span),
            };
            results.push(Value::record(record, span));
        }

        let _ = writeln!(stdin, "quit");
        let _ = child.wait();

        if results.len() == 1 {
            Ok(PipelineData::Value(results.remove(0), None))
        } else {
            Ok(PipelineData::Value(Value::list(results, span), None))
        }
    }
}

fn parse_eval_line(line: &str) -> Option<i64> {
    let after = line.split("Final evaluation").nth(1)?;
    // after: "       +6.60 (white side) [with scaled NNUE, ...]"
    let value_str = after.trim().split_whitespace().next()?;
    match value_str {
        "none" => None,
        s if s.starts_with('+') || s.starts_with('-') => {
            let f: f64 = s.parse().ok()?;
            Some((f * 100.0).round() as i64)
        }
        _ => None,
    }
}
