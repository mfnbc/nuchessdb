use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Signature, SyntaxShape, Type, Value};
use rayon::prelude::*;

pub struct HugmEval;

impl PluginCommand for HugmEval {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb hugm-eval"
    }

    fn description(&self) -> &str {
        "Evaluate a chess position or list of positions (FEN from pipeline) and return full HUGM (Human GM) decomposed record(s). Use --explain to include human-readable explanations." 
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
            .named(
                "engine-score",
                SyntaxShape::Int,
                "Optional engine centipawn score to compare against",
                Some('e'),
            )
            .named(
                "verbose",
                SyntaxShape::Boolean,
                "Include full JSON explanations and structured annotations (human + structured)",
                Some('v'),
            )
            .named(
                "weights",
                SyntaxShape::String,
                "Optional JSON file with tunable weights to override defaults",
                Some('w'),
            )
            .named(
                "player-elo",
                SyntaxShape::Int,
                "Player ELO for concept gating and Socratic issue ranking",
                Some('p'),
            )
            .category(Category::Custom(crate::PLUGIN_CATEGORY.into()))
    }

    fn run(
        &self,
        _plugin: &Self::Plugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let span = call.head;
        let engine_score: Option<i64> = call.get_flag("engine-score")?;
        let verbose_flag: Option<bool> = call.get_flag("verbose")?;
        let include_verbose = verbose_flag.unwrap_or(false);
        let player_elo: Option<i32> = call.get_flag("player-elo")?;
        let weights_file: Option<String> = call.get_flag("weights")?;
        if let Some(ref path) = weights_file {
            crate::eval::set_weights_from_file(path).map_err(|e| LabeledError::new(e).with_label("weights load error", span))?;
        }
        let input_value = input.into_value(span)?;

        match input_value {
            Value::String { val, .. } => {
                // Single FEN string
                let record = crate::eval::analyze_fen_with_engine_score(&val, engine_score)
                    .map_err(|e| LabeledError::new(e.to_string()).with_label("eval error", span))?;

                let mut json_val = serde_json::to_value(&record).map_err(|e| {
                    LabeledError::new(e.to_string()).with_label("serialization error", span)
                })?;

                if include_verbose {
                    let expl = crate::eval::render_explanations(&record);
                    if let serde_json::Value::Object(ref mut map) = json_val {
                        map.insert("explanations".to_string(), serde_json::Value::Array(expl.into_iter().map(serde_json::Value::String).collect()));
                        let structured = crate::eval::render_structured_explanations(&record);
                        map.insert("explanations_structured".to_string(), serde_json::Value::Array(structured));
                    }
                }

                if let Some(elo) = player_elo {
                    let concepts = crate::eval::concepts::extract_concepts(&record.groups, &record.side_to_move);
                    let issues = crate::eval::concepts::rank_issues_for_position(&concepts, elo);
                    if let serde_json::Value::Object(ref mut map) = json_val {
                        map.insert("gated_issues".to_string(), serde_json::to_value(&issues).unwrap_or_default());
                    }
                }

                Ok(PipelineData::Value(
                    crate::utils::json_to_nu_value(json_val, span),
                    None,
                ))
            }
            Value::List { vals, .. } => {
                // List of FEN strings - process in parallel using Rayon but surface deterministic errors
                let fens: Result<Vec<String>, LabeledError> = vals
                    .iter()
                    .map(|v| {
                        v.as_str()
                            .map(|s| s.to_string())
                            .map_err(|e| LabeledError::new(e.to_string()))
                    })
                    .collect();
                let fens = fens?;

                // Parallel evaluation: produce per-item Result<Value, LabeledError>
                let results_res: Vec<Result<Value, LabeledError>> = fens
                    .par_iter()
                    .map(|fen| {
                        match crate::eval::analyze_fen_with_engine_score(fen, engine_score) {
                            Ok(record) => {
                                let mut json_val = serde_json::to_value(&record).map_err(|e| LabeledError::new(e.to_string()).with_label("serialization error", span))?;
                                if include_verbose {
                                    let expl = crate::eval::render_explanations(&record);
                                    if let serde_json::Value::Object(ref mut map) = json_val {
                                        map.insert("explanations".to_string(), serde_json::Value::Array(expl.into_iter().map(serde_json::Value::String).collect()));
                                        let structured = crate::eval::render_structured_explanations(&record);
                                        map.insert("explanations_structured".to_string(), serde_json::Value::Array(structured));
                                    }
                                }
                                if let Some(elo) = player_elo {
                                    let concepts = crate::eval::concepts::extract_concepts(&record.groups, &record.side_to_move);
                                    let issues = crate::eval::concepts::rank_issues_for_position(&concepts, elo);
                                    if let serde_json::Value::Object(ref mut map) = json_val {
                                        map.insert("gated_issues".to_string(), serde_json::to_value(&issues).unwrap_or_default());
                                    }
                                }
                                Ok(crate::utils::json_to_nu_value(json_val, span))
                            }
                            Err(e) => Err(LabeledError::new(e.to_string()).with_label("eval error", span)),
                        }
                    })
                    .collect();

                // If any item failed, return the first error (fail-fast for deterministic errors)
                let mut results: Vec<Value> = Vec::with_capacity(results_res.len());
                for r in results_res {
                    match r {
                        Ok(v) => results.push(v),
                        Err(e) => return Err(e),
                    }
                }

                Ok(PipelineData::Value(Value::list(results, span), None))
            }
            _ => Err(LabeledError::new("Expected string or list of strings")
                .with_label("invalid input type", span)),
        }
    }
}
