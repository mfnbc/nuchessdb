use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Signature, SyntaxShape, Type};

pub struct CritterEval;

impl PluginCommand for CritterEval {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb critter-eval"
    }

    fn description(&self) -> &str {
        "Evaluate a chess position (FEN from pipeline) and return a full critter-eval record."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .input_output_types(vec![(Type::String, Type::Record(vec![].into()))])
            .named(
                "engine-score",
                SyntaxShape::Int,
                "Optional engine centipawn score to compare against",
                Some('e'),
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
        let fen_str = input.into_value(call.head)?.as_str()?.to_string();
        let span = call.head;

        let engine_score: Option<i64> = call.get_flag("engine-score")?;

        let record = crate::eval::analyze_fen_with_engine_score(&fen_str, engine_score)
            .map_err(|e| LabeledError::new(e.to_string()).with_label("eval error", span))?;

        // Serialize the full record to a Nu Value via serde_json -> Value::record
        let json_val = serde_json::to_value(&record).map_err(|e| {
            LabeledError::new(e.to_string()).with_label("serialization error", span)
        })?;

        Ok(PipelineData::Value(
            crate::utils::json_to_nu_value(json_val, span),
            None,
        ))
    }
}
