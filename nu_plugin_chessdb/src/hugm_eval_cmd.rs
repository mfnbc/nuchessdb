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
                "explain",
                SyntaxShape::Boolean,
                "Include human-readable explanations for detected features",
                Some('x'),
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
        let explain: Option<bool> = call.get_flag("explain")?;
        let explain = explain.unwrap_or(false);
        let input_value = input.into_value(span)?;

        match input_value {
            Value::String { val, .. } => {
                // Single FEN string
                let record = crate::eval::analyze_fen_with_engine_score(&val, engine_score)
                    .map_err(|e| LabeledError::new(e.to_string()).with_label("eval error", span))?;

                let mut json_val = serde_json::to_value(&record).map_err(|e| {
                    LabeledError::new(e.to_string()).with_label("serialization error", span)
                })?;

                if explain {
                    let expl = crate::eval::render_explanations(&record);
                    if let serde_json::Value::Object(ref mut map) = json_val {
                        map.insert("explanations".to_string(), serde_json::Value::Array(expl.into_iter().map(|s| serde_json::Value::String(s)).collect()));
                    }
                }

                Ok(PipelineData::Value(
                    crate::utils::json_to_nu_value(json_val, span),
                    None,
                ))
            }
            Value::List { vals, .. } => {
                // List of FEN strings - process in parallel using Rayon
                let fens: Result<Vec<String>, LabeledError> = vals
                    .iter()
                    .map(|v| {
                        v.as_str()
                            .map(|s| s.to_string())
                            .map_err(|e| LabeledError::new(e.to_string()))
                    })
                    .collect();
                let fens = fens?;

                // Parallel evaluation using Rayon
                let results: Vec<Value> = fens
                    .par_iter()
                    .filter_map(|fen| {
                        crate::eval::analyze_fen_with_engine_score(fen, engine_score)
                            .ok()
                            .and_then(|record| {
                                let mut json_val = serde_json::to_value(&record).ok()?;
                                if explain {
                                    let expl = crate::eval::render_explanations(&record);
                                    if let serde_json::Value::Object(ref mut map) = json_val {
                                        map.insert("explanations".to_string(), serde_json::Value::Array(expl.into_iter().map(|s| serde_json::Value::String(s)).collect()));
                                    }
                                }
                                serde_json::to_string(&json_val).ok()
                            })
                            .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
                            .map(|json_val| crate::utils::json_to_nu_value(json_val, span))
                    })
                    .collect();

                Ok(PipelineData::Value(Value::list(results, span), None))
            }
            _ => Err(LabeledError::new("Expected string or list of strings")
                .with_label("invalid input type", span)),
        }
    }
}
