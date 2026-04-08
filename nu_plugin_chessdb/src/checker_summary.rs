use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Record, Signature, Type, Value};

pub struct CheckerSummary;

impl PluginCommand for CheckerSummary {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb checker-summary"
    }

    fn description(&self) -> &str {
        "Return check status and checking squares for the side to move."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .input_output_types(vec![(Type::String, Type::Record(vec![].into()))])
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
        let summary = crate::core::checker_summary(&fen_str, call.head)?;

        let mut rec = Record::new();
        rec.push(
            "side_to_move",
            Value::string(summary.side_to_move, call.head),
        );
        rec.push("is_check", Value::bool(summary.is_check, call.head));
        rec.push("is_checkmate", Value::bool(summary.is_checkmate, call.head));
        rec.push(
            "checker_squares",
            Value::list(
                summary
                    .checker_squares
                    .into_iter()
                    .map(|sq| Value::string(sq, call.head))
                    .collect(),
                call.head,
            ),
        );

        Ok(PipelineData::Value(Value::record(rec, call.head), None))
    }
}
